import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/core/local_store.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/bubble_engine.dart';
import 'package:flutter/painting.dart';

OrbitTask task({
  String id = 'test',
  RepeatKind repeat = RepeatKind.none,
  DateTime? date,
  Map<String, String?> records = const {},
}) => OrbitTask(
  id: id,
  title: '读书',
  createdAt: DateTime(2026, 1, 1),
  date: date,
  repeat: repeat,
  records: records,
);

void main() {
  test(
    'daily recurrence records missed days, including leap day, without backlog',
    () {
      final value = task(
        repeat: RepeatKind.daily,
        date: DateTime(2024, 2, 28),
      ).materializeMissed(DateTime(2024, 3, 1));
      expect(value.records, {'2024-02-28': null, '2024-02-29': null});
      expect(value.activeAt(DateTime(2024, 3, 1))!.key, '2024-03-01');
      expect(
        OrbitDocument(tasks: [value]).active(DateTime(2024, 3, 1)),
        hasLength(1),
      );
    },
  );
  test('weekly task remains current until the next weekly cycle', () {
    final value = task(repeat: RepeatKind.weekly, date: DateTime(2025, 12, 29));
    expect(value.activeAt(DateTime(2026, 1, 4))!.key, '2025-12-29');
    final advanced = value.materializeMissed(DateTime(2026, 1, 5));
    expect(advanced.records, {'2025-12-29': null});
    expect(advanced.activeAt(DateTime(2026, 1, 5))!.key, '2026-01-05');
  });
  test(
    'completing today hides until next cycle in Today, but All shows next',
    () {
      final now = DateTime(2026, 11, 10);
      final value = task(
        repeat: RepeatKind.daily,
        date: now,
        records: {dayKey(now): now.toIso8601String()},
      );
      final doc = OrbitDocument(tasks: [value]);
      expect(doc.active(now), isEmpty);
      expect(
        doc.active(now, todayOnly: false).single.day,
        DateTime(2026, 11, 11),
      );
    },
  );
  test(
    'backup rejects corrupt contents, unsupported versions and duplicate IDs',
    () {
      final source = BackupCodec.encode(OrbitDocument(tasks: [task()]));
      expect(BackupCodec.decode(source).tasks.single.title, '读书');
      expect(
        () => BackupCodec.decode(source.replaceFirst('读书', '坏数据')),
        throwsFormatException,
      );
      final raw = jsonDecode(source) as Map<String, dynamic>;
      raw['version'] = BackupCodec.currentVersion + 1;
      expect(() => BackupCodec.decode(jsonEncode(raw)), throwsFormatException);
      final duplicate = BackupCodec.encode(
        OrbitDocument(tasks: [task(), task()]),
      );
      expect(() => BackupCodec.decode(duplicate), throwsFormatException);
    },
  );
  test('malformed dates and reminder combinations are rejected', () {
    final raw = task().toJson();
    raw['date'] = '2026-02-30';
    expect(() => OrbitTask.fromJson(raw), throwsFormatException);
    raw['date'] = null;
    raw['reminderMinute'] = 500;
    expect(() => OrbitTask.fromJson(raw), throwsFormatException);
    raw['reminderMinute'] = null;
    raw['importance'] = 8;
    expect(() => OrbitTask.fromJson(raw), throwsFormatException);
  });
  group('durable state', () {
    late Directory directory;
    late LocalStore store;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('orbit_test_');
      store = LocalStore(directory);
    });
    tearDown(() async {
      await directory.delete(recursive: true);
    });
    test('save, close and reopen keeps tasks and settings', () async {
      await store.save(
        OrbitDocument(
          tasks: [task()],
          settings: const AppSettings(
            display: DisplayMode.cards,
            motion: MotionMode.lively,
          ),
        ),
      );
      final reopened = await LocalStore(directory).load();
      expect(reopened.tasks.single.id, 'test');
      expect(reopened.settings.display, DisplayMode.cards);
    });
    test('crash between renames recovers previous good data', () async {
      await store.save(OrbitDocument(tasks: [task()]));
      await store.current.rename(store.previous.path);
      final reopened = LocalStore(directory);
      expect((await reopened.load()).tasks, hasLength(1));
      expect(reopened.recoveryNotice, isNotNull);
    });
    test(
      'corrupt current file is preserved and good previous state recovered',
      () async {
        await store.save(OrbitDocument(tasks: [task()]));
        await store.save(OrbitDocument(tasks: [task(id: 'new')]));
        await store.current.writeAsString('broken');
        expect((await store.load()).tasks.single.id, 'test');
        expect(
          await directory
              .list()
              .where((item) => item.path.contains('damaged-'))
              .length,
          1,
        );
      },
    );
    test('restore produces a readable backup before replacement', () async {
      final old = OrbitDocument(tasks: [task()]),
          incoming = OrbitDocument(tasks: [task(id: 'new')]);
      await store.save(old);
      final backup = await store.restore(incoming, old);
      expect(
        BackupCodec.decode(await backup.readAsString()).tasks.single.id,
        'test',
      );
      expect((await store.load()).tasks.single.id, 'new');
    });
    test('backup failure leaves current data untouched', () async {
      final old = OrbitDocument(tasks: [task()]);
      await store.save(old);
      await File('${directory.path}/backups').writeAsString('blocking file');
      await expectLater(
        store.restore(OrbitDocument(), old),
        throwsA(isA<FileSystemException>()),
      );
      expect((await store.load()).tasks.single.id, 'test');
    });
    test(
      'queued mutations and display changes preserve completion undo',
      () async {
        final controller = OrbitController(
          store,
          clock: () => DateTime(2026, 11, 10),
        );
        await controller.initialize();
        await Future.wait([
          controller.upsert(task()),
          controller.upsert(task(id: 'second')),
        ]);
        await controller.complete(
          controller.document.active(controller.clock()).first,
        );
        await controller.settings(
          controller.document.settings.copyWith(display: DisplayMode.papers),
        );
        await controller.undo();
        expect(controller.document.active(controller.clock()), hasLength(2));
        expect(controller.document.settings.display, DisplayMode.papers);
        controller.dispose();
      },
    );
    test(
      'undo after midnight marks old repeat missed and exposes only today',
      () async {
        var now = DateTime(2026, 11, 10, 23, 59);
        final controller = OrbitController(store, clock: () => now);
        await controller.initialize();
        await controller.upsert(
          task(repeat: RepeatKind.daily, date: dateOnly(now)),
        );
        await controller.complete(controller.document.active(now).single);
        now = DateTime(2026, 11, 11, 0, 1);
        await controller.rollover();
        await controller.undo();
        expect(controller.document.tasks.single.records['2026-11-10'], null);
        expect(controller.document.active(now).single.key, '2026-11-11');
        controller.dispose();
      },
    );
  });
  test(
    'bubble size grows with priority and every circle stays inside bounds',
    () {
      final engine = BubbleEngine();
      final tasks = List.generate(
        6,
        (index) => task(id: 'task$index')
            .copyWith(importance: index % 3 + 1, urgency: index % 3 + 1)
            .activeAt(DateTime.now())!,
      );
      for (final size in [const Size(320, 360), const Size(700, 430)]) {
        engine.configure(tasks, size, MotionMode.lively, false);
        expect(engine.bodies[2].radius, greaterThan(engine.bodies[0].radius));
        for (var i = 0; i < 3000; i++) {
          engine.step(1 / 60);
        }
        for (final body in engine.bodies) {
          expect(
            body.position.dx,
            inInclusiveRange(body.radius, size.width - body.radius),
          );
          expect(
            body.position.dy,
            inInclusiveRange(body.radius, size.height - body.radius),
          );
        }
        final position = engine.bodies[0].position;
        engine.paused = true;
        engine.step(1);
        expect(engine.bodies[0].position, position);
      }
      engine.dispose();
    },
  );
  test('opening motion settles and hovered bubble stays still', () {
    final engine = BubbleEngine();
    engine.configure(
      [task().activeAt(DateTime.now())!],
      const Size(320, 360),
      MotionMode.opening,
      false,
    );
    engine.hold(0, 'hover', true);
    final original = engine.bodies.first.position;
    engine.step(.02);
    expect(engine.bodies.first.position, original);
    engine.hold(0, 'hover', false);
    for (var i = 0; i < 450; i++) {
      engine.step(1 / 60);
    }
    final settled = engine.bodies.first.position;
    engine.step(.02);
    expect(engine.bodies.first.position, settled);
    engine.dispose();
  });
}
