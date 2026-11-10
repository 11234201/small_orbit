import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/local_store.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/platform/reminder_service.dart';
import 'package:small_orbit/ui/settings_panel.dart';

class ReminderMemoryStore extends LocalStore {
  ReminderMemoryStore() : super(Directory.systemTemp);
  @override
  Future<OrbitDocument> load() async => OrbitDocument();
  @override
  Future<void> save(OrbitDocument document) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const bridge = MethodChannel('small_orbit/reminder_test');
  final now = DateTime(2026, 11, 10, 10);
  OrbitTask task(String id) => OrbitTask(
    id: id,
    title: '提醒$id',
    createdAt: now,
    date: DateTime(2026, 11, 10),
    reminderMinute: 9 * 60,
  );
  tearDown(() => messenger.setMockMethodCallHandler(bridge, null));

  testWidgets('initial platform failure keeps automatic retry alive', (
    tester,
  ) async {
    final controller = OrbitController(ReminderMemoryStore(), clock: () => now);
    await controller.initialize();
    final service = ReminderService(
      controller,
      platform: ReminderPlatform.android,
      bridge: bridge,
    );
    var attempts = 0;
    messenger.setMockMethodCallHandler(bridge, (call) async {
      if (call.method == 'syncReminders' && ++attempts == 1) {
        throw PlatformException(code: 'TEMPORARY');
      }
      return null;
    });
    try {
      await service.start();
      expect(service.lastError, isNotNull);
      await tester.pump(const Duration(seconds: 21));
      expect(attempts, 2);
      expect(service.lastError, isNull);
    } finally {
      service.dispose();
      controller.dispose();
    }
  });

  test('queued reminder updates read latest state and never overlap', () async {
    final controller = OrbitController(ReminderMemoryStore(), clock: () => now);
    await controller.initialize();
    controller.document = OrbitDocument(tasks: [task('old')]);
    final service = ReminderService(
      controller,
      platform: ReminderPlatform.android,
      bridge: bridge,
    );
    addTearDown(() {
      service.dispose();
      controller.dispose();
    });
    final gate = Completer<void>();
    final entered = Completer<void>();
    final configs = <Map<String, dynamic>>[];
    var active = 0;
    messenger.setMockMethodCallHandler(bridge, (call) async {
      expect(++active, 1);
      configs.add(jsonDecode(call.arguments as String) as Map<String, dynamic>);
      if (configs.length == 1) {
        entered.complete();
        await gate.future;
      }
      active--;
      return null;
    });
    final first = service.synchronize();
    await entered.future;
    controller.document = OrbitDocument(tasks: [task('new')]);
    final second = service.synchronize();
    controller.document = OrbitDocument(
      tasks: [task('restored')],
      settings: const AppSettings(remindersEnabled: false),
    );
    final third = service.synchronize();
    gate.complete();
    await Future.wait([first, second, third]);
    expect(configs, hasLength(2));
    expect(configs.last['enabled'], isFalse);
    expect((configs.last['tasks'] as List).single['id'], 'restored');
  });

  test(
    'platform sync failure preserves committed data and recovers on retry',
    () async {
      final controller = OrbitController(
        ReminderMemoryStore(),
        clock: () => now,
      );
      await controller.initialize();
      final service = ReminderService(
        controller,
        platform: ReminderPlatform.android,
        bridge: bridge,
      );
      addTearDown(() {
        service.dispose();
        controller.dispose();
      });
      var failing = false;
      final configs = <String>[];
      messenger.setMockMethodCallHandler(bridge, (call) async {
        if (failing) throw PlatformException(code: 'TEMPORARY');
        configs.add(call.arguments as String);
        return null;
      });
      await service.start();
      failing = true;
      await controller.upsert(task('saved'));
      expect(controller.document.tasks.single.id, 'saved');
      expect(service.lastError, isNotNull);
      failing = false;
      await service.retry();
      expect(service.lastError, isNull);
      expect(configs.last, contains('saved'));
      await controller.settings(
        controller.document.settings.copyWith(remindersEnabled: false),
      );
      expect(jsonDecode(configs.last)['enabled'], isFalse);
    },
  );

  test('Windows receipts survive restart and skip previous days', () async {
    final directory = await Directory.systemTemp.createTemp('orbit_receipts_');
    final controller = OrbitController(LocalStore(directory), clock: () => now);
    await controller.initialize();
    await controller.upsert(task('today'));
    await controller.upsert(task('past').copyWith(date: DateTime(2026, 11, 9)));
    var delivered = 0;
    messenger.setMockMethodCallHandler(bridge, (call) async {
      expect(call.method, 'showNotification');
      delivered++;
      return null;
    });
    final first = ReminderService(
      controller,
      platform: ReminderPlatform.windows,
      bridge: bridge,
    );
    final second = ReminderService(
      controller,
      platform: ReminderPlatform.windows,
      bridge: bridge,
    );
    try {
      await first.start();
      await first.tick();
      expect(delivered, 1);
      first.dispose();
      await second.start();
      expect(delivered, 1);
      await controller.upsert(
        task('today').copyWith(reminderMinute: 9 * 60 + 30),
      );
      await second.tick();
      expect(delivered, 2);
    } finally {
      second.dispose();
      controller.dispose();
      await directory.delete(recursive: true);
    }
  });

  testWidgets(
    'settings refresh channel permissions when returning from system settings',
    (tester) async {
      final controller = OrbitController(
        ReminderMemoryStore(),
        clock: () => now,
      );
      await controller.initialize();
      final service = ReminderService(
        controller,
        platform: ReminderPlatform.android,
        bridge: bridge,
      );
      var allowed = false;
      messenger.setMockMethodCallHandler(
        bridge,
        (call) async => {
          'notifications': true,
          'channel': allowed,
          'exact': allowed,
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsPanel(controller: controller, reminders: service),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('“小事提醒”通知类别已关闭，提醒不会显示。'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      allowed = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('“小事提醒”通知类别已关闭，提醒不会显示。'), findsNothing);
      expect(find.text('准时提醒：已允许'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      service.dispose();
      controller.dispose();
    },
  );

  test(
    'Windows rechecks deletion while an earlier notification is in flight',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'orbit_pending_notice_',
      );
      final controller = OrbitController(
        LocalStore(directory),
        clock: () => now,
      );
      await controller.initialize();
      await controller.upsert(task('first'));
      await controller.upsert(task('deleted'));
      final service = ReminderService(
        controller,
        platform: ReminderPlatform.windows,
        bridge: bridge,
      );
      final gate = Completer<void>();
      final entered = Completer<void>();
      final titles = <String>[];
      messenger.setMockMethodCallHandler(bridge, (call) async {
        titles.add((call.arguments as Map)['body'] as String);
        if (titles.length == 1) {
          entered.complete();
          await gate.future;
        }
        return null;
      });
      try {
        final starting = service.start();
        await entered.future;
        await controller.delete('deleted');
        gate.complete();
        await starting;
        expect(titles, ['提醒first']);
      } finally {
        service.dispose();
        controller.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
