import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';

import 'core/local_store.dart';
import 'core/orbit_controller.dart';
import 'core/task_model.dart';
import 'platform/reminder_service.dart';
import 'platform/window_service.dart';
import 'platform/startup_probe.dart';
import 'ui/settings_panel.dart';
import 'ui/task_editor.dart';
import 'ui/task_stage.dart';
import 'ui/startup_recovery.dart';
import 'ui/window_opacity_panel.dart';
import 'ui/playground_panel.dart';
import 'platform/focus_service.dart';

WindowService? _windowService;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await startApplication();
}

Future<void> startApplication() async {
  final startup = Stopwatch()..start();
  LocalStore? store;
  OrbitController? controller;
  try {
    final override = Platform.environment['SMALL_ORBIT_DATA_DIR'];
    final directory = override == null
        ? await getApplicationSupportDirectory()
        : Directory(override);
    store = LocalStore(directory);
    controller = OrbitController(store);
    await controller.initialize();
    final dataReady = startup.elapsed;
    final reminders = ReminderService(controller);
    try {
      await reminders.start();
    } catch (_) {
      controller.notice = '提醒暂未就绪，可在设置中检查权限。';
    }
    final focus = FocusService(controller);
    await focus.start();
    final loadedController = controller;
    _windowService?.dispose();
    final window = WindowService(
      onPrepareToQuit: () async {
        try {
          await loadedController.closeWrites(
            afterDrain: () async {
              await focus.stop();
              await reminders.stop();
            },
          );
        } catch (_) {
          focus.resumeClock();
          rethrow;
        }
        focus.dispose();
        reminders.dispose();
      },
    )..register();
    _windowService = window;
    runApp(
      OrbitApp(
        controller: controller,
        reminders: reminders,
        window: window,
        focus: focus,
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        recordStartupProbe(
          loadedController.store,
          dataReady,
          startup.elapsed,
          loadedController.document.tasks.length,
          window.requestQuit,
        ),
      );
    });
  } catch (error) {
    controller?.dispose();
    _windowService?.dispose();
    _windowService = WindowService(onPrepareToQuit: () async {})..register();
    runApp(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: StartupRecovery(
          error: error,
          store: store,
          onRetry: startApplication,
        ),
      ),
    );
  }
}

class OrbitApp extends StatelessWidget {
  const OrbitApp({
    super.key,
    required this.controller,
    required this.reminders,
    this.window,
    this.focus,
  });
  final OrbitController controller;
  final ReminderService reminders;
  final WindowService? window;
  final FocusService? focus;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '小事星球',
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    builder: (context, child) => window == null
        ? child!
        : ListenableBuilder(
            listenable: window!,
            builder: (context, _) => Stack(
              children: [
                AbsorbPointer(
                  absorbing: window!.isClosing,
                  child: TickerMode(
                    enabled: window!.isVisible && !window!.isClosing,
                    child: ExcludeFocus(
                      excluding: window!.isClosing,
                      child: child!,
                    ),
                  ),
                ),
                if (window!.isClosing) ...[
                  const ModalBarrier(
                    dismissible: false,
                    color: Color(0xccfcfaf7),
                  ),
                  const Center(
                    child: Material(
                      color: Colors.transparent,
                      child: Text('正在保存并退出…'),
                    ),
                  ),
                ],
              ],
            ),
          ),
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfffcfaf7),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff8b72ab),
        brightness: Brightness.light,
        surface: const Color(0xfffcfaf7),
      ),
      fontFamily: Platform.isWindows ? 'Microsoft YaHei' : null,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xffe8e1ec)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xffe8e1ec)),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    ),
    home: OrbitHome(
      controller: controller,
      reminders: reminders,
      window: window,
      focus: focus,
    ),
  );
}

class OrbitHome extends StatefulWidget {
  const OrbitHome({
    super.key,
    required this.controller,
    required this.reminders,
    this.window,
    this.focus,
  });
  final OrbitController controller;
  final ReminderService reminders;
  final WindowService? window;
  final FocusService? focus;
  @override
  State<OrbitHome> createState() => _OrbitHomeState();
}

class _OrbitHomeState extends State<OrbitHome> with WidgetsBindingObserver {
  final TextEditingController _quick = TextEditingController();
  final FocusNode _quickFocus = FocusNode();
  final FocusNode _pageFocus = FocusNode(debugLabel: 'todo surface');
  final GlobalKey _stageKey = GlobalKey();
  bool _wasCompact = false;
  late final FocusService _focus;
  bool _today = true, _adding = false, _editing = false;
  int _replay = 0;
  OrbitController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    _focus = widget.focus ?? FocusService(controller);
    if (widget.focus == null) unawaited(_focus.start());
    _wasCompact = _compact;
    WidgetsBinding.instance.addObserver(this);
    widget.reminders.addListener(_reminderChanged);
    widget.window?.addListener(_windowChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller.notice != null) _message(controller.notice!);
      _reminderChanged();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.reminders.removeListener(_reminderChanged);
    widget.window?.removeListener(_windowChanged);
    if (widget.focus == null) _focus.dispose();
    _quick.dispose();
    _quickFocus.dispose();
    _pageFocus.dispose();
    super.dispose();
  }

  void _windowChanged() {
    final enteredCompact = _compact && !_wasCompact;
    _wasCompact = _compact;
    if (mounted) setState(() {});
    if (enteredCompact) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _compact) _pageFocus.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant OrbitHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.window != widget.window) {
      oldWidget.window?.removeListener(_windowChanged);
      widget.window?.addListener(_windowChanged);
    }
  }

  bool get _compact => widget.window?.compact ?? false;

  PopupMenuButton<String> _windowMenu() => PopupMenuButton<String>(
    tooltip: '窗口选项',
    icon: Icon(_compact ? Icons.more_horiz : Icons.expand_more, size: 20),
    onOpened: () {
      if (!(widget.window?.optionsLoaded ?? false))
        unawaited(widget.window?.refreshOptions());
    },
    onSelected: (value) => _safe(() async {
      final window = widget.window!;
      switch (value) {
        case 'play':
          await _play();
        case 'compact':
          _quickFocus.unfocus();
          await window.setCompact(!window.compact);
        case 'top':
          await window.setAlwaysOnTop(!window.alwaysOnTop);
        case 'opacity':
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => WindowOpacityPanel(window: window),
          );
        case 'add':
          await _edit();
        case 'undo':
          await controller.undo();
        case 'quit':
          await window.requestQuit();
        default:
          await ReminderService.channel.invokeMethod<void>(value);
      }
    }),
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'play', child: Text('玩法与小世界')),
      CheckedPopupMenuItem(
        value: 'compact',
        checked: _compact,
        enabled:
            (widget.window?.optionsLoaded ?? false) &&
            !(widget.window?.updatingOptions ?? true),
        child: Text(_compact ? '恢复完整界面' : '仅显示待办'),
      ),
      CheckedPopupMenuItem(
        value: 'top',
        checked: widget.window?.alwaysOnTop ?? false,
        enabled:
            (widget.window?.optionsLoaded ?? false) &&
            !(widget.window?.updatingOptions ?? true),
        child: const Text('窗口置顶'),
      ),
      PopupMenuItem(
        value: 'opacity',
        enabled:
            (widget.window?.optionsLoaded ?? false) &&
            !(widget.window?.updatingOptions ?? true),
        child: Text('窗口透明度 · ${widget.window?.opacity ?? 100}%'),
      ),
      if (_compact) ...[
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'add',
          enabled: !_editing && !_adding,
          child: const Text('添加小事'),
        ),
        PopupMenuItem(
          value: 'undo',
          enabled: controller.canUndo,
          child: const Text('撤销上一步'),
        ),
      ],
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'hide', child: Text('收进托盘')),
      const PopupMenuItem(value: 'minimize', child: Text('最小化')),
      const PopupMenuItem(value: 'quit', child: Text('退出并停止提醒')),
    ],
  );

  Future<void> _play({int page = 0, TaskOccurrence? selected}) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => PlaygroundPanel(
            controller: controller,
            focus: _focus,
            initialPage: page,
            initialTask: selected,
          ),
        ),
      );

  Future<void> _complete(TaskOccurrence item) async {
    final before = controller.document.activeMemories.length;
    await controller.complete(item);
    if (controller.document.activeMemories.length > before)
      await _focus.feedback();
  }

  Widget _taskStage(List<TaskOccurrence> items, AppSettings settings) {
    final stars = controller.document.memories
        .where((m) => m.day == dayKey(controller.clock()))
        .take(constellationPageSize)
        .toList();
    return Stack(
      children: [
        if (stars.isNotEmpty)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: ConstellationPainter(stars, background: false),
              ),
            ),
          ),
        Positioned.fill(child: _taskStageContent(items, settings)),
      ],
    );
  }

  Widget _taskStageContent(List<TaskOccurrence> items, AppSettings settings) =>
      TaskStage(
        key: _stageKey,
        items: items,
        settings: settings,
        replay: _replay,
        minimalChrome: _compact,
        onComplete: _complete,
        onEdit: _menu,
        onDelete: (task) => _safe(() => controller.delete(task.id)),
      );

  Widget _compactBody(List<TaskOccurrence> items, AppSettings settings) =>
      Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 30, 10, 6),
              child: _taskStage(items, settings),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 38,
            height: 28,
            child: MouseRegion(
              cursor: SystemMouseCursors.move,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => _safe(() => widget.window!.startDragging()),
                child: const Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: EdgeInsets.only(left: 12),
                    child: Tooltip(
                      message: '拖动窗口',
                      child: Icon(
                        Icons.drag_indicator,
                        size: 16,
                        color: Color(0xffb7acbf),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            height: 30,
            width: 38,
            child: _windowMenu(),
          ),
        ],
      );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.reminders.tick(forceSync: true));
      unawaited(_focus.retryNotifications());
      setState(() => _replay++);
    }
  }

  void _reminderChanged() {
    final error = widget.reminders.lastError;
    if (error != null) _message(error);
  }

  void _message(String text) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _safe(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      _message('没有保存成功，请重试：$error');
    }
  }

  Future<void> _add() async {
    if (_adding || _quick.text.trim().isEmpty) return;
    setState(() => _adding = true);
    final title = _quick.text.trim();
    await _safe(() async {
      await controller.upsert(
        OrbitTask(id: newTaskId(), title: title, createdAt: DateTime.now()),
      );
      if (mounted && _quick.text.trim() == title) _quick.clear();
    });
    if (mounted) setState(() => _adding = false);
  }

  Future<void> _edit({OrbitTask? task}) async {
    if (_editing || (task == null && _adding)) return;
    setState(() => _editing = true);
    final draft = task == null ? _quick.text : '';
    try {
      // Keep the editor and its draft open until the write is durable. A disk
      // failure can then be retried without losing the user's changes.
      final edited = await editTask(
        context,
        task: task,
        title: draft,
        onSave: controller.upsert,
      );
      if (edited == null || !mounted) return;
      if (task == null && _quick.text == draft) _quick.clear();
      if (edited.reminderMinute != null) {
        try {
          await widget.reminders.requestNotifications();
          await widget.reminders.retry();
        } catch (_) {
          _message('小事已保存，提醒暂未就绪，可在设置中重试。');
        }
      }
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  Future<void> _menu(OrbitTask task) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .72,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 8,
                  ),
                  child: Text(
                    task.title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('编辑这件小事'),
                onTap: () => Navigator.pop(context, 'edit'),
              ),
              ListTile(
                leading: const Icon(Icons.track_changes),
                title: const Text('专注这件事'),
                onTap: () => Navigator.pop(context, 'focus'),
              ),
              ListTile(
                subtitle: const Text('已获得的星星和装饰将作为匿名纪念保留'),
                leading: const Icon(Icons.delete_outline),
                title: Text(
                  task.repeat == RepeatKind.none ? '删除任务' : '删除整个重复任务',
                ),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'focus') {
      final item = controller.document
          .active(controller.clock(), todayOnly: false)
          .where((i) => i.task.id == task.id)
          .firstOrNull;
      if (item != null) await _play(page: 2, selected: item);
    }
    if (action == 'edit') await _edit(task: task);
    if (action == 'delete') await _safe(() => controller.delete(task.id));
  }

  Future<void> _history() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .72,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final entries = controller.document.history(DateTime.now());
            return Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    '最近 30 天的小事',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                ),
                Expanded(
                  child: entries.isEmpty
                      ? const Center(child: Text('完成一件小事，它就会来到这里。'))
                      : ListView.builder(
                          itemCount: entries.length,
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            return ListTile(
                              leading: Icon(
                                entry.completed
                                    ? Icons.check_circle_outline
                                    : Icons.radio_button_unchecked,
                                color: entry.completed
                                    ? const Color(0xff719a7e)
                                    : Colors.grey,
                              ),
                              title: Text(entry.task.title),
                              subtitle: Text(
                                '${dayKey(entry.day)} · ${entry.completed ? '已完成' : '未完成'}',
                              ),
                              trailing: entry.completed
                                  ? TextButton(
                                      onPressed: () =>
                                          _safe(() => controller.reopen(entry)),
                                      child: const Text('撤销完成'),
                                    )
                                  : null,
                              onTap: () {
                                Navigator.pop(context);
                                _menu(entry.task);
                              },
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: {
      const SingleActivator(LogicalKeyboardKey.keyN, control: true):
          const _NewIntent(),
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
          const _UndoIntent(),
      if (_compact)
        const SingleActivator(LogicalKeyboardKey.escape):
            const _FullViewIntent(),
    },
    child: Actions(
      actions: {
        _NewIntent: CallbackAction<_NewIntent>(
          onInvoke: (_) {
            if (_compact) {
              unawaited(_edit());
            } else {
              _quickFocus.requestFocus();
            }
            return null;
          },
        ),
        _FullViewIntent: CallbackAction<_FullViewIntent>(
          onInvoke: (_) {
            if (_compact)
              unawaited(_safe(() => widget.window!.setCompact(false)));
            return null;
          },
        ),
        _UndoIntent: CallbackAction<_UndoIntent>(
          onInvoke: (_) {
            final focusedContext = FocusManager.instance.primaryFocus?.context;
            if (focusedContext != null &&
                Actions.maybeFind<UndoTextIntent>(focusedContext) != null) {
              Actions.invoke(
                focusedContext,
                const UndoTextIntent(SelectionChangedCause.keyboard),
              );
              return null;
            }
            _safe(controller.undo);
            return null;
          },
        ),
      },
      child: Focus(
        focusNode: _pageFocus,
        autofocus: true,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final settings = controller.document.settings;
            final items = controller.document.active(
              DateTime.now(),
              todayOnly: _today,
            );
            return Scaffold(
              backgroundColor: const Color(0xfffcfaf7).withValues(
                alpha: (widget.window?.enabled ?? false)
                    ? widget.window!.opacity / 100
                    : 1,
              ),
              body: SafeArea(
                child: _compact
                    ? _compactBody(items, settings)
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
                        child: _AdaptiveViewport(
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.bubble_chart_outlined,
                                    color: Color(0xff947caf),
                                    size: 29,
                                  ),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                    child: Text(
                                      '小事星球',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 22,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: '玩法与小世界',
                                    onPressed: () => _play(),
                                    icon: const Icon(
                                      Icons.auto_awesome_outlined,
                                    ),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  IconButton(
                                    tooltip: '完成与漏做历史',
                                    onPressed: _history,
                                    icon: const Icon(Icons.history),
                                  ),
                                  IconButton(
                                    tooltip: '设置与备份',
                                    onPressed: () => showDialog<void>(
                                      context: context,
                                      builder: (_) => SettingsPanel(
                                        controller: controller,
                                        reminders: widget.reminders,
                                      ),
                                    ),
                                    icon: const Icon(Icons.tune),
                                  ),
                                  if (widget.window?.enabled ?? false)
                                    _windowMenu(),
                                ],
                              ),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                    top: 4,
                                    bottom: 12,
                                  ),
                                  child: Text(
                                    items.isEmpty
                                        ? '今天，给自己留一点轻松。'
                                        : '${items.length} 件小事，慢慢来就好。',
                                    style: const TextStyle(
                                      color: Color(0xff817988),
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _quick,
                                      focusNode: _quickFocus,
                                      maxLength: 240,
                                      textInputAction: TextInputAction.done,
                                      onSubmitted: (_) => _add(),
                                      decoration: InputDecoration(
                                        counterText: '',
                                        hintText: '放进一件小事…',
                                        isDense: true,
                                        suffixIcon: IconButton(
                                          tooltip: '日期、提醒和重要程度',
                                          onPressed: _adding || _editing
                                              ? null
                                              : () => _edit(),
                                          icon: const Icon(
                                            Icons.tune,
                                            size: 19,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton.filled(
                                    tooltip: '添加小事',
                                    onPressed: _adding ? null : _add,
                                    icon: const Icon(Icons.add),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  ChoiceChip(
                                    label: const Text('今天'),
                                    selected: _today,
                                    showCheckmark: false,
                                    onSelected: (_) =>
                                        setState(() => _today = true),
                                  ),
                                  const SizedBox(width: 6),
                                  ChoiceChip(
                                    label: const Text('全部'),
                                    selected: !_today,
                                    showCheckmark: false,
                                    onSelected: (_) =>
                                        setState(() => _today = false),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: SizedBox(
                                        width:
                                            MediaQuery.textScalerOf(
                                              context,
                                            ).scale(70) +
                                            24,
                                        child: DropdownButtonHideUnderline(
                                          child: DropdownButton<DisplayMode>(
                                            value: settings.display,
                                            isExpanded: true,
                                            alignment:
                                                AlignmentDirectional.centerEnd,
                                            items: const [
                                              DropdownMenuItem(
                                                value: DisplayMode.bubbles,
                                                child: Text(
                                                  '◌  泡泡',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                              DropdownMenuItem(
                                                value: DisplayMode.papers,
                                                child: Text(
                                                  '▱  纸片',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                              DropdownMenuItem(
                                                value: DisplayMode.cards,
                                                child: Text(
                                                  '▣  卡牌',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                            ],
                                            onChanged: (value) => _safe(
                                              () => controller.updateSettings(
                                                (current) => current.copyWith(
                                                  display: value,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (settings.display == DisplayMode.bubbles)
                                Row(
                                  children: [
                                    Expanded(
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: SizedBox(
                                          width:
                                              MediaQuery.textScalerOf(
                                                context,
                                              ).scale(144) +
                                              24,
                                          child: DropdownButtonHideUnderline(
                                            child: DropdownButton<MotionMode>(
                                              value: settings.motion,
                                              isDense: true,
                                              isExpanded: true,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                    fontSize: 12,
                                                    color: const Color(
                                                      0xff777180,
                                                    ),
                                                  ),
                                              items: const [
                                                DropdownMenuItem(
                                                  value: MotionMode.opening,
                                                  child: Text(
                                                    '开场弹跳 → 慢慢安静',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                DropdownMenuItem(
                                                  value: MotionMode.gentle,
                                                  child: Text(
                                                    '一直轻轻漂浮',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                DropdownMenuItem(
                                                  value: MotionMode.lively,
                                                  child: Text(
                                                    '一直活泼弹跳',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              ],
                                              onChanged: (value) => _safe(
                                                () => controller.updateSettings(
                                                  (current) => current.copyWith(
                                                    motion: value,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '再弹一次',
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () =>
                                          setState(() => _replay++),
                                      icon: const Icon(Icons.replay, size: 18),
                                    ),
                                    IconButton(
                                      tooltip: settings.paused
                                          ? '继续运动'
                                          : '暂停运动',
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () => _safe(
                                        () => controller.updateSettings(
                                          (current) => current.copyWith(
                                            paused: !current.paused,
                                          ),
                                        ),
                                      ),
                                      icon: Icon(
                                        settings.paused
                                            ? Icons.play_arrow
                                            : Icons.pause,
                                        size: 18,
                                      ),
                                    ),
                                  ],
                                ),
                              Expanded(child: _taskStage(items, settings)),
                              SizedBox(
                                height: 38,
                                child: controller.canUndo
                                    ? Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              controller.undoLabel ?? '',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: () =>
                                                _safe(controller.undo),
                                            child: const Text('撤销'),
                                          ),
                                        ],
                                      )
                                    : Center(
                                        child: Text(
                                          switch (settings.display) {
                                            DisplayMode.bubbles =>
                                              '轻点戳破 · 长按编辑 · 越重要越紧急，越大',
                                            DisplayMode.papers => '做完一件，轻轻收进口袋',
                                            DisplayMode.cards => '向右划走，或点 ✓ 完成',
                                          },
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: Color(0xff9b91a2),
                                          ),
                                        ),
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

class _NewIntent extends Intent {
  const _NewIntent();
}

class _AdaptiveViewport extends StatelessWidget {
  const _AdaptiveViewport({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: SizedBox(
        height: constraints.maxHeight < 500 ? 500 : constraints.maxHeight,
        child: child,
      ),
    ),
  );
}

class _UndoIntent extends Intent {
  const _UndoIntent();
}

class _FullViewIntent extends Intent {
  const _FullViewIntent();
}
