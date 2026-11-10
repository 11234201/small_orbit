import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/local_store.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/task_model.dart';

class ControlledStore extends LocalStore {
  ControlledStore(super.directory);
  bool failNextSave = false;
  Completer<void>? saveGate;
  @override
  Future<void> save(OrbitDocument document) async {
    if (failNextSave) {
      failNextSave = false;
      throw const FileSystemException('Simulated disk failure');
    }
    await saveGate?.future;
    await super.save(document);
  }
}

void main() {
  late Directory directory;
  late ControlledStore store;
  late OrbitController controller;
  final now = DateTime(2026, 11, 10, 10);
  OrbitTask task({RepeatKind repeat = RepeatKind.none}) => OrbitTask(
    id: 'reading',
    title: '读书',
    createdAt: now,
    date: DateTime(2026, 11, 10),
    repeat: repeat,
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('orbit_reliability_');
    store = ControlledStore(directory);
    controller = OrbitController(store, clock: () => now);
    await controller.initialize();
  });
  tearDown(() async {
    controller.dispose();
    await directory.delete(recursive: true);
  });

  test('stale editor preserves completion made after opening', () async {
    await controller.upsert(task(repeat: RepeatKind.daily));
    final editorTask = controller.document.tasks.single;
    await controller.complete(controller.document.active(now).single);
    await controller.upsert(editorTask.copyWith(title: '读十页书'));
    expect(controller.document.active(now), isEmpty);
    expect((await store.load()).tasks.single.records[dayKey(now)], isNotNull);
  });

  test('stale editor cannot restore a completion removed by undo', () async {
    await controller.upsert(task());
    await controller.complete(controller.document.active(now).single);
    final editorTask = controller.document.tasks.single;
    await controller.undo();
    await controller.upsert(editorTask.copyWith(title: '读十页书'));
    expect(controller.document.active(now).single.task.title, '读十页书');
    expect(controller.document.tasks.single.records, isEmpty);
  });

  test('tap from before rescheduling cannot complete the moved task', () async {
    await controller.upsert(task());
    final oldTap = controller.document.active(now).single;
    await controller.upsert(task().copyWith(date: DateTime(2026, 11, 11)));
    await controller.complete(oldTap);
    expect(controller.document.tasks.single.records, isEmpty);
    expect(controller.document.active(now, todayOnly: false), hasLength(1));
  });

  test('failed edit keeps completion undo and later writes recover', () async {
    await controller.upsert(task());
    await controller.complete(controller.document.active(now).single);
    store.failNextSave = true;
    await expectLater(
      controller.upsert(task().copyWith(title: 'new')),
      throwsA(isA<FileSystemException>()),
    );
    expect(controller.canUndo, isTrue);
    await controller.undo();
    expect(controller.document.active(now).single.task.title, '读书');
    expect((await store.load()).active(now), hasLength(1));
  });

  test('export snapshot waits for queued writes', () async {
    store.saveGate = Completer<void>();
    final saving = controller.upsert(task());
    final snapshot = controller.snapshot();
    var exported = false;
    unawaited(
      snapshot.then((_) {
        exported = true;
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(exported, isFalse);
    store.saveGate!.complete();
    await saving;
    expect((await snapshot).tasks.single.title, '读书');
  });

  test(
    'future primary format never rolls back to an older recovery file',
    () async {
      await store.save(OrbitDocument(tasks: [task()]));
      await store.save(OrbitDocument());
      final newer = jsonDecode(await store.current.readAsString()) as Map;
      newer['version'] = 2;
      final original = jsonEncode(newer);
      await store.current.writeAsString(original);
      final previous = await store.previous.readAsString();
      await expectLater(store.load(), throwsA(isA<UnsupportedBackupVersion>()));
      expect(await store.current.readAsString(), original);
      expect(await store.previous.readAsString(), previous);
      expect(await directory.list().length, 2);
    },
  );
}
