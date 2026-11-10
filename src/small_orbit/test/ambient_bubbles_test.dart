import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/ui/task_stage.dart';
import 'interaction_polish_test.dart' show occurrence, stage;

void main() {
  testWidgets(
    'native visibility gate still stops and restarts an inactive window',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      final content = stage(items: [occurrence('native')], reduceMotion: false);
      await tester.pumpWidget(TickerMode(enabled: true, child: content));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pumpWidget(TickerMode(enabled: false, child: content));
      final hidden = tester.getCenter(find.text('小事native'));
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getCenter(find.text('小事native')), hidden);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(TickerMode(enabled: true, child: content));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getCenter(find.text('小事native')), isNot(hidden));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'visible inactive window keeps moving without resetting its clock',
    (tester) async {
      await tester.pumpWidget(
        stage(items: [occurrence('ambient')], reduceMotion: false),
      );
      await tester.pump(const Duration(milliseconds: 40));
      final before = tester.getCenter(find.text('小事ambient'));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getCenter(find.text('小事ambient')), isNot(before));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'opening while inactive starts motion; hiding stops it and restoring restarts',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpWidget(
        stage(items: [occurrence('startup')], reduceMotion: false),
      );
      await tester.pump(const Duration(milliseconds: 40));
      final before = tester.getCenter(find.text('小事startup'));
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getCenter(find.text('小事startup')), isNot(before));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      expect(tester.binding.transientCallbackCount, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(milliseconds: 40));
      final restored = tester.getCenter(find.text('小事startup'));
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getCenter(find.text('小事startup')), isNot(restored));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('keyboard focus only holds a bubble while its window is active', (
    tester,
  ) async {
    await tester.pumpWidget(
      stage(items: [occurrence('keyboard')], reduceMotion: false),
    );
    await tester.pump(const Duration(milliseconds: 40));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final selected = tester.getCenter(find.text('小事keyboard'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getCenter(find.text('小事keyboard')), selected);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getCenter(find.text('小事keyboard')), isNot(selected));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final resumed = tester.getCenter(find.text('小事keyboard'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getCenter(find.text('小事keyboard')), resumed);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'hover only holds an active window and does not block ambient movement',
    (tester) async {
      await tester.pumpWidget(
        stage(items: [occurrence('mouse')], reduceMotion: false),
      );
      await tester.pump(const Duration(milliseconds: 40));
      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer();
      await pointer.moveTo(tester.getCenter(find.text('小事mouse')));
      await tester.pump();
      final hovered = tester.getCenter(find.text('小事mouse'));
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getCenter(find.text('小事mouse')), hovered);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getCenter(find.text('小事mouse')), isNot(hovered));
      await pointer.removePointer();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'inactive window still respects reduced motion and explicit pause',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      for (final settings in [
        const AppSettings(motion: MotionMode.lively, paused: true),
        const AppSettings(motion: MotionMode.lively, reduceMotion: true),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TaskStage(
                items: [occurrence('quiet')],
                settings: settings,
                onComplete: (_) async {},
                onEdit: (_) {},
                onDelete: (_) {},
                replay: 0,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        final position = tester.getCenter(find.text('小事quiet'));
        await tester.pump(const Duration(milliseconds: 80));
        expect(tester.getCenter(find.text('小事quiet')), position);
        expect(tester.binding.transientCallbackCount, 0);
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
