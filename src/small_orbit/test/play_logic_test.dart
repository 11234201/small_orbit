import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:small_orbit/ui/task_stage.dart';
import 'package:small_orbit/ui/bubble_surface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/bubble_engine.dart';
import 'package:small_orbit/core/focus_session.dart';
import 'package:small_orbit/core/local_store.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/play_settings.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/core/task_picker.dart';
import 'package:small_orbit/platform/focus_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 11, 14, 12);
  OrbitTask task(
    String id, {
    int? minutes,
    TaskEnergy? energy,
    int importance = 2,
    int urgency = 2,
  }) => OrbitTask(
    id: id,
    title: id,
    createdAt: now,
    estimatedMinutes: minutes,
    energy: energy,
    importance: importance,
    urgency: urgency,
  );
  testWidgets(
    'blank gravity gestures cancel without completing or editing tasks',
    (tester) async {
      var completed = 0, edited = 0;
      final item = task('gravity-target').activeAt(now)!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 600,
              child: TaskStage(
                items: [item],
                settings: const AppSettings(
                  gravityEnabled: true,
                  motion: MotionMode.gentle,
                ),
                replay: 0,
                onComplete: (_) async {
                  completed++;
                },
                onEdit: (_) {
                  edited++;
                },
                onDelete: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      final paint = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .firstWhere((p) => p.painter is BubbleSurface);
      final engine = (paint.painter! as BubbleSurface).engine;
      final blank =
          tester.getBottomRight(find.byType(Flow)) - const Offset(3, 3);
      final gesture = await tester.startGesture(blank);
      await tester.pump(const Duration(milliseconds: 100));
      expect(engine.attraction, isNotNull);
      await gesture.moveBy(const Offset(-20, -10));
      await gesture.cancel();
      await tester.pump();
      expect(engine.attraction, isNull);
      expect(completed, 0);
      expect(edited, 0);
      await tester.tap(find.text('gravity-target'));
      await tester.pump(const Duration(milliseconds: 250));
      expect(completed, 1);
      expect(engine.attraction, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test('picker honors metadata, priority and without-replacement rounds', () {
    final doc = OrbitDocument(
      tasks: [
        task('unknown'),
        task('quick', minutes: 5, energy: TaskEnergy.light),
        task('long', minutes: 60, importance: 3),
        task('urgent', importance: 2, urgency: 3),
      ],
    );
    final picker = TaskPicker(random: Random(73));
    expect(picker.draw(doc, now, PickRule.fiveMinutes)!.task.id, 'quick');
    expect(picker.draw(doc, now, PickRule.light)!.task.id, 'quick');
    expect(picker.draw(doc, now, PickRule.important)!.task.id, 'long');
    expect(
      List.generate(
        4,
        (_) => picker.draw(doc, now, PickRule.random)!.identity,
      ).toSet().length,
      4,
    );
    expect(picker.draw(OrbitDocument(), now, PickRule.random), isNull);
    expect(doc.active(now).length, 4);
  });
  test(
    'all gravity/material/rhythm combinations stay bounded and quiet modes stop',
    () {
      for (final gravity in GravityStyle.values) {
        for (final material in BubbleMaterial.values) {
          for (final motion in MotionMode.values) {
            final engine = BubbleEngine()
              ..configure(
                [task('a').activeAt(now)!, task('b').activeAt(now)!],
                const Size(500, 600),
                motion,
                false,
                gravityStyle: gravity,
                bubbleMaterial: material,
              );
            for (var i = 0; i < 800; i++) engine.step(1 / 60);
            engine.attract(const Offset(200, 300));
            for (var i = 0; i < 360; i++) engine.step(1 / 60);
            for (final body in engine.bodies) {
              expect(
                body.position.dx,
                inInclusiveRange(body.radius, 500 - body.radius),
              );
              expect(
                body.position.dy,
                inInclusiveRange(body.radius, 600 - body.radius),
              );
              expect(body.velocity.distance, lessThanOrEqualTo(151));
            }
            engine.attract(null);
            for (var i = 0; i < 240; i++) engine.step(1 / 60);
            if (motion == MotionMode.opening) expect(engine.moving, false);
            engine.paused = true;
            engine.attract(const Offset(10, 20));
            expect(engine.attraction, isNull);
            engine.dispose();
          }
        }
      }
    },
  );
  test(
    'focus persists pause/restart, completes time without completing task, and cancels on restore',
    () async {
      final dir = await Directory.systemTemp.createTemp('focus_lifecycle_');
      var clock = now;
      final controller = OrbitController(LocalStore(dir), clock: () => clock);
      FocusService? focus;
      try {
        await controller.initialize();
        await controller.upsert(task('focus'));
        focus = FocusService(controller);
        await focus.start();
        final item = controller.document.active(clock).single;
        await focus.begin(item, 1);
        await focus.pause();
        expect(focus.session!.phase, FocusPhase.paused);
        focus.dispose();
        focus = FocusService(controller);
        await focus.start();
        expect(focus.session!.phase, FocusPhase.paused);
        await focus.resume();
        focus.dispose();
        clock = clock.add(const Duration(minutes: 2));
        focus = FocusService(controller);
        await focus.start();
        expect(focus.session!.phase, FocusPhase.finished);
        expect(controller.document.active(clock).length, 1);
        await focus.begin(item, 5);
        await controller.restore(controller.document);
        await focus.flush();
        expect(focus.session!.phase, FocusPhase.ended);
        expect(controller.document.activeMemories, isEmpty);
      } finally {
        focus?.dispose();
        controller.dispose();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'focus rejects stale targets and stops when target is completed',
    () async {
      final dir = await Directory.systemTemp.createTemp('focus_target_');
      final controller = OrbitController(LocalStore(dir), clock: () => now);
      final focus = FocusService(controller);
      try {
        await controller.initialize();
        await controller.upsert(task('target'));
        await focus.start();
        final item = controller.document.active(now).single;
        await focus.begin(item, 5);
        await controller.complete(item);
        await focus.flush();
        expect(focus.session!.phase, FocusPhase.ended);
        await expectLater(focus.begin(item, 5), throwsStateError);
        expect(controller.document.activeMemories.length, 1);
      } finally {
        focus.dispose();
        controller.dispose();
        await dir.delete(recursive: true);
      }
    },
  );
}
