import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/local_store.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/task_model.dart';

class ReviewStore extends LocalStore {
  ReviewStore(super.directory);
  String? failedReadPath;
  Completer<void>? saveGate;

  @override
  Future<String> readBounded(File file) {
    if (file.path == failedReadPath) {
      throw FileSystemException('Simulated temporary read failure', file.path);
    }
    return super.readBounded(file);
  }

  @override
  Future<void> save(OrbitDocument document) async {
    await saveGate?.future;
    await super.save(document);
  }
}

void main() {
  late Directory directory;
  late ReviewStore store;
  late OrbitController controller;
  late DateTime now;

  OrbitTask task({RepeatKind repeat = RepeatKind.none, DateTime? date}) =>
      OrbitTask(
        id: 'review_task',
        title: '每天读书',
        createdAt: DateTime(2026, 11, 1),
        repeat: repeat,
        date: date,
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('orbit_review_data_');
    store = ReviewStore(directory);
    now = DateTime(2026, 11, 10, 10);
    controller = OrbitController(store, clock: () => now);
    await controller.initialize();
  });

  tearDown(() async {
    controller.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'primary read I/O failure never rolls back to the previous database',
    () async {
      await store.save(OrbitDocument(tasks: [task().copyWith(title: 'old')]));
      await store.save(
        OrbitDocument(tasks: [task().copyWith(title: 'latest')]),
      );
      final current = await store.current.readAsBytes();
      final previous = await store.previous.readAsBytes();
      store.failedReadPath = store.current.path;

      await expectLater(store.load(), throwsA(isA<FileSystemException>()));

      expect(await store.current.readAsBytes(), current);
      expect(await store.previous.readAsBytes(), previous);
      expect(await directory.list().length, 2);
      expect(store.recoveryNotice, isNull);
      store.failedReadPath = null;
      expect((await store.load()).tasks.single.title, 'latest');
    },
  );

  test(
    'recovery read I/O failure preserves both originals and remains retryable',
    () async {
      await store.save(OrbitDocument(tasks: [task()]));
      await store.save(OrbitDocument());
      await store.current.writeAsString('damaged');
      final previous = await store.previous.readAsBytes();
      store.failedReadPath = store.previous.path;

      await expectLater(store.load(), throwsA(isA<FileSystemException>()));

      expect(await store.current.readAsString(), 'damaged');
      expect(await store.previous.readAsBytes(), previous);
      store.failedReadPath = null;
      expect((await store.load()).tasks.single.id, 'review_task');
    },
  );

  test(
    'malformed format versions are corruption while newer versions stay protected',
    () async {
      await store.save(OrbitDocument(tasks: [task()]));
      await store.save(OrbitDocument());
      final raw = jsonDecode(await store.current.readAsString()) as Map;
      for (final invalid in [null, '1', 0, -1, 1.0]) {
        raw['version'] = invalid;
        expect(
          () => BackupCodec.decode(jsonEncode(raw)),
          throwsA(
            isA<FormatException>().having(
              (error) => error is UnsupportedBackupVersion,
              'is newer format',
              isFalse,
            ),
          ),
        );
      }
      raw.remove('version');
      await store.current.writeAsString(jsonEncode(raw));
      expect((await store.load()).tasks.single.id, 'review_task');
    },
  );

  test(
    'queued settings changes compose against the latest committed preferences',
    () async {
      store.saveGate = Completer<void>();
      final first = controller.updateSettings(
        (settings) => settings.copyWith(display: DisplayMode.cards),
      );
      final second = controller.updateSettings(
        (settings) => settings.copyWith(motion: MotionMode.lively),
      );
      store.saveGate!.complete();
      await Future.wait([first, second]);

      final saved = await store.load();
      expect(saved.settings.display, DisplayMode.cards);
      expect(saved.settings.motion, MotionMode.lively);
    },
  );

  test(
    'queued setting may be changed back before the first save completes',
    () async {
      store.saveGate = Completer<void>();
      final first = controller.updateSettings(
        (settings) => settings.copyWith(display: DisplayMode.cards),
      );
      final second = controller.updateSettings(
        (settings) => settings.copyWith(display: DisplayMode.bubbles),
      );
      store.saveGate!.complete();
      await Future.wait([first, second]);

      expect((await store.load()).settings.display, DisplayMode.bubbles);
    },
  );

  test(
    'new recurrence starting in the past immediately includes missed history',
    () async {
      await controller.upsert(
        task(repeat: RepeatKind.daily, date: DateTime(2026, 11, 7)),
      );

      expect(controller.document.tasks.single.records, {
        '2026-11-07': null,
        '2026-11-08': null,
        '2026-11-09': null,
      });
      expect(controller.document.active(now).single.key, '2026-11-10');
      expect((await store.load()).toJson(), controller.document.toJson());
    },
  );

  test(
    'moving a recurrence start earlier materializes its history in the same save',
    () async {
      await controller.upsert(
        task(repeat: RepeatKind.daily, date: dateOnly(now)),
      );
      await controller.upsert(
        controller.document.tasks.single.copyWith(date: DateTime(2026, 11, 8)),
      );

      expect((await store.load()).tasks.single.records, {
        '2026-11-08': null,
        '2026-11-09': null,
      });
    },
  );

  test(
    'recurring-to-once keeps the task pending and archives the older single completion',
    () async {
      await controller.upsert(task(date: dateOnly(now)));
      await controller.complete(controller.document.active(now).single);
      final completedAt = controller.document.tasks.single.records['once'];
      now = addDays(now, 1);
      await controller.upsert(
        controller.document.tasks.single.copyWith(
          repeat: RepeatKind.daily,
          date: dateOnly(now),
        ),
      );
      await controller.upsert(
        controller.document.tasks.single.copyWith(repeat: RepeatKind.none),
      );

      final saved = await store.load();
      expect(saved.tasks.single.records, {'2026-11-10': completedAt});
      expect(saved.active(now).single.key, 'once');
      expect(saved.history(now).single.completed, isTrue);
    },
  );

  test(
    'recurrence conversion keeps the existing completion when history shares a day',
    () async {
      await controller.upsert(task(date: dateOnly(now)));
      await controller.complete(controller.document.active(now).single);
      await controller.upsert(
        controller.document.tasks.single.copyWith(repeat: RepeatKind.daily),
      );
      now = now.add(const Duration(hours: 1));
      await controller.complete(controller.document.active(now).single);
      final dailyCompletion =
          controller.document.tasks.single.records[dayKey(now)];
      now = addDays(now, 1);
      await controller.upsert(
        controller.document.tasks.single.copyWith(
          repeat: RepeatKind.none,
          date: dateOnly(now),
        ),
      );

      expect(controller.document.tasks.single.records, {
        '2026-11-10': dailyCompletion,
      });
      expect(controller.document.active(now).single.key, 'once');
      expect(controller.document.history(now), hasLength(1));
    },
  );

  test('title limit matches the UI for emoji and combined graphemes', () async {
    final title = List.filled(240, '👨‍👩‍👧‍👦').join();
    await controller.upsert(task().copyWith(title: title));
    expect((await store.load()).tasks.single.title, title);
    final tooLong = task().copyWith(title: '$title🙂').toJson();
    expect(() => OrbitTask.fromJson(tooLong), throwsFormatException);
  });

  test(
    'failed shutdown receipt flush reopens writes and can be retried',
    () async {
      await expectLater(
        controller.closeWrites(
          afterDrain: () async {
            throw const FileSystemException('Receipt write failed');
          },
        ),
        throwsA(isA<FileSystemException>()),
      );

      await controller.upsert(task());
      var drained = false;
      await controller.closeWrites(afterDrain: () async => drained = true);
      expect(drained, isTrue);
      expect((await store.load()).tasks.single.id, 'review_task');
      await expectLater(controller.delete('review_task'), throwsStateError);
    },
  );
}
