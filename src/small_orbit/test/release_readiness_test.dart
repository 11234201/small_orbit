import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/local_store.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/main.dart';
import 'package:small_orbit/platform/reminder_service.dart';
import 'package:small_orbit/platform/window_service.dart';
import 'package:small_orbit/ui/startup_recovery.dart';
import 'widget_test.dart' show MemoryStore;

class DelayedStore extends MemoryStore {
  Completer<void>? gate;
  bool failNextSave = false;
  @override
  Future<void> save(OrbitDocument document) async {
    await gate?.future;
    if (failNextSave) {
      failNextSave = false;
      throw const FileSystemException('Simulated disk failure during quit');
    }
    await super.save(document);
  }
}

void main() {
  final task = OrbitTask(
    id: 'restore',
    title: '恢复后的小事',
    createdAt: DateTime(2026, 11, 10),
  );
  testWidgets(
    'native window visibility stops and resumes the complete app ticker',
    (tester) async {
      const bridge = MethodChannel('small_orbit/visibility_integration');
      const codec = StandardMethodCodec();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(bridge, (call) async => false);
      final controller = OrbitController(MemoryStore());
      await controller.initialize();
      await controller.upsert(task);
      await controller.settings(
        controller.document.settings.copyWith(motion: MotionMode.lively),
      );
      final reminders = ReminderService(controller);
      final window = WindowService(
        enabled: true,
        bridge: bridge,
        onPrepareToQuit: () async {},
      )..register();
      await tester.pumpWidget(
        OrbitApp(controller: controller, reminders: reminders, window: window),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(window.isVisible, isFalse);
      expect(tester.binding.hasScheduledFrame, isFalse);
      Future<void> visibility(bool value) async {
        await messenger.handlePlatformMessage(
          bridge.name,
          codec.encodeMethodCall(MethodCall('visibilityChanged', value)),
          (_) {},
        );
        await tester.pump();
      }

      await visibility(true);
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.binding.hasScheduledFrame, isTrue);
      await visibility(false);
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox());
      window.dispose();
      reminders.dispose();
      controller.dispose();
      messenger.setMockMethodCallHandler(bridge, null);
    },
  );
  group('startup recovery', () {
    late Directory directory;
    late LocalStore store;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'orbit_startup_recovery_',
      );
      store = LocalStore(directory);
    });
    tearDown(() async => directory.delete(recursive: true));
    test(
      'corrupt current and previous bytes are preserved before restoration',
      () async {
        await store.current.writeAsBytes([0, 255, 123, 125]);
        await store.previous.writeAsString('broken previous');
        final pending = File('${directory.path}/tasks.pending.json');
        await pending.writeAsString('interrupted write');
        await expectLater(store.load(), throwsStateError);
        final archive = await store.recover(OrbitDocument(tasks: [task]));
        expect(await File('${archive.path}/tasks.json').readAsBytes(), [
          0,
          255,
          123,
          125,
        ]);
        expect(
          await File('${archive.path}/tasks.previous.json').readAsString(),
          'broken previous',
        );
        expect(
          await File('${archive.path}/tasks.pending.json').readAsString(),
          'interrupted write',
        );
        expect(
          (await LocalStore(directory).load()).tasks.single.title,
          task.title,
        );
      },
    );
    test(
      'recovery archive failure leaves damaged originals untouched',
      () async {
        await store.current.writeAsString('damaged');
        await store.previous.writeAsString('previous');
        await File('${directory.path}/backups').writeAsString('blocked');
        await expectLater(
          store.recover(OrbitDocument(tasks: [task])),
          throwsA(isA<FileSystemException>()),
        );
        expect(await store.current.readAsString(), 'damaged');
        expect(await store.previous.readAsString(), 'previous');
      },
    );
    test('manual startup recovery cannot overwrite a newer format', () async {
      final raw =
          jsonDecode(BackupCodec.encode(OrbitDocument(tasks: [task]))) as Map;
      raw['version'] = 9;
      final newer = jsonEncode(raw);
      await store.current.writeAsString(newer);
      await expectLater(
        store.recover(OrbitDocument()),
        throwsA(isA<UnsupportedBackupVersion>()),
      );
      expect(await store.current.readAsString(), newer);
      expect(await store.backupDirectory.exists(), isFalse);
    });
  });

  test(
    'explicit exit waits for accepted writes and rejects new mutations',
    () async {
      final store = DelayedStore();
      final controller = OrbitController(store);
      await controller.initialize();
      store.gate = Completer<void>();
      final saving = controller.upsert(task);
      var ready = false;
      final closing = controller.closeWrites().then((_) => ready = true);
      await expectLater(controller.delete(task.id), throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(ready, isFalse);
      store.gate!.complete();
      await saving;
      await closing;
      expect(store.value.tasks.single.id, task.id);
      controller.dispose();
    },
  );

  test(
    'a save failure during quit keeps the controller writable for retry',
    () async {
      final store = DelayedStore();
      final controller = OrbitController(store);
      await controller.initialize();
      store.gate = Completer<void>();
      store.failNextSave = true;
      final saving = expectLater(
        controller.upsert(task),
        throwsA(isA<FileSystemException>()),
      );
      final closing = expectLater(controller.closeWrites(), throwsStateError);
      store.gate!.complete();
      await saving;
      await closing;
      expect(store.value.tasks, isEmpty);
      await controller.upsert(task);
      expect(store.value.tasks.single.id, task.id);
      controller.dispose();
    },
  );

  testWidgets('Ctrl+Z in the quick entry edits text without undoing a task', (
    tester,
  ) async {
    final controller = OrbitController(MemoryStore());
    await controller.initialize();
    await controller.upsert(task);
    await controller.complete(
      controller.document.active(DateTime.now()).single,
    );
    final reminders = ReminderService(controller);
    await tester.pumpWidget(
      OrbitApp(controller: controller, reminders: reminders),
    );
    final field = find.byType(TextField).first;
    await tester.tap(field);
    await tester.enterText(field, 'abc');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(field, 'abcd');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(controller.document.active(DateTime.now()), isEmpty);
    expect(controller.canUndo, isTrue);
    expect(tester.widget<TextField>(field).controller!.text, 'abc');
    await tester.pumpWidget(const SizedBox());
    reminders.dispose();
    controller.dispose();
  });

  test(
    'shutdown waits for an in-flight Windows receipt to become durable',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'orbit_shutdown_',
      );
      final now = DateTime(2026, 11, 10, 10);
      final controller = OrbitController(
        LocalStore(directory),
        clock: () => now,
      );
      await controller.initialize();
      await controller.upsert(
        task.copyWith(date: DateTime(2026, 11, 10), reminderMinute: 9 * 60),
      );
      const bridge = MethodChannel('small_orbit/shutdown_test');
      final entered = Completer<void>(), gate = Completer<void>();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(bridge, (call) async {
        entered.complete();
        await gate.future;
        return null;
      });
      final service = ReminderService(
        controller,
        platform: ReminderPlatform.windows,
        bridge: bridge,
      );
      try {
        final starting = service.start();
        await entered.future;
        final writes = controller.closeWrites();
        var stopped = false;
        final stopping = service.stop().then((_) => stopped = true);
        await Future<void>.delayed(Duration.zero);
        expect(stopped, isFalse);
        gate.complete();
        await starting;
        await writes;
        await stopping;
        expect(
          await File('${directory.path}/reminders.json').readAsString(),
          contains('restore:once'),
        );
      } finally {
        service.dispose();
        controller.dispose();
        messenger.setMockMethodCallHandler(bridge, null);
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'newer-data startup screen offers retry but no destructive recovery',
    (tester) async {
      var retried = false;
      await tester.pumpWidget(
        MaterialApp(
          home: StartupRecovery(
            error: const UnsupportedBackupVersion(),
            store: LocalStore(Directory.systemTemp),
            onRetry: () async {
              retried = true;
            },
          ),
        ),
      );
      expect(find.text('从备份恢复'), findsNothing);
      await tester.tap(find.text('重试打开'));
      await tester.pump();
      expect(retried, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
