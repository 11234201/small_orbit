import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/focus_session.dart';
import 'package:small_orbit/core/play_settings.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/platform/focus_service.dart';
import 'package:small_orbit/ui/playground_panel.dart';
import 'widget_test.dart' show MemoryStore;

class FailingEndFocus extends FocusService {
  FailingEndFocus(super.controller);
  @override
  Future<void> end() async => throw StateError('injected focus save failure');
}

class PlayFixture {
  final now = DateTime(2026, 11, 14, 12);
  late final controller = OrbitController(MemoryStore(), clock: () => now);
  late final focus = FocusService(controller);
  Future<void> initialize() async {
    await controller.initialize();
    for (var i = 0; i < 22; i++) {
      await controller.upsert(
        OrbitTask(
          id: 'play$i',
          title: ['读一小节书', '给绿植浇水', '整理桌面', '出门散步', '写下今天的想法'][i % 5],
          createdAt: now,
          estimatedMinutes: i % 2 == 0 ? 5 : 30,
          energy: TaskEnergy.light,
        ),
      );
      if (i < 20)
        await controller.complete(
          controller.document
              .active(now)
              .firstWhere((t) => t.task.id == 'play$i'),
        );
    }
  }

  Widget app(int page, {double scale = 1}) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      fontFamilyFallback: const ['NotoColorEmoji'],
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff8b72ab)),
      scaffoldBackgroundColor: const Color(0xfffcfaf7),
    ),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: PlaygroundPanel(
      controller: controller,
      focus: focus,
      initialPage: page,
      initialTask: page == 2 ? controller.document.active(now).first : null,
    ),
  );
  void dispose() {
    focus.dispose();
    controller.dispose();
  }
}

void main() {
  testWidgets(
    'a stale running session still exposes the end action for retry',
    (tester) async {
      final fixture = PlayFixture();
      await fixture.initialize();
      fixture.focus.session = FocusSession(
        id: 'stale',
        taskId: 'deleted',
        key: 'once',
        taskDay: null,
        repeat: RepeatKind.none,
        durationSeconds: 1500,
        remainingSeconds: 1500,
        deadline: fixture.now.add(const Duration(minutes: 25)),
        phase: FocusPhase.running,
      );
      await tester.pumpWidget(fixture.app(2));
      await tester.pumpAndSettle();
      expect(find.text('结束这段'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      fixture.dispose();
    },
  );
  testWidgets('failed focus switch keeps the drawn task on its original page', (
    tester,
  ) async {
    final fixture = PlayFixture();
    await fixture.initialize();
    final previous = fixture.controller.document.active(fixture.now).first;
    final focus = FailingEndFocus(fixture.controller)
      ..session = FocusSession(
        id: 'running',
        taskId: previous.task.id,
        key: previous.key,
        taskDay: null,
        repeat: RepeatKind.none,
        durationSeconds: 1500,
        remainingSeconds: 1500,
        deadline: fixture.now.add(const Duration(minutes: 25)),
        phase: FocusPhase.running,
      );
    await tester.pumpWidget(
      MaterialApp(
        home: PlaygroundPanel(
          controller: fixture.controller,
          focus: focus,
          initialPage: 3,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final draw = find.widgetWithText(FilledButton, '抽一件');
    await tester.ensureVisible(draw);
    await tester.tap(draw);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('放进专注轨道'));
    await tester.tap(find.text('放进专注轨道'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '继续'));
    await tester.pumpAndSettle();
    expect(find.text('放进专注轨道'), findsOneWidget);
    expect(focus.session!.phase, FocusPhase.running);
    expect(find.textContaining('操作未完成'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    focus.dispose();
    fixture.dispose();
  });
  testWidgets(
    'selecting another task after a finished focus shows a fresh timer',
    (tester) async {
      final fixture = PlayFixture();
      await fixture.initialize();
      final items = fixture.controller.document.active(fixture.now);
      final previous = items.first;
      fixture.focus.session = FocusSession(
        id: 'finished',
        taskId: previous.task.id,
        key: previous.key,
        taskDay: null,
        repeat: RepeatKind.none,
        durationSeconds: 1500,
        remainingSeconds: 0,
        deadline: fixture.now,
        phase: FocusPhase.finished,
      );
      await tester.pumpWidget(fixture.app(2));
      await tester.pumpAndSettle();
      expect(find.text('0:00'), findsOneWidget);
      final target = find.widgetWithText(ListTile, items.last.task.title);
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(find.text('25:00'), findsOneWidget);
      expect(find.text('准备开始'), findsOneWidget);
      expect(find.text('这一段结束了'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      fixture.dispose();
    },
  );
  for (final size in [
    const Size(260, 300),
    const Size(390, 720),
    const Size(900, 760),
  ]) {
    testWidgets('five play pages fit $size with large text', (tester) async {
      final fixture = PlayFixture();
      await fixture.initialize();
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      for (var page = 0; page < 5; page++) {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(fixture.app(page, scale: 1.8));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'page $page');
      }
      await tester.pumpWidget(const SizedBox());
      fixture.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }
  testWidgets('material selection persists, drawing never completes tasks', (
    tester,
  ) async {
    final fixture = PlayFixture();
    await fixture.initialize();
    await tester.pumpWidget(fixture.app(0));
    await tester.pumpAndSettle();
    final soap = find.widgetWithText(ChoiceChip, '肥皂泡');
    await tester.ensureVisible(soap);
    await tester.tap(soap);
    await tester.pumpAndSettle();
    expect(fixture.controller.document.settings.material, BubbleMaterial.soap);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(fixture.app(3));
    await tester.pumpAndSettle();
    final before = fixture.controller.document.activeMemories.length;
    final draw = find.widgetWithText(FilledButton, '抽一件');
    await tester.ensureVisible(draw);
    await tester.tap(draw);
    await tester.pumpAndSettle();
    expect(find.text('放进专注轨道'), findsOneWidget);
    expect(fixture.controller.document.activeMemories.length, before);
    await tester.pumpWidget(const SizedBox());
    fixture.dispose();
  });
}
