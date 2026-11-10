import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/local_store.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/task_model.dart';

class StartupEdgeStore extends LocalStore {
  StartupEdgeStore(super.directory);
  bool failNextSave = false;
  bool failLoad = false;

  @override
  Future<OrbitDocument> load() async {
    if (failLoad) throw const FileSystemException('Unable to read database');
    return super.load();
  }

  @override
  Future<void> save(OrbitDocument document) async {
    if (failNextSave) {
      failNextSave = false;
      throw const FileSystemException('Disk full during startup rollover');
    }
    await super.save(document);
  }
}

void main() {
  late Directory directory;
  late StartupEdgeStore store;
  late OrbitController controller;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('orbit_startup_edge_');
    store = StartupEdgeStore(directory);
  });
  tearDown(() async {
    controller.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'startup rollover write failure keeps valid tasks accessible and retries',
    () async {
      final now = DateTime(2026, 11, 11, 8);
      final original = OrbitDocument(
        tasks: [
          OrbitTask(
            id: 'daily',
            title: '读书',
            createdAt: DateTime(2026, 11, 10),
            date: DateTime(2026, 11, 10),
            repeat: RepeatKind.daily,
          ),
        ],
      );
      await store.save(original);
      final before = await store.current.readAsBytes();
      store.failNextSave = true;
      controller = OrbitController(store, clock: () => now);

      await controller.initialize();

      expect(controller.document.toJson(), original.toJson());
      expect(await store.current.readAsBytes(), before);
      expect(controller.notice, contains('跨天历史暂未保存'));
      expect(controller.document.active(now).single.key, '2026-11-11');
      final exported = BackupCodec.decode(
        BackupCodec.encode(await controller.snapshot()),
      );
      expect(exported.toJson(), original.toJson());

      await controller.rollover();
      expect(controller.document.tasks.single.records, {'2026-11-10': null});
      expect((await store.load()).toJson(), controller.document.toJson());
      expect(controller.notice, isNull);
    },
  );

  test(
    'history limit at midnight does not lock a valid database out of the app',
    () async {
      final start = DateTime(2020, 1, 1);
      final records = <String, String?>{
        for (var day = 0; day < 2500; day++) dayKey(addDays(start, day)): null,
      };
      final original = OrbitDocument(
        tasks: [
          for (var index = 0; index < 100; index++)
            OrbitTask(
              id: 'daily_$index',
              title: '每天的小事 $index',
              createdAt: start,
              date: start,
              repeat: RepeatKind.daily,
              records: records,
            ),
        ],
      );
      // Exactly 250,000 entries is a valid on-disk database. The next missed
      // day exceeds the limit even though no user input or corruption occurred.
      await store.save(original);
      final now = addDays(start, 2501);
      controller = OrbitController(store, clock: () => now);

      await controller.initialize();

      expect(controller.document.tasks, hasLength(100));
      expect(controller.document.tasks.first.records, hasLength(2500));
      expect(controller.notice, contains('跨天历史暂未保存'));
      final exported = BackupCodec.decode(
        BackupCodec.encode(await controller.snapshot()),
      );
      expect(exported.tasks.first.records, hasLength(2500));
      expect((await store.load()).tasks, hasLength(100));

      // Removing a no-longer-needed recurrence must remain possible, and after
      // space is available, the deferred rollover can persist normally.
      await controller.delete('daily_0');
      await controller.rollover();
      expect(controller.document.tasks, hasLength(99));
      expect(controller.document.tasks.first.records, hasLength(2501));
      expect((await store.load()).tasks.first.records, hasLength(2501));
      expect(controller.notice, isNull);
    },
  );

  test('actual database load failure still reaches startup recovery', () async {
    controller = OrbitController(store);
    store.failLoad = true;
    await expectLater(
      controller.initialize(),
      throwsA(isA<FileSystemException>()),
    );
    expect(controller.notice, isNull);
  });
}
