import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../core/task_model.dart';
import '../core/bubble_engine.dart';

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

class TaskStage extends StatefulWidget {
  const TaskStage({
    super.key,
    required this.items,
    required this.settings,
    required this.onComplete,
    required this.onEdit,
    required this.onDelete,
    required this.replay,
  });
  final List<TaskOccurrence> items;
  final AppSettings settings;
  final Future<void> Function(TaskOccurrence) onComplete;
  final ValueChanged<OrbitTask> onEdit;
  final ValueChanged<OrbitTask> onDelete;
  final int replay;
  @override
  State<TaskStage> createState() => _TaskStageState();
}

class _TaskStageState extends State<TaskStage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final BubbleEngine _engine = BubbleEngine();
  late final Ticker _ticker;
  Duration? _last;
  bool _visible = true;
  int _page = 0;
  int _cardCursor = 0;
  int _pageSize = 6;
  final Set<String> _finishing = {};
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker((time) {
      final delta = _last == null
          ? 0.0
          : (time - _last!).inMicroseconds / 1000000;
      _last = time;
      if (_visible && widget.settings.display == DisplayMode.bubbles)
        _engine.step(delta);
      if (!_visible ||
          widget.settings.display != DisplayMode.bubbles ||
          _engine.paused ||
          (_engine.motion == MotionMode.opening && _engine.elapsed >= 6.5))
        _ticker.stop();
    })..start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    _last = null;
  }

  @override
  void didUpdateWidget(covariant TaskStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.replay != widget.replay ||
        oldWidget.settings.display != widget.settings.display)
      _engine.replay();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _engine.dispose();
    super.dispose();
  }

  Future<void> _finish(TaskOccurrence item) async {
    if (_finishing.contains(item.identity)) return;
    setState(() => _finishing.add(item.identity));
    if (!widget.settings.reduceMotion &&
        !MediaQuery.disableAnimationsOf(context))
      await Future<void>.delayed(const Duration(milliseconds: 180));
    try {
      await widget.onComplete(item);
    } finally {
      if (mounted) setState(() => _finishing.remove(item.identity));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty)
      return Center(
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
      );
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = constraints.maxHeight < 310 ? 4 : 6;
        _pageSize = count;
        final pages = (widget.items.length / count).ceil();
        _page = _page.clamp(0, pages - 1);
        final items = widget.items.skip(_page * count).take(count).toList();
        return Column(
          children: [
            Expanded(
              child: switch (widget.settings.display) {
                DisplayMode.bubbles => _bubbles(items),
                DisplayMode.papers => _papers(items),
                DisplayMode.cards => _cards(items),
              },
            ),
            if (pages > 1)
              SizedBox(
                height: 36,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: '上一组',
                      padding: EdgeInsets.zero,
                      onPressed: _page == 0
                          ? null
                          : () => setState(() => _page--),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Text('${_page + 1} / $pages · 共 ${widget.items.length} 件'),
                    IconButton(
                      tooltip: '下一组',
                      padding: EdgeInsets.zero,
                      onPressed: _page == pages - 1
                          ? null
                          : () => setState(() => _page++),
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
      _engine.configure(
        items,
        Size(box.maxWidth, box.maxHeight),
        widget.settings.motion,
        widget.settings.paused ||
            widget.settings.reduceMotion ||
            MediaQuery.disableAnimationsOf(context),
      );
      if (!_engine.paused &&
          (widget.settings.motion != MotionMode.opening ||
              _engine.elapsed < 6.5) &&
          !_ticker.isActive) {
        _last = null;
        _ticker.start();
      }
      return ClipRect(
        child: Flow(
          delegate: _BubbleFlow(_engine),
          children: List.generate(items.length, (index) {
            final item = items[index], body = _engine.bodies[index];
            final color = taskColor(item.task.id);
            return MouseRegion(
              onEnter: (_) => _engine.hold(index, 'hover', true),
              onExit: (_) => _engine.hold(index, 'hover', false),
              child: Listener(
                onPointerDown: (_) => _engine.hold(index, 'press', true),
                onPointerUp: (_) => _engine.hold(index, 'press', false),
                onPointerCancel: (_) => _engine.hold(index, 'press', false),
                child: Focus(
                  onFocusChange: (value) => _engine.hold(index, 'focus', value),
                  child: AnimatedScale(
                    scale: _finishing.contains(item.identity) ? .05 : 1,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeInBack,
                    child: SizedBox(
                      width: body.radius * 2,
                      height: body.radius * 2,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            center: const Alignment(-.4, -.5),
                            colors: [
                              Color.lerp(color, Colors.white, .5)!,
                              color,
                            ],
                          ),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: .9),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: color.withValues(alpha: .38),
                              blurRadius: 14,
                              offset: const Offset(0, 5),
                            ),
                          ],
                        ),
                        child: Material(
                          color: Colors.transparent,
                          shape: const CircleBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => _finish(item),
                            onLongPress: () => widget.onEdit(item.task),
                            customBorder: const CircleBorder(),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 9,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Flexible(
                                    child: Text(
                                      item.task.title,
                                      textAlign: TextAlign.center,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: (body.radius * .21).clamp(
                                          13,
                                          18,
                                        ),
                                        fontWeight: FontWeight.w600,
                                        height: 1.25,
                                      ),
                                    ),
                                  ),
                                  if (body.radius > 57 &&
                                      occurrenceCaption(item).isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 5),
                                      child: Text(
                                        occurrenceCaption(item),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 10),
                                      ),
                                    ),
                                  SizedBox(
                                    height: 30,
                                    child: IconButton(
                                      tooltip: '编辑 ${item.task.title}',
                                      padding: EdgeInsets.zero,
                                      iconSize: 15,
                                      onPressed: () => widget.onEdit(item.task),
                                      icon: const Icon(Icons.edit_outlined),
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
            );
          }),
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
        offset: _finishing.contains(item.identity)
            ? const Offset(0, 1)
            : Offset.zero,
        duration: const Duration(milliseconds: 180),
        child: AnimatedScale(
          scale: _finishing.contains(item.identity) ? .1 : 1,
          duration: const Duration(milliseconds: 180),
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
                        onPressed: () => _finish(item),
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
      final height = box.maxHeight < 420 ? 420.0 : box.maxHeight;
      return SingleChildScrollView(
        child: SizedBox(
          height: height,
          child: Column(
            children: [
              const SizedBox(height: 24),
              const Text(
                '先专心做这一件。',
                style: TextStyle(color: Color(0xff817988), fontSize: 14),
              ),
              const SizedBox(height: 24),
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
                        direction: DismissDirection.startToEnd,
                        confirmDismiss: (_) async {
                          await _finish(item);
                          return false;
                        },
                        child: AnimatedSlide(
                          offset: _finishing.contains(item.identity)
                              ? const Offset(1.2, -.08)
                              : Offset.zero,
                          duration: const Duration(milliseconds: 180),
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
                                      '${_page * _pageSize + _cardCursor + 1} / ${widget.items.length}',
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
                                  '重要 ${['低', '中', '高'][item.task.importance - 1]} · 紧急 ${['低', '中', '高'][item.task.urgency - 1]}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xff756781),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton.icon(
                                    onPressed: () => _finish(item),
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
                          : () => setState(
                              () => _cardCursor =
                                  (_cardCursor + 1) % items.length,
                            ),
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
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView.builder(
          itemCount: widget.items.length,
          itemBuilder: (context, index) => ListTile(
            leading: Icon(
              Icons.circle,
              color: taskColor(widget.items[index].task.id),
              size: 16,
            ),
            title: Text(widget.items[index].task.title),
            subtitle: Text(occurrenceCaption(widget.items[index])),
            onTap: () => Navigator.pop(context, index),
          ),
        ),
      ),
    );
    if (selected != null && mounted)
      setState(() {
        _page = selected ~/ _pageSize;
        _cardCursor = selected % _pageSize;
      });
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
