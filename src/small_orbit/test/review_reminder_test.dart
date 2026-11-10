import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/local_store.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/platform/reminder_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const bridge = MethodChannel('small_orbit/review_reminders');
  var now = DateTime(2026, 11, 10, 10);
  late Directory directory;
  late OrbitController controller;
  final services = <ReminderService>[];
  var delivered = 0;

  OrbitTask task(String id) => OrbitTask(
    id: id,
    title: id,
    createdAt: now,
    date: DateTime(2026, 11, 10),
    reminderMinute: 9 * 60,
  );
  ReminderService service() {
    final result = ReminderService(
      controller,
      platform: ReminderPlatform.windows,
      bridge: bridge,
    );
    services.add(result);
    return result;
  }

  setUp(() async {
    now = DateTime(2026, 11, 10, 10);
    delivered = 0;
    directory = await Directory.systemTemp.createTemp('orbit_review_reminder_');
    controller = OrbitController(LocalStore(directory), clock: () => now);
    await controller.initialize();
    messenger.setMockMethodCallHandler(bridge, (call) async {
      expect(call.method, 'showNotification');
      delivered++;
      return null;
    });
  });

  tearDown(() async {
    for (final item in services) {
      item.dispose();
    }
    services.clear();
    controller.dispose();
    messenger.setMockMethodCallHandler(bridge, null);
    await directory.delete(recursive: true);
  });

  test(
    'receipt retry persists a delivered alert without replaying it',
    () async {
      await controller.upsert(task('due'));
      final blocked = Directory('${directory.path}/reminders.json');
      await blocked.create();
      final first = service();
      await first.start();
      expect(delivered, 1);
      expect(first.lastError, isNotNull);
      await first.tick();
      expect(first.lastError, isNotNull);
      expect(delivered, 1);
      await blocked.delete();
      // Turning reminders off must not discard the pending persistence retry.
      await controller.settings(
        controller.document.settings.copyWith(remindersEnabled: false),
      );
      await first.retry();
      expect(first.lastError, isNull);
      expect(
        jsonDecode(
          await File('${directory.path}/reminders.json').readAsString(),
        ),
        hasLength(1),
      );
      await first.stop();
      await controller.settings(
        controller.document.settings.copyWith(remindersEnabled: true),
      );
      await service().start();
      expect(delivered, 1);
    },
  );

  test('failed receipt write preserves earlier durable receipts', () async {
    await controller.upsert(task('first'));
    final first = service();
    await first.start();
    final receipt = File('${directory.path}/reminders.json');
    final original = await receipt.readAsString();
    final blocked = Directory('${receipt.path}.pending');
    await blocked.create();
    await controller.upsert(task('second'));
    await first.tick();
    expect(delivered, 2);
    expect(first.lastError, isNotNull);
    expect(await receipt.readAsString(), original);
    await blocked.delete();
    await first.retry();
    expect(jsonDecode(await receipt.readAsString()), hasLength(2));
    await first.stop();
    await service().start();
    expect(delivered, 2);
  });

  test('failed quit keeps writes and reminder retry available', () async {
    await controller.upsert(task('due'));
    final blocked = Directory('${directory.path}/reminders.json');
    await blocked.create();
    final reminders = service();
    await reminders.start();
    await expectLater(
      controller.closeWrites(afterDrain: reminders.stop),
      throwsA(isA<FileSystemException>()),
    );
    expect(controller.onCommitted, isNotNull);
    await controller.upsert(task('new').copyWith(clearReminder: true));
    expect(controller.document.tasks, hasLength(2));
    await blocked.delete();
    await controller.closeWrites(afterDrain: reminders.stop);
    expect(delivered, 1);
    expect(
      jsonDecode(await File('${directory.path}/reminders.json').readAsString()),
      hasLength(1),
    );
  });

  test(
    'disposal during receipt loading cannot re-register the service',
    () async {
      final reminders = service();
      final starting = reminders.start();
      // start() is awaiting its first file operation here.
      reminders.dispose();
      services.remove(reminders);
      await starting;
      expect(controller.onCommitted, isNull);
      expect(delivered, 0);
    },
  );

  test(
    'notification loop rechecks the day after an asynchronous delivery',
    () async {
      await controller.upsert(task('first'));
      await controller.upsert(task('now-expired'));
      final gate = Completer<void>();
      final entered = Completer<void>();
      messenger.setMockMethodCallHandler(bridge, (call) async {
        delivered++;
        if (delivered == 1) {
          entered.complete();
          await gate.future;
        }
        return null;
      });
      final starting = service().start();
      await entered.future;
      now = DateTime(2026, 11, 11, 0, 1);
      gate.complete();
      await starting;
      expect(delivered, 1);
    },
  );
}
