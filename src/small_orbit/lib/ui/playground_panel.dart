import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import '../core/completion_collection.dart';
import '../core/focus_session.dart';
import '../core/island_world.dart';
import '../core/orbit_controller.dart';
import '../core/play_settings.dart';
import '../core/task_model.dart';
import '../core/task_picker.dart';
import '../platform/focus_service.dart';
import 'task_editor.dart';

class PlaygroundPanel extends StatefulWidget {
  const PlaygroundPanel({
    super.key,
    required this.controller,
    required this.focus,
    this.initialPage = 0,
    this.initialTask,
  });
  final OrbitController controller;
  final FocusService focus;
  final int initialPage;
  final TaskOccurrence? initialTask;
  @override
  State<PlaygroundPanel> createState() => _PlaygroundPanelState();
}

class _PlaygroundPanelState extends State<PlaygroundPanel> {
  late int _page;
  final _picker = TaskPicker();
  PickRule _rule = PickRule.random;
  bool _todayOnly = true, _busy = false;
  TaskOccurrence? _drawn, _selected;
  int _minutes = 25, _starPage = 0;
  late String _day;
  String? _decoration;
  final Map<String, Offset> _draftPositions = {};
  OrbitDocument? _cachedCollection;
  List<CompletionMemory> _cachedActive = const [];
  int _cachedAnonymous = 0;
  void _refreshCollection() {
    if (identical(_cachedCollection, document)) return;
    _cachedCollection = document;
    _cachedActive = document.activeMemories.toList();
    final taskIds = document.tasks.map((t) => t.id).toSet();
    _cachedAnonymous = _cachedActive
        .where((m) => !taskIds.contains(m.taskId))
        .length;
  }

  List<CompletionMemory> get _activeMemories {
    _refreshCollection();
    return _cachedActive;
  }

  OrbitController get controller => widget.controller;
  FocusService get focus => widget.focus;
  OrbitDocument get document => controller.document;
  @override
  void initState() {
    super.initState();
    _selected = widget.initialTask;
    _page = widget.initialPage;
    _day = dayKey(controller.clock());
    controller.addListener(_changed);
    focus.addListener(_focusChanged);
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    focus.removeListener(_focusChanged);
    super.dispose();
  }

  void _focusChanged() {
    if (mounted && _page == 2 && TickerMode.valuesOf(context).enabled)
      setState(() {});
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<bool> _run(Future<void> Function() action) async {
    if (_busy || !mounted) return false;
    setState(() => _busy = true);
    try {
      await action();
      return true;
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('操作未完成：$e')));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续'),
            ),
          ],
        ),
      ) ??
      false;
  Future<int?> _number(String title, int current, int maximum) async {
    final input = TextEditingController(text: '$current');
    final value = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: input,
            keyboardType: TextInputType.number,
            onChanged: (_) => update(() {}),
            decoration: InputDecoration(labelText: '分钟（1～$maximum）'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed:
                  (int.tryParse(input.text) ?? 0) >= 1 &&
                      (int.tryParse(input.text) ?? 0) <= maximum
                  ? () => Navigator.pop(context, int.parse(input.text))
                  : null,
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    input.dispose();
    return value;
  }

  @override
  Widget build(BuildContext context) {
    const titles = ['手感与材质', '今日星座', '专注卫星', '抽一件', '我的小岛'];
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(titles[_page]),
          leading: IconButton(
            tooltip: '返回待办',
            onPressed: _busy ? null : () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back),
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: List.generate(
                    titles.length,
                    (i) => Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(titles[i]),
                        selected: _page == i,
                        showCheckmark: false,
                        onSelected: _busy
                            ? null
                            : (_) => setState(() => _page = i),
                      ),
                    ),
                  ),
                ),
              ),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: switch (_page) {
                        0 => _materials(),
                        1 => _stars(),
                        2 => _focus(),
                        3 => _draw(),
                        _ => _island(),
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _intro(String title, String caption, {Widget? child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    margin: const EdgeInsets.only(bottom: 18),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(26),
      gradient: const LinearGradient(
        colors: [Color(0xffeae2f6), Color(0xffe1f0ef)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          caption,
          style: const TextStyle(height: 1.5, color: Color(0xff645b71)),
        ),
        if (child != null) ...[const SizedBox(height: 16), child],
      ],
    ),
  );

  Widget _materials() {
    final settings = document.settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _intro(
          '把桌面变成小宇宙',
          '在空白处按住，带着泡泡绕一小圈。松手后，它们会慢慢散开。',
          child: Center(
            child: SizedBox(
              width: 220,
              height: 130,
              child: CustomPaint(painter: _MaterialPreview(settings.material)),
            ),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('空白处引力'),
          subtitle: const Text('暂停或减少动态时停用'),
          value: settings.gravityEnabled,
          onChanged: _busy
              ? null
              : (v) => _run(
                  () => controller.updateSettings(
                    (s) => s.copyWith(gravityEnabled: v),
                  ),
                ),
        ),
        const Text('物理手感', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: GravityStyle.values
              .map(
                (g) => ChoiceChip(
                  label: Text(gravityLabels[g.index]),
                  selected: settings.gravity == g,
                  onSelected: _busy
                      ? null
                      : (_) => _run(
                          () => controller.updateSettings(
                            (s) => s.copyWith(gravity: g),
                          ),
                        ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 20),
        const Text('泡泡材质', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: BubbleMaterial.values
              .map(
                (m) => ChoiceChip(
                  label: Text(materialLabels[m.index]),
                  selected: settings.material == m,
                  onSelected: _busy
                      ? null
                      : (_) => _run(
                          () => controller.updateSettings(
                            (s) => s.copyWith(material: m),
                          ),
                        ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('轻音效'),
          subtitle: const Text('完成时播放一声轻提示'),
          value: focus.sound,
          onChanged: _busy
              ? null
              : (v) => _run(() => focus.preferences(sound: v)),
        ),
        if (Platform.isAndroid)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('轻触觉反馈'),
            value: focus.haptics,
            onChanged: _busy
                ? null
                : (v) => _run(() => focus.preferences(haptics: v)),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('减少动态效果'),
          value: settings.reduceMotion,
          onChanged: _busy
              ? null
              : (v) => _run(
                  () => controller.updateSettings(
                    (s) => s.copyWith(reduceMotion: v),
                  ),
                ),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => _run(
                  () => controller.updateSettings(
                    (s) => s.copyWith(
                      material: BubbleMaterial.classic,
                      gravity: GravityStyle.weightless,
                      gravityEnabled: false,
                    ),
                  ),
                ),
          child: const Text('恢复经典材质与手感'),
        ),
      ],
    );
  }

  Widget _stars() {
    final days = {
      dayKey(controller.clock()),
      ..._activeMemories.map((m) => m.day),
    }.toList()..sort((a, b) => b.compareTo(a));
    final dateIndex = days.indexOf(_day);
    final all = document.memories.where((m) => m.day == _day).toList();
    final pages = max(1, (all.length / constellationPageSize).ceil());
    final page = _starPage.clamp(0, pages - 1);
    final stars = all
        .skip(page * constellationPageSize)
        .take(constellationPageSize)
        .toList();
    final count = all.where((m) => m.active).length;
    return Column(
      children: [
        _intro('$count 件小事，留在星空', '每颗星都来自一次完成。轻点星星，看看那天的自己。'),
        Row(
          children: [
            IconButton(
              tooltip: '更早一天',
              onPressed: dateIndex >= 0 && dateIndex < days.length - 1
                  ? () => setState(() {
                      _day = days[dateIndex + 1];
                      _starPage = 0;
                    })
                  : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                _day,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18),
              ),
            ),
            IconButton(
              tooltip: '更新一天',
              onPressed: dateIndex > 0
                  ? () => setState(() {
                      _day = days[dateIndex - 1];
                      _starPage = 0;
                    })
                  : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: SizedBox(
            height: 340,
            child: LayoutBuilder(
              builder: (context, box) => Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(painter: ConstellationPainter(stars)),
                  ),
                  if (count == 0)
                    const Center(
                      child: Text(
                        '天空留着位置，等一件小事完成。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  for (var i = 0; i < stars.length; i++)
                    if (stars[i].active)
                      Positioned(
                        left:
                            starPosition(i, stars[i].seed).dx *
                            (box.maxWidth - 44),
                        top:
                            starPosition(i, stars[i].seed).dy *
                            (box.maxHeight - 44),
                        width: 44,
                        height: 44,
                        child: IconButton(
                          tooltip: '查看完成纪念 ${i + 1}',
                          onPressed: () => _memoryDetail(stars[i]),
                          icon: const Icon(
                            Icons.star_rounded,
                            color: Color(0xffffe5a0),
                            size: 20,
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ),
        ),
        if (pages > 1)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                onPressed: page > 0
                    ? () => setState(() => _starPage = page - 1)
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  '星图 ${page + 1} / $pages',
                  textAlign: TextAlign.center,
                ),
              ),
              IconButton(
                onPressed: page < pages - 1
                    ? () => setState(() => _starPage = page + 1)
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        if (all.any((m) => m.inferred))
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('旧记录的日期按升级时设备时区推算。'),
          ),
      ],
    );
  }

  void _memoryDetail(CompletionMemory memory) {
    final task = document.tasks.where((t) => t.id == memory.taskId).firstOrNull;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(task?.title ?? '一件已经完成的小事'),
        content: Text(
          '${memory.day}\n${task == null ? '原任务已删除，这颗星作为匿名纪念保留。' : '这是你留给自己的完成纪念。'}${memory.inferred ? '\n日期由旧记录推算。' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('收好这颗星'),
          ),
        ],
      ),
    );
  }

  TaskOccurrence? get _currentFocus {
    final session = focus.session;
    if (session != null &&
        (session.ongoing ||
            (session.phase == FocusPhase.finished && _selected == null))) {
      return document
          .active(controller.clock(), todayOnly: false)
          .where(session.matches)
          .firstOrNull;
    }
    final selected = _selected;
    return selected == null
        ? null
        : document
              .active(controller.clock(), todayOnly: false)
              .where(
                (i) =>
                    i.identity == selected.identity &&
                    i.day == selected.day &&
                    i.task.repeat == selected.task.repeat,
              )
              .firstOrNull;
  }

  Widget _focus() {
    final item = _currentFocus;
    final storedSession = focus.session;
    final session =
        storedSession != null &&
            (storedSession.ongoing ||
                (item != null &&
                    storedSession.phase == FocusPhase.finished &&
                    storedSession.matches(item)))
        ? storedSession
        : null;
    final ongoing = session?.ongoing ?? false;
    final remaining = ongoing
        ? focus.remaining
        : session?.phase == FocusPhase.finished
        ? 0
        : _minutes * 60;
    final time =
        '${remaining ~/ 60}:${(remaining % 60).toString().padLeft(2, '0')}';
    final items = document.active(controller.clock());
    return Column(
      children: [
        _intro('先陪这一件事转一圈', '选一件小事，或把下方任务拖入轨道。到点后，由你决定是否完成。'),
        DragTarget<TaskOccurrence>(
          onWillAcceptWithDetails: (_) => !ongoing && !_busy,
          onAcceptWithDetails: (d) => setState(() => _selected = d.data),
          builder: (context, candidates, rejected) => Container(
            height: 240,
            width: double.infinity,
            decoration: BoxDecoration(
              color: candidates.isEmpty
                  ? const Color(0xfff1edf8)
                  : const Color(0xffe0efe7),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _OrbitPainter(
                      progress: ongoing && session != null
                          ? 1 - remaining / session.durationSeconds
                          : 0,
                      quiet:
                          document.settings.reduceMotion ||
                          MediaQuery.disableAnimationsOf(context),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 20,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          item?.task.title ?? '把一件小事放进轨道',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 10),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          time,
                          maxLines: 1,
                          style: const TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(switch (session?.phase) {
                          FocusPhase.running => '专注中',
                          FocusPhase.paused => '已暂停',
                          FocusPhase.finished => '这一段结束了',
                          _ => '准备开始',
                        }, maxLines: 1),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (focus.notice != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(focus.notice!),
          ),
        const SizedBox(height: 14),
        if (!ongoing)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: [
              for (final minutes in [5, 15, 25, 45])
                ChoiceChip(
                  label: Text('$minutes 分钟'),
                  selected: _minutes == minutes,
                  onSelected: (_) => setState(() => _minutes = minutes),
                ),
              ActionChip(
                label: Text(
                  [5, 15, 25, 45].contains(_minutes) ? '自定义' : '$_minutes 分钟',
                ),
                onPressed: () async {
                  final value = await _number('专注多久', _minutes, 180);
                  if (value != null && mounted)
                    setState(() => _minutes = value);
                },
              ),
            ],
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            if (!ongoing)
              FilledButton.icon(
                onPressed: item == null || _busy
                    ? null
                    : () => _run(() => focus.begin(item, _minutes)),
                icon: const Icon(Icons.play_arrow),
                label: Text(
                  session?.phase == FocusPhase.finished ? '再来一段' : '开始专注',
                ),
              ),
            if (ongoing)
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(
                        session!.phase == FocusPhase.running
                            ? focus.pause
                            : focus.resume,
                      ),
                child: Text(session!.phase == FocusPhase.running ? '暂停' : '继续'),
              ),
            if (ongoing)
              OutlinedButton(
                onPressed: _busy ? null : () => _run(focus.end),
                child: const Text('结束这段'),
              ),
            if (item != null)
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await controller.complete(item);
                        await focus.feedback();
                      }),
                icon: const Icon(Icons.check),
                label: const Text('完成这件事'),
              ),
          ],
        ),
        const SizedBox(height: 20),
        const Align(
          alignment: Alignment.centerLeft,
          child: Text('选择一件小事', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('今天的小事已经清空，可以歇一会儿。'),
          ),
        for (final candidate in items.take(30))
          LongPressDraggable<TaskOccurrence>(
            data: candidate,
            maxSimultaneousDrags: ongoing ? 0 : 1,
            feedback: Material(
              borderRadius: BorderRadius.circular(18),
              color: const Color(0xffe3d8f2),
              child: SizedBox(
                width: 180,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    candidate.task.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.radio_button_unchecked),
              title: Text(
                candidate.task.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: candidate.task.estimatedMinutes == null
                  ? null
                  : Text('预计 ${candidate.task.estimatedMinutes} 分钟'),
              onTap: _busy
                  ? null
                  : () async {
                      if (ongoing &&
                          !await _confirm('切换专注任务？', '当前这一段会结束，任务完成状态保持不变。'))
                        return;
                      if (ongoing && !await _run(focus.end)) return;
                      if (mounted) setState(() => _selected = candidate);
                    },
            ),
          ),
        if (items.length > 30) Text('显示前 30 件，可从任务概览整理后再选择。'),
      ],
    );
  }

  Widget _draw() {
    final drawn = _drawn;
    final valid = drawn == null
        ? null
        : _picker
              .candidates(
                document,
                controller.clock(),
                _rule,
                todayOnly: _todayOnly,
              )
              .where(
                (i) =>
                    i.identity == drawn.identity &&
                    i.day == drawn.day &&
                    i.task.repeat == drawn.task.repeat,
              )
              .firstOrNull;
    final count = _picker
        .candidates(document, controller.clock(), _rule, todayOnly: _todayOnly)
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _intro('让下一步轻一点', '选一个现在的状态，抽出一件小事。同一轮会尽量不重复。'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: PickRule.values
              .map(
                (r) => ChoiceChip(
                  label: Text(pickLabels[r.index]),
                  selected: _rule == r,
                  onSelected: (_) => setState(() {
                    _rule = r;
                    _drawn = null;
                  }),
                ),
              )
              .toList(),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('只从今天的小事中抽'),
          value: _todayOnly || _rule == PickRule.important,
          onChanged: _rule == PickRule.important
              ? null
              : (v) => setState(() {
                  _todayOnly = v;
                  _drawn = null;
                }),
        ),
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xfff7e8dd),
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            children: [
              const Icon(
                Icons.casino_outlined,
                size: 62,
                color: Color(0xffb4846d),
              ),
              const SizedBox(height: 16),
              Text(
                valid?.task.title ??
                    (count == 0 ? '暂时没有符合条件的小事' : '这里有 $count 件小事，等你抽一件'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, height: 1.5),
              ),
              if (count == 0)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    '可以换个条件，或在任务编辑里补充预计耗时与精力。',
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: count == 0
              ? null
              : () => setState(() {
                  _drawn = _picker.draw(
                    document,
                    controller.clock(),
                    _rule,
                    todayOnly: _todayOnly,
                  );
                }),
          icon: const Icon(Icons.shuffle),
          label: Text(valid == null ? '抽一件' : '换一件'),
        ),
        if (valid != null) ...[
          OutlinedButton(
            onPressed: _busy
                ? null
                : () async {
                    if ((focus.session?.ongoing ?? false) &&
                        !await _confirm('切换专注任务？', '结束当前这一段，把抽中的任务放进轨道。'))
                      return;
                    if (focus.session != null && !await _run(focus.end)) return;
                    if (mounted)
                      setState(() {
                        _selected = valid;
                        _page = 2;
                      });
                  },
            child: const Text('放进专注轨道'),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    await editTask(
                      context,
                      task: valid.task,
                      onSave: controller.upsert,
                    );
                  }),
            child: const Text('编辑这件事'),
          ),
        ],
      ],
    );
  }

  Offset _position(IslandDecoration d) {
    final stored = document.islandLayout[d.id];
    return _draftPositions[d.id] ??
        (stored == null ? Offset(d.x, d.y) : Offset(stored[0], stored[1]));
  }

  Widget _island() {
    final growth = _activeMemories.length;
    final unlocked = islandDecorations
        .where((d) => d.threshold <= growth)
        .toList();
    final next = islandDecorations
        .where((d) => d.threshold > growth)
        .firstOrNull;
    final chosen = unlocked.where((d) => d.id == _decoration).firstOrNull;
    // Collection totals depend on committed data, never on per-frame dragging.
    final anonymous = _cachedAnonymous;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _intro(
          '你的小岛，慢慢长大',
          '$growth 份完成纪念 · ${unlocked.length} 件装饰\n${next == null ? '岛上已经很热闹了，每件小事仍会留在星空。' : '再完成 ${next.threshold - growth} 件，遇见${next.label}。'}',
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: SizedBox(
            height: 340,
            child: LayoutBuilder(
              builder: (context, box) => Stack(
                children: [
                  const Positioned.fill(
                    child: CustomPaint(painter: _IslandPainter()),
                  ),
                  if (unlocked.isEmpty)
                    const Center(
                      child: Text(
                        '完成第一件小事，\n这里就会冒出一棵嫩芽。',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  for (final d in unlocked)
                    Positioned(
                      left: _position(d).dx * (box.maxWidth - 48),
                      top: _position(d).dy * (box.maxHeight - 48),
                      width: 48,
                      height: 48,
                      child: Semantics(
                        label: d.label,
                        button: true,
                        selected: _decoration == d.id,
                        child: GestureDetector(
                          onTap: () => setState(() => _decoration = d.id),
                          onPanStart: _busy
                              ? null
                              : (_) => setState(() => _decoration = d.id),
                          onPanUpdate: _busy
                              ? null
                              : (event) => setState(() {
                                  final old = _position(d);
                                  _draftPositions[d.id] = Offset(
                                    (old.dx +
                                            event.delta.dx /
                                                (box.maxWidth - 48))
                                        .clamp(.05, .95),
                                    (old.dy +
                                            event.delta.dy /
                                                (box.maxHeight - 48))
                                        .clamp(.1, .9),
                                  );
                                }),
                          onPanEnd: _busy
                              ? null
                              : (_) => _run(() async {
                                  final p = _position(d);
                                  try {
                                    await controller.moveDecoration(
                                      d.id,
                                      p.dx,
                                      p.dy,
                                    );
                                  } finally {
                                    _draftPositions.remove(d.id);
                                  }
                                }),
                          onPanCancel: () =>
                              setState(() => _draftPositions.remove(d.id)),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: _decoration == d.id
                                  ? Colors.white60
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Center(
                              child: Text(
                                d.symbol,
                                style: const TextStyle(
                                  fontSize: 34,
                                  fontFamilyFallback: [
                                    'NotoColorEmoji',
                                    'Segoe UI Emoji',
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        const Text('拖动装饰摆放，或选中后用方向按钮微调。离开几天，小岛也会好好等着你。'),
        Wrap(
          spacing: 6,
          children: unlocked
              .map(
                (d) => ChoiceChip(
                  label: Text('${d.symbol} ${d.label}'),
                  selected: chosen?.id == d.id,
                  onSelected: (_) => setState(() => _decoration = d.id),
                ),
              )
              .toList(),
        ),
        if (chosen != null)
          Wrap(
            alignment: WrapAlignment.center,
            children: [
              for (final direction in const [
                (Icons.arrow_left, Offset(-.03, 0), '向左'),
                (Icons.arrow_right, Offset(.03, 0), '向右'),
                (Icons.arrow_upward, Offset(0, -.03), '向上'),
                (Icons.arrow_downward, Offset(0, .03), '向下'),
              ])
                IconButton(
                  tooltip: direction.$3,
                  onPressed: _busy
                      ? null
                      : () => _run(() {
                          final p = _position(chosen) + direction.$2;
                          return controller.moveDecoration(
                            chosen.id,
                            p.dx,
                            p.dy,
                          );
                        }),
                  icon: Icon(direction.$1),
                ),
            ],
          ),
        TextButton(
          onPressed: _busy
              ? null
              : () => _run(() async {
                  await controller.tidyIsland();
                  _draftPositions.clear();
                }),
          child: const Text('一键整理小岛'),
        ),
        if (anonymous > 0)
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    if (await _confirm(
                      '清除匿名纪念？',
                      '移除 $anonymous 份已删除任务留下的纪念，星座和成长会同步减少。可先在设置导出备份。',
                    )) {
                      await _run(controller.clearAnonymousMemories);
                    }
                  },
            child: Text('管理 $anonymous 份匿名纪念'),
          ),
      ],
    );
  }
}

const constellationPageSize = 15;
Offset starPosition(int index, int seed) {
  // A small irregular constellation, with stable per-souvenir variation.
  // Positions leave room for the 44px controls at compact window sizes.
  const points = [
    Offset(.08, .16),
    Offset(.36, .07),
    Offset(.78, .05),
    Offset(.94, .28),
    Offset(.58, .26),
    Offset(.27, .35),
    Offset(.06, .52),
    Offset(.46, .48),
    Offset(.77, .49),
    Offset(.94, .70),
    Offset(.60, .72),
    Offset(.28, .66),
    Offset(.09, .91),
    Offset(.43, .94),
    Offset(.81, .94),
  ];
  return points[(index * 7) % points.length] +
      Offset((seed % 101) / 5000 - .01, ((seed ~/ 101) % 101) / 5000 - .01);
}

class ConstellationPainter extends CustomPainter {
  const ConstellationPainter(this.memories, {this.background = true});
  final List<CompletionMemory> memories;
  final bool background;
  @override
  void paint(Canvas canvas, Size size) {
    if (background)
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = const LinearGradient(
            colors: [Color(0xff19273e), Color(0xff423358)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ).createShader(Offset.zero & size),
      );
    final previous = <Offset>[];
    for (var i = 0; i < memories.length && i < constellationPageSize; i++) {
      if (!memories[i].active) continue;
      final unit = starPosition(i, memories[i].seed);
      final point = Offset(
        22 + unit.dx * max(0, size.width - 44),
        22 + unit.dy * max(0, size.height - 44),
      );
      if (previous.isNotEmpty) {
        final closest = previous.reduce(
          (a, b) => (a - point).distance < (b - point).distance ? a : b,
        );
        canvas.drawLine(
          closest,
          point,
          Paint()
            ..color = background
                ? const Color(0xffa9a8d3).withValues(alpha: .28)
                : const Color(0xff9b87b6).withValues(alpha: .16)
            ..strokeWidth = 1,
        );
      }
      canvas.drawCircle(
        point,
        3,
        Paint()
          ..color = background
              ? const Color(0xffffdf96)
              : const Color(0xffbaa0c9).withValues(alpha: .35),
      );
      previous.add(point);
    }
  }

  @override
  bool shouldRepaint(covariant ConstellationPainter oldDelegate) =>
      oldDelegate.memories != memories || oldDelegate.background != background;
}

class _MaterialPreview extends CustomPainter {
  const _MaterialPreview(this.material);
  final BubbleMaterial material;
  @override
  void paint(Canvas canvas, Size size) {
    final colors = [
      const Color(0xffceb9e6),
      const Color(0xfff2cf8d),
      const Color(0xffa6d8ee),
      const Color(0xffd8b5df),
    ];
    for (var i = 0; i < 3; i++) {
      final center = Offset(42.0 + i * 67, i == 1 ? 47 : 75);
      final rect = Rect.fromCircle(center: center, radius: i == 1 ? 40 : 30);
      canvas.drawOval(
        rect,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-.4, -.5),
            colors: [Colors.white, colors[material.index]],
          ).createShader(rect),
      );
      canvas.drawArc(
        rect.deflate(5),
        pi * 1.1,
        pi * .45,
        false,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
      if (material == BubbleMaterial.soap)
        canvas.drawOval(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..shader = const SweepGradient(
              colors: [
                Colors.pinkAccent,
                Colors.lightBlueAccent,
                Colors.lightGreenAccent,
                Colors.pinkAccent,
              ],
            ).createShader(rect),
        );
    }
  }

  @override
  bool shouldRepaint(covariant _MaterialPreview oldDelegate) =>
      oldDelegate.material != material;
}

class _OrbitPainter extends CustomPainter {
  const _OrbitPainter({required this.progress, required this.quiet});
  final double progress;
  final bool quiet;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero),
        radius = min(size.width, size.height) * .43;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = const Color(0xffd7cce8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawArc(
      rect,
      -pi / 2,
      2 * pi * progress,
      false,
      Paint()
        ..color = const Color(0xff9478ba)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );
    final angle = quiet ? -pi / 2 : progress * 2 * pi - pi / 2;
    canvas.drawCircle(
      center + Offset(cos(angle), sin(angle)) * radius,
      8,
      Paint()..color = const Color(0xffb19bd0),
    );
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.quiet != quiet;
}

class _IslandPainter extends CustomPainter {
  const _IslandPainter();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xffc8e7ed), Color(0xff9fcddf)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ).createShader(Offset.zero & size),
    );
    final island = Rect.fromCenter(
      center: Offset(size.width / 2, size.height * .57),
      width: size.width * .94,
      height: size.height * .69,
    );
    canvas.drawOval(
      island.shift(const Offset(0, 12)),
      Paint()..color = const Color(0xffc7aa7b),
    );
    canvas.drawOval(
      island,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xffd0e7ab), Color(0xff96c69b)],
        ).createShader(island),
    );
    for (var i = 0; i < 5; i++)
      canvas.drawArc(
        Rect.fromLTWH(i * size.width / 5, size.height * .88, 30, 10),
        0,
        pi,
        false,
        Paint()
          ..color = Colors.white.withValues(alpha: .4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
  }

  @override
  bool shouldRepaint(covariant _IslandPainter oldDelegate) => false;
}
