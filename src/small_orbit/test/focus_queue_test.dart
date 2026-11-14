import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/focus_session.dart';
import 'package:small_orbit/core/local_store.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/platform/focus_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'an old queued clock event cannot pause a newly started session',
    () async {
      final dir = await Directory.systemTemp.createTemp('focus_clock_queue_');
      var now = DateTime(2026, 11, 14, 12);
      final controller = OrbitController(LocalStore(dir), clock: () => now);
      final focus = FocusService(controller);
      void Function(Timer)? clockTick;
      Timer? timer;
      try {
        await runZoned(
          () async {
            await controller.initialize();
            await controller.upsert(
              OrbitTask(id: 'target', title: 'target', createdAt: now),
            );
            await focus.start();
            final item = controller.document.active(now).single;
            await focus.begin(item, 5);
            final previousId = focus.session!.id;
            now = now.add(const Duration(minutes: 2));
            final next = focus.begin(item, 15);
            // The old timer fires while the replacement session is queued to save.
            clockTick!(timer!);
            await next;
            await focus.flush();
            expect(focus.session!.id, isNot(previousId));
            expect(focus.session!.phase, FocusPhase.running);
            expect(focus.remaining, 15 * 60);
            expect(focus.notice, isNull);
          },
          zoneSpecification: ZoneSpecification(
            createPeriodicTimer: (self, parent, zone, duration, callback) {
              clockTick = callback;
              return timer = parent.createPeriodicTimer(
                zone,
                const Duration(days: 1),
                callback,
              );
            },
          ),
        );
      } finally {
        focus.dispose();
        controller.dispose();
        await dir.delete(recursive: true);
      }
    },
  );

  test('quit reports a pending focus save failure and permits retry', () async {
    final dir = await Directory.systemTemp.createTemp('focus_quit_failure_');
    final controller = OrbitController(LocalStore(dir));
    final focus = FocusService(controller);
    try {
      await controller.initialize();
      await focus.start();
      final blocker = await Directory(
        '${dir.path}/focus.json.pending',
      ).create();
      final changing = focus.preferences(sound: true);
      final failedWrite = expectLater(
        changing,
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(focus.stop(), throwsStateError);
      await failedWrite;
      expect(focus.sound, false);
      await blocker.delete();
      await focus.preferences(sound: true);
      expect(focus.sound, true);
    } finally {
      focus.dispose();
      controller.dispose();
      await dir.delete(recursive: true);
    }
  });
}
