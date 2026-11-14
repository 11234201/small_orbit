import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/focus_session.dart';
import 'package:small_orbit/core/local_store.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/platform/focus_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const bridge = MethodChannel('focus_review_notification');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final now = DateTime(2026, 11, 14, 12);
  late Directory dir;
  late OrbitController controller;
  late FocusService focus;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('focus_notification_');
    controller = OrbitController(LocalStore(dir), clock: () => now);
    await controller.initialize();
    await controller.upsert(
      OrbitTask(id: 'target', title: 'read', createdAt: now),
    );
    final session = FocusSession(
      id: 'finished',
      taskId: 'target',
      key: 'once',
      taskDay: null,
      repeat: RepeatKind.none,
      durationSeconds: 60,
      remainingSeconds: 0,
      deadline: now,
      phase: FocusPhase.finished,
    );
    await File(
      '${dir.path}/focus.json',
    ).writeAsString(jsonEncode({'session': session.toJson()}));
    focus = FocusService(
      controller,
      bridge: bridge,
      platform: TargetPlatform.windows,
    );
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(bridge, null);
    focus.dispose();
    controller.dispose();
    await dir.delete(recursive: true);
  });
  test(
    'Windows finished alert retries failure and survives reopen without duplicates',
    () async {
      var attempts = 0;
      messenger.setMockMethodCallHandler(bridge, (call) async {
        if (call.method == 'showFocusNotification' && ++attempts == 1) {
          throw PlatformException(code: 'TRAY_UNAVAILABLE');
        }
        return null;
      });
      await focus.start();
      expect(attempts, 1);
      expect(focus.notice, contains('后台提示'));
      await focus.retryNotifications();
      expect(attempts, 2);
      expect(focus.notice, isNull);
      await focus.retryNotifications();
      expect(attempts, 2);
      focus.dispose();
      focus = FocusService(
        controller,
        bridge: bridge,
        platform: TargetPlatform.windows,
      );
      await focus.start();
      expect(attempts, 2);
      expect(controller.document.active(now).length, 1);
    },
  );
  test(
    'delivered Windows alert retries its receipt without resending and blocks failed quit',
    () async {
      var attempts = 0;
      final blocker = Directory('${dir.path}/focus.json.pending');
      messenger.setMockMethodCallHandler(bridge, (call) async {
        if (call.method == 'showFocusNotification') {
          attempts++;
          await blocker.create();
        }
        return null;
      });
      await focus.start();
      expect(attempts, 1);
      await expectLater(focus.stop(), throwsA(isA<FileSystemException>()));
      await blocker.delete();
      await focus.retryNotifications();
      expect(attempts, 1);
      focus.dispose();
      focus = FocusService(
        controller,
        bridge: bridge,
        platform: TargetPlatform.windows,
      );
      await focus.start();
      expect(attempts, 1);
    },
  );
  test(
    'completing the target cancels a pending finished alert before retry',
    () async {
      var attempts = 0;
      messenger.setMockMethodCallHandler(bridge, (call) async {
        if (call.method == 'showFocusNotification') {
          attempts++;
          throw PlatformException(code: 'TRAY_UNAVAILABLE');
        }
        return null;
      });
      await focus.start();
      expect(attempts, 1);
      await controller.complete(controller.document.active(now).single);
      await focus.flush();
      await focus.retryNotifications();
      expect(focus.session!.phase, FocusPhase.ended);
      expect(attempts, 1);
    },
  );
}
