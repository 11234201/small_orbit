import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/bubble_engine.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/ui/bubble_surface.dart';

import 'interaction_polish_test.dart' show occurrence, stage;

void main() {
  test('gentle bubbles traverse both axes of the stage over two minutes', () {
    for (final bounds in [const Size(390, 500), const Size(1000, 800)]) {
      final engine = BubbleEngine()
        ..configure(
          [occurrence('traveller')],
          bounds,
          MotionMode.gentle,
          false,
          capacity: 6,
        );
      final body = engine.bodies.single;
      var minX = body.position.dx, maxX = minX;
      var minY = body.position.dy, maxY = minY;
      for (var i = 0; i < 3600; i++) {
        engine.step(1 / 30);
        final p = body.position;
        minX = p.dx < minX ? p.dx : minX;
        maxX = p.dx > maxX ? p.dx : maxX;
        minY = p.dy < minY ? p.dy : minY;
        maxY = p.dy > maxY ? p.dy : maxY;
        expect(body.velocity.distance, lessThanOrEqualTo(27.01));
        expect(p.dx, inInclusiveRange(body.radius, bounds.width - body.radius));
        expect(
          p.dy,
          inInclusiveRange(body.radius, bounds.height - body.radius),
        );
      }
      expect(maxX - minX, greaterThan((bounds.width - 2 * body.radius) * .55));
      expect(maxY - minY, greaterThan((bounds.height - 2 * body.radius) * .55));
      engine.dispose();
    }
  });

  test('throw is bounded, decays, and respects quiet modes and boundaries', () {
    for (final mode in MotionMode.values) {
      final engine = BubbleEngine()
        ..configure([occurrence('throw')], const Size(1000, 800), mode, false);
      for (var i = 0; i < 220; i++) {
        engine.step(1 / 30);
      }
      final body = engine.bodies.single;
      engine.dragTo(body.id, const Offset(-9999, 9999));
      expect(body.position, Offset(body.radius, 800 - body.radius));
      engine.dragTo(body.id, const Offset(500, 400));
      engine.release(body.id, const Offset(10000, 0));
      expect(body.velocity.distance, 260);
      engine.step(.1);
      expect(body.position.dx, greaterThan(500));
      for (var i = 0; i < 120; i++) {
        engine.step(1 / 30);
      }
      expect(body.throwRemaining, 0);
      if (mode == MotionMode.opening) expect(engine.moving, isFalse);
      if (mode == MotionMode.gentle)
        expect(body.velocity.distance, lessThan(27));
      engine.paused = true;
      final stopped = body.position;
      engine.release(body.id, const Offset(500, 0));
      engine.step(.1);
      expect(body.position, stopped);
      expect(body.velocity, Offset.zero);
      engine.dispose();
    }
  });

  test(
    'a group of six still explores beyond its starting rows and columns',
    () {
      final engine = BubbleEngine()
        ..configure(
          List.generate(6, (index) => occurrence('group$index')),
          const Size(440, 560),
          MotionMode.gentle,
          false,
          capacity: 6,
        );
      final ranges = [
        for (final body in engine.bodies)
          Rect.fromPoints(body.position, body.position),
      ];
      for (var i = 0; i < 5400; i++) {
        engine.step(1 / 30);
        for (var j = 0; j < engine.bodies.length; j++) {
          final point = engine.bodies[j].position;
          ranges[j] = ranges[j].expandToInclude(Rect.fromPoints(point, point));
        }
      }
      for (var j = 0; j < ranges.length; j++) {
        expect(
          ranges[j].width,
          greaterThan(130),
          reason: 'bubble $j horizontal travel',
        );
        expect(
          ranges[j].height,
          greaterThan(170),
          reason: 'bubble $j vertical travel',
        );
      }
      engine.dispose();
    },
  );

  test('bubble fill stays opaque through the coloured rim', () async {
    final engine = BubbleEngine()..paused = true;
    final body = BubbleBody('opaque', 60, Offset.zero, Offset.zero);
    final recorder = ui.PictureRecorder();
    BubbleSurface(
      engine: engine,
      body: body,
      color: const Color(0xffd4e8f8),
    ).paint(Canvas(recorder), const Size(120, 120));
    final picture = recorder.endRecording();
    final image = await picture.toImage(120, 120);
    final bytes = (await image.toByteData())!;
    for (final x in [20, 35, 60, 90, 110]) {
      expect(bytes.getUint8((60 * 120 + x) * 4 + 3), 255);
    }
    image.dispose();
    picture.dispose();
    engine.dispose();
  });

  testWidgets('drag and release moves a bubble without completing or editing', (
    tester,
  ) async {
    var completed = 0, edited = 0;
    await tester.pumpWidget(
      stage(
        items: [occurrence('play')],
        reduceMotion: false,
        complete: (_) async {
          completed++;
        },
        edit: (_) {
          edited++;
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 40));
    final title = find.text('小事play');
    final start = tester.getCenter(title);
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: start);
    await pointer.down(start);
    await pointer.moveBy(
      const Offset(25, 0),
      timeStamp: const Duration(milliseconds: 16),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await pointer.moveBy(
      const Offset(25, 18),
      timeStamp: const Duration(milliseconds: 32),
    );
    await pointer.moveBy(
      const Offset(25, 17),
      timeStamp: const Duration(milliseconds: 48),
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect((tester.getCenter(title) - start).distance, greaterThan(40));
    await pointer.up(timeStamp: const Duration(milliseconds: 64));
    await tester.pump();
    final surface = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<BubbleSurface>()
        .single;
    expect(surface.body.throwRemaining, greaterThan(0));
    expect(surface.body.velocity.dx, greaterThan(0));
    expect(surface.body.velocity.dy, greaterThan(0));
    final released = tester.getCenter(title);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getCenter(title), isNot(released));
    expect(completed, 0);
    expect(edited, 0);
    await pointer.removePointer();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'small tap jitter, edit tap, long press and keyboard retain their actions',
    (tester) async {
      var completed = 0, edited = 0;
      await tester.pumpWidget(
        stage(
          items: [occurrence('actions')],
          complete: (_) async {
            completed++;
          },
          edit: (_) {
            edited++;
          },
        ),
      );
      final title = find.text('小事actions');
      final pointer = await tester.startGesture(tester.getCenter(title));
      await pointer.moveBy(const Offset(3, 2));
      await pointer.up();
      await tester.pumpAndSettle();
      expect(completed, 1);
      await tester.tap(find.byTooltip('编辑 小事actions'));
      await tester.pumpAndSettle();
      expect(edited, 1);
      await tester.longPress(title);
      await tester.pumpAndSettle();
      expect(edited, 2);
      expect(completed, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(completed + edited, 4);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('minor mouse movement never starts a drag or a throw', (
    tester,
  ) async {
    await tester.pumpWidget(stage(items: [occurrence('jitter')]));
    final title = find.text('小事jitter');
    final start = tester.getCenter(title);
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: start);
    await pointer.down(start);
    await pointer.moveBy(const Offset(8, 4));
    await tester.pump();
    expect(tester.getCenter(title), start);
    await pointer.up();
    await pointer.removePointer();
    await tester.pumpAndSettle();
    expect(tester.getCenter(title), start);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('dragging the edit control triggers no task action or movement', (
    tester,
  ) async {
    var actions = 0;
    await tester.pumpWidget(
      stage(
        items: [occurrence('edit')],
        complete: (_) async {
          actions++;
        },
        edit: (_) {
          actions++;
        },
      ),
    );
    final start = tester.getCenter(find.text('小事edit'));
    await tester.drag(find.byTooltip('编辑 小事edit'), const Offset(80, 50));
    await tester.pumpAndSettle();
    expect(actions, 0);
    expect(tester.getCenter(find.text('小事edit')), start);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduced motion allows placement without inertial movement', (
    tester,
  ) async {
    var completed = 0;
    await tester.pumpWidget(
      stage(
        items: [occurrence('quiet')],
        complete: (_) async {
          completed++;
        },
      ),
    );
    final title = find.text('小事quiet');
    final start = tester.getCenter(title);
    await tester.drag(title, const Offset(90, 60));
    await tester.pumpAndSettle();
    final released = tester.getCenter(title);
    expect(released, isNot(start));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.getCenter(title), released);
    expect(completed, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'losing focus cancels a drag without a later completion or throw',
    (tester) async {
      var completed = 0;
      await tester.pumpWidget(
        stage(
          items: [occurrence('cancel')],
          complete: (_) async {
            completed++;
          },
        ),
      );
      final title = find.text('小事cancel');
      final pointer = await tester.startGesture(tester.getCenter(title));
      await pointer.moveBy(const Offset(30, 0));
      await pointer.moveBy(const Offset(60, 30));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      final cancelled = tester.getCenter(title);
      await pointer.moveBy(const Offset(60, 30));
      await pointer.up();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(completed, 0);
      expect(tester.getCenter(title), cancelled);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
