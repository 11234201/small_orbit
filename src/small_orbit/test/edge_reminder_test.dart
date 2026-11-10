import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/local_store.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/platform/reminder_service.dart';
import 'widget_test.dart' show MemoryStore;

class MaintenanceFailureStore extends LocalStore {
  MaintenanceFailureStore(super.directory);
  bool failDatabaseWrites = false;
  @override
  Future<void> save(OrbitDocument document) async {
    if (failDatabaseWrites)
      throw const FileSystemException('history storage limit');
    await super.save(document);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const bridge = MethodChannel('small_orbit/edge_reminders');

  test(
    'failed history maintenance does not suppress valid current reminders',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'orbit_history_reminder_',
      );
      final store = MaintenanceFailureStore(directory);
      var now = DateTime(2026, 11, 10, 10);
      final controller = OrbitController(store, clock: () => now);
      await controller.initialize();
      await controller.upsert(
        OrbitTask(
          id: 'daily',
          title: '每天仍需提醒',
          createdAt: now,
          date: DateTime(2026, 11, 10),
          reminderMinute: 540,
          repeat: RepeatKind.daily,
        ),
      );
      now = DateTime(2026, 11, 11, 10);
      store.failDatabaseWrites = true;
      var deliveries = 0;
      messenger.setMockMethodCallHandler(bridge, (call) async {
        expect(call.method, 'showNotification');
        deliveries++;
        return null;
      });
      final service = ReminderService(
        controller,
        platform: ReminderPlatform.windows,
        bridge: bridge,
      );
      try {
        await service.start();
        expect(deliveries, 1);
        expect(controller.document.tasks.single.records, isEmpty);
        expect(service.lastError, isNotNull);
        await service.tick();
        expect(deliveries, 1);
        store.failDatabaseWrites = false;
        await service.retry();
        expect(service.lastError, isNull);
        expect(
          controller.document.tasks.single.records,
          containsPair('2026-11-10', null),
        );
        await service.stop();
      } finally {
        service.dispose();
        controller.dispose();
        messenger.setMockMethodCallHandler(bridge, null);
        await directory.delete(recursive: true);
      }
    },
  );

  test('Windows local reminder identity survives a timezone change', () async {
    // The optional two-process probe writes in Asia/Shanghai and reads in
    // Europe/London. No system timezone or user data is changed by the probe.
    final phase = Platform.environment['ORBIT_TIMEZONE_PHASE'];
    final probePath = Platform.environment['ORBIT_TIMEZONE_DIRECTORY'];
    final directory = phase == null
        ? await Directory.systemTemp.createTemp('orbit_calendar_receipt_')
        : Directory(probePath!);
    await directory.create(recursive: true);
    final now = DateTime(2026, 11, 10, 10);
    final controller = OrbitController(LocalStore(directory), clock: () => now);
    await controller.initialize();
    if (phase != 'read') {
      await controller.upsert(
        OrbitTask(
          id: 'timezone',
          title: '每天本地九点',
          createdAt: now,
          date: DateTime(2026, 11, 10),
          reminderMinute: 540,
        ),
      );
    }
    if (phase == null) {
      // A portable fixture of a delivery made in another timezone: its local
      // occurrence is unchanged and must not generate a second notification.
      await File(
        '${directory.path}/reminders.json',
      ).writeAsString(jsonEncode(['v2:timezone:once:2026-11-10:540']));
    }
    var deliveries = 0;
    messenger.setMockMethodCallHandler(bridge, (call) async {
      expect(call.method, 'showNotification');
      deliveries++;
      return null;
    });
    final service = ReminderService(
      controller,
      platform: ReminderPlatform.windows,
      bridge: bridge,
    );
    try {
      await service.start();
      expect(deliveries, phase == 'write' ? 1 : 0);
      await service.stop();
    } finally {
      service.dispose();
      controller.dispose();
      messenger.setMockMethodCallHandler(bridge, null);
      if (phase == null) await directory.delete(recursive: true);
    }
  });

  test(
    'legacy receipt upgrades without replay and a changed time still alerts',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'orbit_legacy_receipt_',
      );
      final now = DateTime(2026, 11, 10, 10);
      final controller = OrbitController(
        LocalStore(directory),
        clock: () => now,
      );
      await controller.initialize();
      await controller.upsert(
        OrbitTask(
          id: 'legacy',
          title: '旧版本任务',
          createdAt: now,
          date: DateTime(2026, 11, 10),
          reminderMinute: 540,
        ),
      );
      final file = File('${directory.path}/reminders.json');
      await file.writeAsString(
        jsonEncode([
          'legacy:once:${DateTime(2026, 11, 10, 9).millisecondsSinceEpoch}',
        ]),
      );
      var deliveries = 0;
      messenger.setMockMethodCallHandler(bridge, (call) async {
        deliveries++;
        return null;
      });
      final service = ReminderService(
        controller,
        platform: ReminderPlatform.windows,
        bridge: bridge,
      );
      try {
        await service.start();
        expect(deliveries, 0);
        expect(jsonDecode(await file.readAsString()), [
          'v2:legacy:once:2026-11-10:540',
        ]);
        await controller.upsert(
          controller.document.tasks.single.copyWith(reminderMinute: 570),
        );
        await service.tick();
        expect(deliveries, 1);
        await service.stop();
      } finally {
        service.dispose();
        controller.dispose();
        messenger.setMockMethodCallHandler(bridge, null);
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'failed native update invalidates the last successful config cache',
    () async {
      final controller = OrbitController(MemoryStore());
      await controller.initialize();
      final service = ReminderService(
        controller,
        platform: ReminderPlatform.android,
        bridge: bridge,
      );
      var calls = 0;
      var failAfterApplying = false;
      Map<String, dynamic>? nativeConfig;
      messenger.setMockMethodCallHandler(bridge, (call) async {
        expect(call.method, 'syncReminders');
        calls++;
        nativeConfig =
            jsonDecode(call.arguments as String) as Map<String, dynamic>;
        if (failAfterApplying) {
          failAfterApplying = false;
          throw PlatformException(code: 'FAILED_AFTER_PARTIAL_UPDATE');
        }
        return null;
      });
      try {
        await service.start();
        expect(nativeConfig!['enabled'], isTrue);
        failAfterApplying = true;
        await controller.updateSettings(
          (settings) => settings.copyWith(remindersEnabled: false),
        );
        expect(nativeConfig!['enabled'], isFalse);
        expect(service.lastError, isNotNull);
        // Undoing the preference returns to the last successful Dart config,
        // but the native state may already have changed before its error reply.
        await controller.updateSettings(
          (settings) => settings.copyWith(remindersEnabled: true),
        );
        expect(nativeConfig!['enabled'], isTrue);
        expect(calls, 3);
        expect(service.lastError, isNull);
      } finally {
        service.dispose();
        controller.dispose();
        messenger.setMockMethodCallHandler(bridge, null);
      }
    },
  );

  test(
    'failed task deletion followed by undo restores the native schedule',
    () async {
      final controller = OrbitController(MemoryStore());
      await controller.initialize();
      await controller.upsert(
        OrbitTask(
          id: 'reminder',
          title: '保留这个提醒',
          createdAt: DateTime(2026, 11, 10),
          date: DateTime(2026, 11, 11),
          reminderMinute: 9 * 60,
        ),
      );
      final service = ReminderService(
        controller,
        platform: ReminderPlatform.android,
        bridge: bridge,
      );
      var failNext = false;
      List<dynamic> nativeTasks = [];
      messenger.setMockMethodCallHandler(bridge, (call) async {
        nativeTasks = jsonDecode(call.arguments as String)['tasks'] as List;
        if (failNext) {
          failNext = false;
          throw PlatformException(code: 'PARTIAL');
        }
        return null;
      });
      try {
        await service.start();
        failNext = true;
        await controller.delete('reminder');
        expect(nativeTasks, isEmpty);
        await controller.undo();
        expect(nativeTasks.single['id'], 'reminder');
        expect(service.lastError, isNull);
      } finally {
        service.dispose();
        controller.dispose();
        messenger.setMockMethodCallHandler(bridge, null);
      }
    },
  );
}
