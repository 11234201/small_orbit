import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/local_store.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/task_model.dart';

OrbitTask dailyTask({Map<String, String?> records = const {}}) => OrbitTask(
  id: 'daily',
  title: '读书',
  createdAt: DateTime(2024, 2, 28),
  date: DateTime(2024, 2, 28),
  repeat: RepeatKind.daily,
  records: records,
);

void main() {
  test('history date validation keeps Gregorian boundaries and leap years', () {
    final source = dailyTask().toJson();
    for (final value in ['2000-02-29', '2024-02-29', '2200-12-31']) {
      source['records'] = {value: null};
      expect(OrbitTask.fromJson(source).records.containsKey(value), isTrue);
    }
    for (final value in [
      '1999-12-31',
      '2201-01-01',
      '2100-02-29',
      '2024-04-31',
      '2024-00-01',
      '2024-13-01',
      '2024-01-00',
      '2024-1-01',
    ]) {
      source['records'] = {value: null};
      expect(
        () => OrbitTask.fromJson(source),
        throwsFormatException,
        reason: value,
      );
    }
  });

  test('repeated materialization and backward clock preserve full history', () {
    var task = dailyTask(records: {'2024-02-28': '2024-02-28T10:00:00Z'});
    task = task.materializeMissed(DateTime(2024, 3, 2));
    final before = jsonEncode(task.toJson());
    expect(task.records, {
      '2024-02-28': '2024-02-28T10:00:00Z',
      '2024-02-29': null,
      '2024-03-01': null,
    });
    expect(task.materializeMissed(DateTime(2024, 3, 2, 23)), same(task));
    expect(task.materializeMissed(DateTime(2024, 2, 29)), same(task));
    expect(jsonEncode(task.toJson()), before);
    final tomorrow = task.materializeMissed(DateTime(2024, 3, 3));
    expect(tomorrow.records.length, 4);
    expect(tomorrow.records['2024-02-28'], '2024-02-28T10:00:00Z');
    expect(tomorrow.records.containsKey('2024-03-02'), isTrue);
  });

  test(
    'editing recurrence or history invalidates previous calendar coverage',
    () {
      final now = DateTime(2024, 3, 2);
      final warm = dailyTask().materializeMissed(now);
      final removed = Map<String, String?>.of(warm.records)
        ..remove('2024-02-29');
      final repaired = warm.copyWith(records: removed).materializeMissed(now);
      expect(repaired.records.containsKey('2024-02-29'), isTrue);
      final earlier = warm
          .copyWith(date: DateTime(2024, 2, 27))
          .materializeMissed(now);
      expect(earlier.records.containsKey('2024-02-27'), isTrue);
      final weekly = warm
          .copyWith(date: DateTime(2024, 2, 20), repeat: RepeatKind.weekly)
          .materializeMissed(DateTime(2024, 3, 6));
      expect(weekly.records.containsKey('2024-02-20'), isTrue);
      expect(weekly.records.containsKey('2024-02-27'), isTrue);
      expect(weekly.activeAt(DateTime(2024, 3, 6))!.key, '2024-03-05');
    },
  );

  test(
    'recent history includes both date boundaries and once completion local dates',
    () {
      final now = DateTime(2026, 11, 10, 12);
      final once = OrbitTask(
        id: 'once',
        title: '买牛奶',
        createdAt: DateTime(2020),
        records: {'once': DateTime(2026, 11, 10, 8).toUtc().toIso8601String()},
      );
      final repeat = dailyTask(
        records: {
          '2026-10-11': null, // Outside a 30-calendar-day window.
          '2026-10-12': null,
          '2026-11-10': '2026-11-10T00:00:00Z',
          '2026-11-11': null,
        },
      );
      final entries = OrbitDocument(tasks: [once, repeat]).history(now);
      expect(entries.map((entry) => '${entry.task.id}:${entry.key}').toSet(), {
        'once:once',
        'daily:2026-10-12',
        'daily:2026-11-10',
      });
      expect(entries.last.day, DateTime(2026, 10, 12));
    },
  );

  test(
    'format-one file from the original version upgrades without losing fields',
    () async {
      const payload =
          '''{"settings":{"display":"papers","motion":"gentle","paused":false,"reduceMotion":true,"remindersEnabled":true},"tasks":[{"id":"old_daily","title":"每天读书📖","createdAt":"2024-02-28T00:00:00.000Z","date":"2024-02-28","reminderMinute":540,"repeat":"daily","importance":3,"urgency":1,"records":{"2024-02-28":"2024-02-28T10:00:00.000Z","2024-02-29":null}},{"id":"old_once","title":"买牛奶","createdAt":"2024-02-28T00:00:00.000Z","date":null,"reminderMinute":null,"repeat":"none","importance":2,"urgency":2,"records":{}}]}''';
      final source = jsonEncode({
        'format': 'small-orbit',
        'version': 1,
        'savedAt': '2024-03-01T00:00:00.000Z',
        'payload': payload,
        'sha256': sha256.convert(utf8.encode(payload)).toString(),
      });
      final directory = await Directory.systemTemp.createTemp('orbit_upgrade_');
      final store = LocalStore(directory);
      final controller = OrbitController(
        store,
        clock: () => DateTime(2024, 3, 2),
      );
      try {
        await store.current.writeAsString(source);
        await controller.initialize();
        final updated = controller.document;
        expect(updated.settings.display, DisplayMode.papers);
        expect(updated.settings.motion, MotionMode.gentle);
        expect(updated.settings.reduceMotion, isTrue);
        expect(updated.tasks.first.title, '每天读书📖');
        expect(updated.tasks.first.reminderMinute, 540);
        expect(updated.tasks.first.records, {
          '2024-02-28': '2024-02-28T10:00:00.000Z',
          '2024-02-29': null,
          '2024-03-01': null,
        });
        expect(
          BackupCodec.decode(await store.previous.readAsString()).toJson(),
          jsonDecode(payload),
        );
        final exported = BackupCodec.decode(BackupCodec.encode(updated));
        expect(exported.toJson(), updated.toJson());
        expect((await LocalStore(directory).load()).toJson(), updated.toJson());
        expect(
          (jsonDecode(await store.current.readAsString()) as Map)['version'],
          1,
        );
      } finally {
        controller.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
