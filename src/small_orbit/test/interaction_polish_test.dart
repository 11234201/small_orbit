import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/bubble_engine.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/ui/task_stage.dart';

TaskOccurrence occurrence(
  String id, {
  String? title,
  int importance = 2,
  int urgency = 2,
}) => OrbitTask(
  id: id,
  title: title ?? '小事$id',
  createdAt: DateTime(2026, 11, 10),
  importance: importance,
  urgency: urgency,
).activeAt(DateTime(2026, 11, 10))!;

Widget stage({
  required List<TaskOccurrence> items,
  DisplayMode mode = DisplayMode.bubbles,
  bool reduceMotion = true,
  Future<void> Function(TaskOccurrence)? complete,
  ValueChanged<OrbitTask>? edit,
  double textScale = 1,
}) => MaterialApp(
  home: Scaffold(
    body: MediaQuery(
      data: MediaQueryData(
        size: const Size(390, 700),
        textScaler: TextScaler.linear(textScale),
      ),
      child: SizedBox(
        width: 390,
        height: 700,
        child: TaskStage(
          items: items,
          settings: AppSettings(
            display: mode,
            reduceMotion: reduceMotion,
            motion: MotionMode.lively,
          ),
          onComplete: complete ?? (_) async {},
          onEdit: edit ?? (_) {},
          onDelete: (_) {},
          replay: 0,
        ),
      ),
    ),
  ),
);

void main() {
  test(
    'held bubble keeps identity and position when another task disappears',
    () {
      final engine = BubbleEngine();
      final first = occurrence('first'), retained = occurrence('retained');
      engine.configure(
        [first, retained],
        const Size(390, 500),
        MotionMode.lively,
        false,
      );
      engine.step(.02);
      engine.holdIdentity(retained.identity, 'press', true);
      final position = engine.bodies.last.position;
      engine.configure(
        [retained],
        const Size(390, 500),
        MotionMode.lively,
        false,
      );
      engine.holdIdentity(first.identity, 'press', false);
      engine.step(.02);
      expect(engine.bodies.single.position, position);
      expect(engine.bodies.single.held, isTrue);
      engine.holdIdentity(retained.identity, 'press', false);
      engine.step(.02);
      expect(engine.bodies.single.position, isNot(position));
      engine.dispose();
    },
  );

  test('stationary physics does not request unnecessary repaint', () {
    final engine = BubbleEngine();
    final item = occurrence('quiet');
    var repaints = 0;
    engine.addListener(() => repaints++);
    engine.configure([item], const Size(390, 500), MotionMode.lively, true);
    for (var i = 0; i < 120; i++) {
      engine.step(1 / 60);
    }
    expect(repaints, 0);
    engine.paused = false;
    engine.holdIdentity(item.identity, 'focus', true);
    engine.step(.02);
    expect(engine.moving, isFalse);
    expect(repaints, 0);
    engine.holdIdentity(item.identity, 'focus', false);
    engine.step(.02);
    expect(repaints, 1);
    engine.dispose();
  });

  test(
    'fixed group capacity keeps remaining bubble size and edge position stable',
    () {
      final engine = BubbleEngine();
      final items = List.generate(5, (index) => occurrence('fixed$index'));
      engine.configure(
        items,
        const Size(320, 280),
        MotionMode.opening,
        true,
        capacity: 6,
      );
      final body = engine.bodies.last;
      final radius = body.radius;
      body.position = Offset(body.radius, 280 - body.radius);
      engine.holdIdentity(body.id, 'press', true);
      final position = body.position;
      engine.configure(
        items.sublist(1),
        const Size(320, 280),
        MotionMode.opening,
        true,
        capacity: 6,
      );
      expect(engine.bodies.last.radius, radius);
      expect(engine.bodies.last.position, position);
      expect(engine.bodies.last.held, isTrue);
      engine.dispose();
    },
  );

  for (final mode in DisplayMode.values) {
    testWidgets('$mode restores the task after completion fails', (
      tester,
    ) async {
      var attempts = 0;
      await tester.pumpWidget(
        stage(
          items: [occurrence('retry')],
          mode: mode,
          complete: (_) async {
            attempts++;
            throw StateError('write failed');
          },
        ),
      );
      final button = switch (mode) {
        DisplayMode.bubbles => find.text('小事retry'),
        DisplayMode.papers => find.byTooltip('收进口袋'),
        DisplayMode.cards => find.text('完成，划走'),
      };
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(attempts, 1);
      expect(find.text('小事retry'), findsOneWidget);
      expect(find.text('没有完成保存，这件小事仍在原处，请重试。'), findsOneWidget);
      await tester.tap(button);
      await tester.pump();
      expect(attempts, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('long task can be found and read in overview from bubbles', (
    tester,
  ) async {
    final longTitle = '记得带上这份完整的长标题，'.padRight(220, '书');
    final items = List.generate(
      100,
      (index) =>
          occurrence('$index', title: index == 79 ? longTitle : '普通任务$index'),
    );
    await tester.pumpWidget(stage(items: items));
    await tester.tap(find.text('1 / 17 · 共 100 件'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '完整的长标题');
    await tester.pump();
    expect(find.widgetWithText(ListTile, longTitle), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, longTitle));
    await tester.pumpAndSettle();
    expect(find.text('14 / 17 · 共 100 件'), findsOneWidget);
    expect(find.text(longTitle), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'save starts immediately and failure restores before exit animation ends',
    (tester) async {
      var started = false;
      await tester.pumpWidget(
        stage(
          items: [occurrence('immediate')],
          reduceMotion: false,
          complete: (_) async {
            started = true;
            throw StateError('write failed');
          },
        ),
      );
      await tester.tap(find.text('小事immediate'));
      await tester.pump();
      expect(started, isTrue);
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
      expect(find.text('没有完成保存，这件小事仍在原处，请重试。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending completion does not leave a ghost after switching modes',
    (tester) async {
      final pending = Completer<void>();
      var items = [occurrence('first'), occurrence('second')];
      var mode = DisplayMode.bubbles;
      var completions = 0;
      Future<void> complete(TaskOccurrence item) async {
        completions++;
        await pending.future;
        items = items
            .where((value) => value.identity != item.identity)
            .toList();
      }

      await tester.pumpWidget(
        stage(items: items, mode: mode, complete: complete),
      );
      await tester.tap(find.text('小事first'));
      await tester.pump();
      mode = DisplayMode.cards;
      await tester.pumpWidget(
        stage(items: items, mode: mode, complete: complete),
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '完成，划走'))
            .onPressed,
        isNull,
      );
      pending.complete();
      await tester.pump();
      await tester.pumpWidget(
        stage(items: items, mode: mode, complete: complete),
      );
      expect(completions, 1);
      expect(find.text('小事first'), findsNothing);
      expect(find.text('小事second'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'moving bubble stays under a held pointer and supports keyboard activation',
    (tester) async {
      var completions = 0;
      await tester.pumpWidget(
        stage(
          items: [occurrence('touch')],
          reduceMotion: false,
          complete: (_) async {
            completions++;
          },
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      final center = tester.getCenter(find.text('小事touch'));
      final pointer = await tester.startGesture(
        center,
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getCenter(find.text('小事touch')), center);
      await pointer.up();
      await tester.pump(const Duration(milliseconds: 200));
      expect(completions, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNotNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 200));
      expect(completions, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('large text and small stage stay usable across all modes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    for (final mode in DisplayMode.values) {
      await tester.pumpWidget(
        stage(
          items: List.generate(
            24,
            (i) => occurrence('$i', title: '一段更长的小事标题$i'),
          ),
          mode: mode,
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$mode at large text');
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'hidden and empty bubble stages stop frames and resume can restart',
    (tester) async {
      await tester.pumpWidget(
        stage(items: [occurrence('moving')], reduceMotion: false),
      );
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(tester.binding.transientCallbackCount, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpWidget(stage(items: [], reduceMotion: false));
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
