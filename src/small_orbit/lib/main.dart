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
    final loadedController = controller;
    _windowService?.dispose();
    final window = WindowService(
      onPrepareToQuit: () async {
        await loadedController.closeWrites(afterDrain: reminders.stop);
        reminders.dispose();
      },
    )..register();
    _windowService = window;
    runApp(
      OrbitApp(controller: controller, reminders: reminders, window: window),
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
  });
  final OrbitController controller;
  final ReminderService reminders;
  final WindowService? window;
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
    home: OrbitHome(controller: controller, reminders: reminders),
  );
}

class OrbitHome extends StatefulWidget {
  const OrbitHome({
    super.key,
    required this.controller,
    required this.reminders,
  });
  final OrbitController controller;
  final ReminderService reminders;
  @override
  State<OrbitHome> createState() => _OrbitHomeState();
}

class _OrbitHomeState extends State<OrbitHome> with WidgetsBindingObserver {
  final TextEditingController _quick = TextEditingController();
  final FocusNode _quickFocus = FocusNode();
  bool _today = true, _adding = false, _editing = false;
  int _replay = 0;
  OrbitController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.reminders.addListener(_reminderChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller.notice != null) _message(controller.notice!);
      _reminderChanged();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.reminders.removeListener(_reminderChanged);
    _quick.dispose();
    _quickFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.reminders.tick(forceSync: true));
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
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Text(
                task.title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑这件小事'),
              onTap: () => Navigator.pop(context, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(task.repeat == RepeatKind.none ? '删除任务' : '删除整个重复任务'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
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
    },
    child: Actions(
      actions: {
        _NewIntent: CallbackAction<_NewIntent>(
          onInvoke: (_) {
            _quickFocus.requestFocus();
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
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final settings = controller.document.settings;
          final items = controller.document.active(
            DateTime.now(),
            todayOnly: _today,
          );
          return Scaffold(
            body: SafeArea(
              child: Padding(
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
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
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
                          if (Platform.isWindows)
                            PopupMenuButton<String>(
                              tooltip: '收起窗口',
                              icon: const Icon(Icons.expand_more),
                              onSelected: (value) =>
                                  ReminderService.channel.invokeMethod(value),
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'hide',
                                  child: Text('收进托盘'),
                                ),
                                PopupMenuItem(
                                  value: 'minimize',
                                  child: Text('最小化'),
                                ),
                                PopupMenuItem(
                                  value: 'quit',
                                  child: Text('退出并停止提醒'),
                                ),
                              ],
                            ),
                        ],
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4, bottom: 12),
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
                                  icon: const Icon(Icons.tune, size: 19),
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
                            onSelected: (_) => setState(() => _today = true),
                          ),
                          const SizedBox(width: 6),
                          ChoiceChip(
                            label: const Text('全部'),
                            selected: !_today,
                            showCheckmark: false,
                            onSelected: (_) => setState(() => _today = false),
                          ),
                          const Spacer(),
                          DropdownButtonHideUnderline(
                            child: DropdownButton<DisplayMode>(
                              value: settings.display,
                              items: const [
                                DropdownMenuItem(
                                  value: DisplayMode.bubbles,
                                  child: Text('◌  泡泡'),
                                ),
                                DropdownMenuItem(
                                  value: DisplayMode.papers,
                                  child: Text('▱  纸片'),
                                ),
                                DropdownMenuItem(
                                  value: DisplayMode.cards,
                                  child: Text('▣  卡牌'),
                                ),
                              ],
                              onChanged: (value) => _safe(
                                () => controller.updateSettings(
                                  (current) => current.copyWith(display: value),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (settings.display == DisplayMode.bubbles)
                        Row(
                          children: [
                            DropdownButtonHideUnderline(
                              child: DropdownButton<MotionMode>(
                                value: settings.motion,
                                isDense: true,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      fontSize: 12,
                                      color: const Color(0xff777180),
                                    ),
                                items: const [
                                  DropdownMenuItem(
                                    value: MotionMode.opening,
                                    child: Text('开场弹跳 → 慢慢安静'),
                                  ),
                                  DropdownMenuItem(
                                    value: MotionMode.gentle,
                                    child: Text('一直轻轻漂浮'),
                                  ),
                                  DropdownMenuItem(
                                    value: MotionMode.lively,
                                    child: Text('一直活泼弹跳'),
                                  ),
                                ],
                                onChanged: (value) => _safe(
                                  () => controller.updateSettings(
                                    (current) =>
                                        current.copyWith(motion: value),
                                  ),
                                ),
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              tooltip: '再弹一次',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => setState(() => _replay++),
                              icon: const Icon(Icons.replay, size: 18),
                            ),
                            IconButton(
                              tooltip: settings.paused ? '继续运动' : '暂停运动',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _safe(
                                () => controller.updateSettings(
                                  (current) =>
                                      current.copyWith(paused: !current.paused),
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
                      Expanded(
                        child: TaskStage(
                          items: items,
                          settings: settings,
                          replay: _replay,
                          onComplete: controller.complete,
                          onEdit: _menu,
                          onDelete: (task) =>
                              _safe(() => controller.delete(task.id)),
                        ),
                      ),
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
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () => _safe(controller.undo),
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
