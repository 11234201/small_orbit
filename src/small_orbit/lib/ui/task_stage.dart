import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/task_model.dart';
import '../core/bubble_engine.dart';
import 'bubble_surface.dart';

const taskColors = [
  Color(0xffffddc7),
  Color(0xffe2d9fb),
  Color(0xffd7eadb),
  Color(0xffffdce5),
  Color(0xffd4e8f8),
  Color(0xfff3e7b7),
];
Color taskColor(String id) =>
    taskColors[id.codeUnits.fold(0, (a, b) => a + b) % taskColors.length];
String occurrenceCaption(TaskOccurrence item) {
  final parts = <String>[];
  if (item.day != null) {
    final delta = daysBetween(dateOnly(DateTime.now()), item.day!);
    parts.add(
      delta == 0
          ? '今天'
          : delta == 1
          ? '明天'
          : '${item.day!.month}/${item.day!.day}${delta < 0 ? ' · 待完成' : ''}',
    );
  }
  if (item.task.reminderMinute != null) {
    final minute = item.task.reminderMinute!;
    parts.add(
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}',
    );
  }
  if (item.task.repeat != RepeatKind.none) parts.add(item.task.repeatLabel);
  return parts.join(' · ');
}

String priorityCaption(OrbitTask task) =>
    '重要 ${['低', '中', '高'][task.importance - 1]} · 紧急 ${['低', '中', '高'][task.urgency - 1]}';

class TaskStage extends StatefulWidget {
  const TaskStage({
    super.key,
    required this.items,
    required this.settings,
    required this.onComplete,
    required this.onEdit,
    required this.onDelete,
    required this.replay,
    this.minimalChrome = false,
  });
  final List<TaskOccurrence> items;
  final AppSettings settings;
  final Future<void> Function(TaskOccurrence) onComplete;
  final ValueChanged<OrbitTask> onEdit;
  final ValueChanged<OrbitTask> onDelete;
  final int replay;
  final bool minimalChrome;
  @override
  State<TaskStage> createState() => _TaskStageState();
}

class _TaskStageState extends State<TaskStage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final BubbleEngine _engine = BubbleEngine();
  late final Ticker _ticker;
  Duration? _last;
  bool _visible = true;
  bool _interactive = true;
  final Map<String, Set<String>> _interactionHolds = {};
  final Map<String, (Offset, Offset)> _dragOrigins = {};
  final Set<String> _releasedUnderPointer = {};
  int? _gravityPointer;
  int _page = 0;
  int _cardCursor = 0;
  String? _cardIdentity;
  int _pageSize = 6;
  final Set<String> _finishing = {};
  final Set<String> _pending = {};
  final Map<String, (TaskOccurrence, int)> _departing = {};
  final Map<String, (Timer, Completer<void>)> _exitTimers = {};
  bool get _reduceMotion =>
      widget.settings.reduceMotion || MediaQuery.disableAnimationsOf(context);
  Duration get _motionDuration =>
      _reduceMotion ? Duration.zero : const Duration(milliseconds: 180);
  List<TaskOccurrence> get _displayItems {
    final result = widget.items.toList();
    for (final entry in _departing.entries) {
      if (!result.any((item) => item.identity == entry.key)) {
        result.insert(entry.value.$2.clamp(0, result.length), entry.value.$1);
      }
    }
    return result;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _visible = _canAnimate(lifecycle);
    _interactive = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _ticker = createTicker((time) {
      final delta = _last == null
          ? 0.0
          : (time - _last!).inMicroseconds / 1000000;
      _last = time;
      if (_visible && widget.settings.display == DisplayMode.bubbles)
        _engine.step(delta);
      _syncTicker();
    });
  }

  // Inactive means visible without input focus (for example a side window).
  // Native Windows visibility/TickerMode still gates minimized/tray windows.
  bool _canAnimate(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  void _syncTicker() {
    final shouldRun =
        _visible &&
        (widget.items.isNotEmpty || _departing.isNotEmpty) &&
        widget.settings.display == DisplayMode.bubbles &&
        _engine.moving &&
        TickerMode.valuesOf(context).enabled;
    if (shouldRun && !_ticker.isActive) {
      _last = null;
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
      _last = null;
    }
  }

  void _hold(String id, String reason, bool held) {
    if (reason == 'hover') {
      if (!held) _releasedUnderPointer.remove(id);
      if (held && _releasedUnderPointer.contains(id)) return;
    }
    if (held) {
      (_interactionHolds[id] ??= {}).add(reason);
    } else {
      _interactionHolds[id]?.remove(reason);
      if (_interactionHolds[id]?.isEmpty ?? false) _interactionHolds.remove(id);
    }
    _engine.holdIdentity(id, reason, held && _interactive);
    _syncTicker();
  }

  void _restoreInteractionHolds() {
    final identities = _engine.bodies.map((body) => body.id).toSet();
    _interactionHolds.removeWhere((id, _) => !identities.contains(id));
    _dragOrigins.removeWhere((id, _) => !identities.contains(id));
    _releasedUnderPointer.removeWhere((id) => !identities.contains(id));
    for (final body in _engine.bodies) {
      body.holds.clear();
      if (_interactive) body.holds.addAll(_interactionHolds[body.id] ?? {});
    }
  }

  void _dragStart(BubbleBody body, DragStartDetails details) {
    if (!_interactive) return;
    Tooltip.dismissAllToolTips();
    _dragOrigins[body.id] = (details.globalPosition, body.position);
    _hold(body.id, 'drag', true);
  }

  void _dragUpdate(String id, DragUpdateDetails details) {
    final origin = _dragOrigins[id];
    if (origin == null || !_interactive) return;
    // Use screen deltas: Flow translates the hit target as the body moves.
    _engine.dragTo(id, origin.$2 + details.globalPosition - origin.$1);
  }

  void _dragEnd(String id, Offset velocity) {
    if (_dragOrigins.remove(id) == null) return;
    _hold(id, 'drag', false);
    _hold(id, 'press', false);
    _hold(id, 'hover', false);
    // The release point is still under the mouse. Let the throw escape until
    // the pointer exits; a new press or keyboard focus always holds it again.
    _releasedUnderPointer.add(id);
    _engine.release(id, velocity);
    _syncTicker();
  }

  void _cancelDrags() {
    _gravityPointer = null;
    _engine.attract(null);
    for (final id in _dragOrigins.keys.toList()) {
      _dragEnd(id, Offset.zero);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = _canAnimate(state);
    final interactive = state == AppLifecycleState.resumed;
    if (visible != _visible) _last = null;
    _visible = visible;
    if (interactive != _interactive) {
      _interactive = interactive;
      if (!interactive) {
        _cancelDrags();
        // A press can be cancelled by switching apps. Logical keyboard focus
        // survives that switch and is restored only when this window is active.
        for (final holds in _interactionHolds.values) {
          holds.remove('press');
        }
        Tooltip.dismissAllToolTips();
      }
      if (!widget.settings.gravityEnabled) _engine.attract(null);
      _restoreInteractionHolds();
      setState(() {});
    }
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant TaskStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.display != widget.settings.display) {
      _cancelDrags();
      _cardIdentity = null;
    }
    if (oldWidget.settings.display != widget.settings.display ||
        (!oldWidget.settings.reduceMotion && widget.settings.reduceMotion)) {
      _departing.clear();
      _finishing.clear();
      _cancelExitTimers();
    }
    if (oldWidget.replay != widget.replay ||
        oldWidget.settings.display != widget.settings.display)
      _engine.replay();
    _syncTicker();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelExitTimers();
    _ticker.dispose();
    _engine.dispose();
    super.dispose();
  }

  void _cancelExitTimer(String identity) {
    final pending = _exitTimers.remove(identity);
    if (pending == null) return;
    pending.$1.cancel();
    if (!pending.$2.isCompleted) pending.$2.complete();
  }

  void _cancelExitTimers() {
    for (final identity in _exitTimers.keys.toList()) {
      _cancelExitTimer(identity);
    }
  }

  Future<void> _finish(TaskOccurrence item) async {
    if (_pending.contains(item.identity)) return;
    final duration = _motionDuration;
    setState(() {
      _pending.add(item.identity);
      if (duration != Duration.zero) {
        _finishing.add(item.identity);
        final index = widget.items.indexWhere(
          (value) => value.identity == item.identity,
        );
        _departing[item.identity] = (item, index < 0 ? 0 : index);
      }
    });
    // Save immediately. Retain only the visual until its short exit finishes.
    // A failed save restores the same task and never leaves an invisible tile.
    Future<void> animation = Future.value();
    if (duration != Duration.zero) {
      final ready = Completer<void>();
      final timer = Timer(duration, () {
        _exitTimers.remove(item.identity);
        ready.complete();
      });
      _exitTimers[item.identity] = (timer, ready);
      animation = ready.future;
    }
    try {
      await widget.onComplete(item);
      await animation;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('没有完成保存，这件小事仍在原处，请重试。')));
      }
    } finally {
      _cancelExitTimer(item.identity);
      if (mounted)
        setState(() {
          _pending.remove(item.identity);
          _finishing.remove(item.identity);
          _departing.remove(item.identity);
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayItems = _displayItems;
    if (displayItems.isEmpty) {
      if (_ticker.isActive) _ticker.stop();
      return Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 108,
                height: 108,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xffebe3f8),
                ),
                child: const Icon(
                  Icons.auto_awesome_outlined,
                  size: 45,
                  color: Color(0xff8c73ae),
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                '留一点空白，也很好。',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                '写下一件小事，让它轻轻飘进来。',
                style: TextStyle(color: Color(0xff817988)),
              ),
            ],
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final largeText = MediaQuery.textScalerOf(context).scale(16) > 22;
        final count = largeText
            ? 2
            : constraints.maxHeight < 310
            ? 4
            : 6;
        _pageSize = count;
        final pages = (displayItems.length / count).ceil();
        if (widget.settings.display == DisplayMode.cards &&
            _cardIdentity != null) {
          final selected = displayItems.indexWhere(
            (item) => item.identity == _cardIdentity,
          );
          if (selected >= 0) {
            _page = selected ~/ count;
            _cardCursor = selected % count;
          }
        }
        _page = _page.clamp(0, pages - 1);
        final items = displayItems.skip(_page * count).take(count).toList();
        return Column(
          children: [
            Expanded(
              child: switch (widget.settings.display) {
                DisplayMode.bubbles => _bubbles(items),
                DisplayMode.papers => _papers(items),
                DisplayMode.cards => _cards(items),
              },
            ),
            if (pages > 1 ||
                (!widget.minimalChrome &&
                    widget.settings.display != DisplayMode.cards))
              SizedBox(
                height: 44,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: '上一组',
                      padding: EdgeInsets.zero,
                      onPressed: _page == 0
                          ? null
                          : () => setState(() {
                              _page--;
                              _cardIdentity = null;
                            }),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Flexible(
                      child: TextButton(
                        onPressed: _cardOverview,
                        child: Text(
                          pages > 1
                              ? '${_page + 1} / $pages · 共 ${widget.items.length} 件'
                              : '看看全部 ${widget.items.length} 件小事',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '下一组',
                      padding: EdgeInsets.zero,
                      onPressed: _page == pages - 1
                          ? null
                          : () => setState(() {
                              _page++;
                              _cardIdentity = null;
                            }),
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _bubbles(List<TaskOccurrence> items) => LayoutBuilder(
    builder: (context, box) {
      final largeText = MediaQuery.textScalerOf(context).scale(16) > 22;
      _engine.configure(
        items,
        Size(box.maxWidth, box.maxHeight),
        widget.settings.motion,
        widget.settings.paused ||
            widget.settings.reduceMotion ||
            MediaQuery.disableAnimationsOf(context),
        capacity: _pageSize,
        gravityStyle: widget.settings.gravity,
        bubbleMaterial: widget.settings.material,
      );
      if (!widget.settings.gravityEnabled) _engine.attract(null);
      _restoreInteractionHolds();
      if (!TickerMode.valuesOf(context).enabled) _cancelDrags();
      _syncTicker();
      return TooltipVisibility(
        visible: _interactive,
        child: ClipRect(
          child: Stack(
            children: [
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) {
                    if (!widget.settings.gravityEnabled ||
                        !_interactive ||
                        _engine.paused ||
                        _gravityPointer != null)
                      return;
                    _gravityPointer = event.pointer;
                    _engine.attract(event.localPosition);
                    _syncTicker();
                  },
                  onPointerMove: (event) {
                    if (_gravityPointer == event.pointer)
                      _engine.attract(event.localPosition);
                  },
                  onPointerUp: (event) {
                    if (_gravityPointer == event.pointer) {
                      _gravityPointer = null;
                      _engine.attract(null);
                      _syncTicker();
                    }
                  },
                  onPointerCancel: (event) {
                    if (_gravityPointer == event.pointer) {
                      _gravityPointer = null;
                      _engine.attract(null);
                      _syncTicker();
                    }
                  },
                ),
              ),
              Flow(
                delegate: _BubbleFlow(_engine),
                children: List.generate(items.length, (index) {
                  final item = items[index], body = _engine.bodies[index];
                  final color = taskColor(item.task.id);
                  return MouseRegion(
                    key: ValueKey('bubble-${item.identity}'),
                    onEnter: (_) => _hold(item.identity, 'hover', true),
                    onExit: (_) => _hold(item.identity, 'hover', false),
                    child: Listener(
                      onPointerDown: (_) => _hold(item.identity, 'press', true),
                      onPointerUp: (_) => _hold(item.identity, 'press', false),
                      onPointerCancel: (_) =>
                          _hold(item.identity, 'press', false),
                      child: Focus(
                        canRequestFocus: false,
                        onFocusChange: (value) =>
                            _hold(item.identity, 'focus', value),
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(
                            end: _finishing.contains(item.identity) ? 1 : 0,
                          ),
                          duration: _motionDuration,
                          builder: (context, progress, child) => CustomPaint(
                            foregroundPainter: BubbleBurst(
                              color: color,
                              progress: progress,
                            ),
                            child: Opacity(opacity: 1 - progress, child: child),
                          ),
                          child: AnimatedScale(
                            scale: _finishing.contains(item.identity) ? .05 : 1,
                            duration: _motionDuration,
                            curve: Curves.easeInBack,
                            child: SizedBox(
                              width: body.radius * 2,
                              height: body.radius * 2,
                              child: CustomPaint(
                                painter: BubbleSurface(
                                  engine: _engine,
                                  material: widget.settings.material,
                                  body: body,
                                  color: color,
                                ),
                                child: Material(
                                  color: Colors.transparent,
                                  shape: const CircleBorder(),
                                  clipBehavior: Clip.antiAlias,
                                  child: Tooltip(
                                    message:
                                        '${item.task.title}\n${priorityCaption(item.task)}',
                                    triggerMode: TooltipTriggerMode.manual,
                                    waitDuration: const Duration(
                                      milliseconds: 600,
                                    ),
                                    constraints: const BoxConstraints(
                                      maxWidth: 280,
                                    ),
                                    child: _BubbleDragTarget(
                                      onPanStart:
                                          _pending.contains(item.identity) ||
                                              !_interactive
                                          ? null
                                          : (details) =>
                                                _dragStart(body, details),
                                      onPanUpdate: (details) =>
                                          _dragUpdate(item.identity, details),
                                      onPanEnd: (details) => _dragEnd(
                                        item.identity,
                                        details.velocity.pixelsPerSecond,
                                      ),
                                      onPanCancel: () =>
                                          _dragEnd(item.identity, Offset.zero),
                                      child: InkWell(
                                        onTap: _pending.contains(item.identity)
                                            ? null
                                            : () => _finish(item),
                                        onLongPress: () =>
                                            widget.onEdit(item.task),
                                        customBorder: const CircleBorder(),
                                        child: Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: body.radius * .22,
                                            vertical: body.radius * .16,
                                          ),
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  item.task.title.replaceAll(
                                                    RegExp(r'\s+'),
                                                    ' ',
                                                  ),
                                                  semanticsLabel:
                                                      item.task.title,
                                                  textAlign: TextAlign.center,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 15,
                                                    fontWeight: FontWeight.w500,
                                                    color: const Color(
                                                      0xff493c55,
                                                    ),
                                                    height: 1.25,
                                                  ),
                                                ),
                                              ),
                                              if (!largeText &&
                                                  body.radius > 66 &&
                                                  occurrenceCaption(
                                                    item,
                                                  ).isNotEmpty)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        top: 5,
                                                      ),
                                                  child: Text(
                                                    occurrenceCaption(item),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontSize: 10,
                                                    ),
                                                  ),
                                                ),
                                              SizedBox(
                                                height: 24,
                                                child: _BubbleDragTarget(
                                                  // A drag starting on the edit control cancels
                                                  // its tap; it must never throw or complete.
                                                  onPanStart: (_) {},
                                                  onPanUpdate: (_) {},
                                                  onPanEnd: (_) {},
                                                  onPanCancel: () {},
                                                  child: IconButton(
                                                    tooltip:
                                                        '编辑 ${item.task.title}',
                                                    padding: EdgeInsets.zero,
                                                    iconSize: 15,
                                                    onPressed: () => widget
                                                        .onEdit(item.task),
                                                    icon: const Icon(
                                                      Icons.edit_outlined,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ],
          ),
        ),
      );
    },
  );
  Widget _papers(List<TaskOccurrence> items) => GridView.builder(
    padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 270,
      mainAxisExtent: 176,
      crossAxisSpacing: 16,
      mainAxisSpacing: 18,
    ),
    itemCount: items.length,
    itemBuilder: (context, index) {
      final item = items[index];
      return AnimatedSlide(
        key: ValueKey('paper-${item.identity}'),
        offset: _finishing.contains(item.identity)
            ? const Offset(0, 1)
            : Offset.zero,
        duration: _motionDuration,
        child: AnimatedScale(
          scale: _finishing.contains(item.identity) ? .1 : 1,
          duration: _motionDuration,
          child: Transform.rotate(
            angle: (index.isEven ? -.025 : .025),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: taskColor(item.task.id),
                borderRadius: BorderRadius.circular(4),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x12000000),
                    blurRadius: 8,
                    offset: Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      item.task.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    occurrenceCaption(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                  Row(
                    children: [
                      IconButton(
                        tooltip: '编辑',
                        onPressed: () => widget.onEdit(item.task),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                      ),
                      const Spacer(),
                      IconButton.filledTonal(
                        tooltip: '收进口袋',
                        onPressed: _pending.contains(item.identity)
                            ? null
                            : () => _finish(item),
                        icon: const Icon(Icons.check, size: 18),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
  Widget _cards(List<TaskOccurrence> items) => LayoutBuilder(
    builder: (context, box) {
      _cardCursor = _cardCursor.clamp(0, items.length - 1);
      final item = items[_cardCursor];
      // Indexes can move while another card finishes saving, or when a task
      // is inserted/reordered. Keep the user's chosen card until it disappears.
      _cardIdentity = item.identity;
      final minimumHeight =
          (420 * MediaQuery.textScalerOf(context).scale(16) / 16).clamp(
            420.0,
            840.0,
          );
      final height = box.maxHeight < minimumHeight
          ? minimumHeight
          : box.maxHeight;
      return SingleChildScrollView(
        child: SizedBox(
          height: height,
          child: Column(
            children: [
              if (!widget.minimalChrome) ...[
                const SizedBox(height: 24),
                const Text(
                  '先专心做这一件。',
                  style: TextStyle(color: Color(0xff817988), fontSize: 14),
                ),
                const SizedBox(height: 24),
              ],
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Transform.rotate(
                        angle: -.055,
                        child: Container(
                          margin: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: const Color(0xffebe3f1),
                            borderRadius: BorderRadius.circular(24),
                          ),
                        ),
                      ),
                      Transform.rotate(
                        angle: .035,
                        child: Container(
                          margin: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: const Color(0xfff6e6d9),
                            borderRadius: BorderRadius.circular(24),
                          ),
                        ),
                      ),
                      Dismissible(
                        key: ValueKey(item.identity),
                        direction: _pending.contains(item.identity)
                            ? DismissDirection.none
                            : DismissDirection.startToEnd,
                        movementDuration: _reduceMotion
                            ? Duration.zero
                            : const Duration(milliseconds: 180),
                        confirmDismiss: (_) async {
                          await _finish(item);
                          return false;
                        },
                        child: AnimatedSlide(
                          offset: _finishing.contains(item.identity)
                              ? const Offset(1.2, -.08)
                              : Offset.zero,
                          duration: _motionDuration,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: taskColor(item.task.id),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: Colors.white, width: 2),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x158b72ab),
                                  blurRadius: 20,
                                  offset: Offset(0, 8),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      '${_page * _pageSize + _cardCursor + 1} / ${_displayItems.length}',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    const Spacer(),
                                    IconButton(
                                      tooltip: '编辑 ${item.task.title}',
                                      onPressed: () => widget.onEdit(item.task),
                                      icon: const Icon(
                                        Icons.edit_outlined,
                                        size: 19,
                                      ),
                                    ),
                                  ],
                                ),
                                Expanded(
                                  child: Center(
                                    child: SingleChildScrollView(
                                      child: Text(
                                        item.task.title,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontSize: 25,
                                          fontWeight: FontWeight.w600,
                                          height: 1.5,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                if (occurrenceCaption(item).isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Text(
                                      occurrenceCaption(item),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                Text(
                                  priorityCaption(item.task),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xff756781),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton.icon(
                                    onPressed: _pending.contains(item.identity)
                                        ? null
                                        : () => _finish(item),
                                    icon: const Icon(Icons.check),
                                    label: const Text('完成，划走'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Wrap(
                  spacing: 16,
                  alignment: WrapAlignment.center,
                  children: [
                    TextButton.icon(
                      onPressed: items.length < 2
                          ? null
                          : () => setState(() {
                              _cardCursor = (_cardCursor + 1) % items.length;
                              _cardIdentity = items[_cardCursor].identity;
                            }),
                      icon: const Icon(Icons.shuffle, size: 18),
                      label: const Text('换一件'),
                    ),
                    TextButton.icon(
                      onPressed: _cardOverview,
                      icon: const Icon(Icons.grid_view, size: 18),
                      label: const Text('看看其他小事'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
  Future<void> _cardOverview() async {
    final selected = await showModalBottomSheet<({String identity, bool edit})>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _TaskOverview(items: widget.items),
    );
    if (selected == null || !mounted) return;
    final index = widget.items.indexWhere(
      (item) => item.identity == selected.identity,
    );
    if (index < 0) return;
    if (selected.edit) {
      widget.onEdit(widget.items[index].task);
    } else {
      setState(() {
        _page = index ~/ _pageSize;
        _cardCursor = index % _pageSize;
        _cardIdentity = selected.identity;
      });
    }
  }
}

class _TaskOverview extends StatefulWidget {
  const _TaskOverview({required this.items});
  final List<TaskOccurrence> items;
  @override
  State<_TaskOverview> createState() => _TaskOverviewState();
}

class _TaskOverviewState extends State<_TaskOverview> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final matching = widget.items
        .where(
          (item) => item.task.title.toLowerCase().contains(
            _query.trim().toLowerCase(),
          ),
        )
        .toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .68,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: '找一件小事',
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
              Expanded(
                child: matching.isEmpty
                    ? const Center(child: Text('还没找到，换个词试试。'))
                    : ListView.builder(
                        itemCount: matching.length,
                        itemBuilder: (context, index) {
                          final item = matching[index];
                          return ListTile(
                            leading: Icon(
                              Icons.circle,
                              color: taskColor(item.task.id),
                              size: 16,
                            ),
                            title: Text(item.task.title),
                            subtitle: Text(
                              [
                                occurrenceCaption(item),
                                priorityCaption(item.task),
                              ].where((text) => text.isNotEmpty).join('\n'),
                            ),
                            trailing: IconButton(
                              tooltip: '编辑 ${item.task.title}',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => Navigator.pop(context, (
                                identity: item.identity,
                                edit: true,
                              )),
                            ),
                            onTap: () => Navigator.pop(context, (
                              identity: item.identity,
                              edit: false,
                            )),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BubbleFlow extends FlowDelegate {
  _BubbleFlow(this.engine) : super(repaint: engine);
  final BubbleEngine engine;
  @override
  void paintChildren(FlowPaintingContext context) {
    for (var i = 0; i < context.childCount; i++) {
      final body = engine.bodies[i];
      context.paintChild(
        i,
        transform: Matrix4.translationValues(
          body.position.dx - body.radius,
          body.position.dy - body.radius,
          0,
        ),
      );
    }
  }

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      BoxConstraints.tight(Size.square(engine.bodies[i].radius * 2));
  @override
  bool shouldRepaint(covariant _BubbleFlow oldDelegate) => true;
}

/// Deliberate travel is needed even with a precise mouse. Tiny hand movements
/// must not start a throw; the existing InkWell retains tap/keyboard semantics.
class _BubblePanRecognizer extends PanGestureRecognizer {
  _BubblePanRecognizer()
    : super(
        supportedDevices: const {
          PointerDeviceKind.mouse,
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
        },
      );

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) => globalDistanceMoved.abs() > 18;
}

class _BubbleDragTarget extends StatelessWidget {
  const _BubbleDragTarget({
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
    required this.onPanCancel,
    required this.child,
  });
  final GestureDragStartCallback? onPanStart;
  final GestureDragUpdateCallback onPanUpdate;
  final GestureDragEndCallback onPanEnd;
  final GestureDragCancelCallback onPanCancel;
  final Widget child;

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    excludeFromSemantics: true,
    gestures: {
      if (onPanStart != null)
        _BubblePanRecognizer:
            GestureRecognizerFactoryWithHandlers<_BubblePanRecognizer>(
              _BubblePanRecognizer.new,
              (recognizer) => recognizer
                ..dragStartBehavior = DragStartBehavior.down
                ..onStart = onPanStart
                ..onUpdate = onPanUpdate
                ..onEnd = onPanEnd
                ..onCancel = onPanCancel,
            ),
    },
    child: child,
  );
}
