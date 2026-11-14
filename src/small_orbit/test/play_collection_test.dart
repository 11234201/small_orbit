import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/core/local_store.dart';
import 'package:small_orbit/core/orbit_controller.dart';

class FailingPlayStore extends LocalStore {
  FailingPlayStore(super.directory);
  bool fail = false;
  @override
  Future<void> save(OrbitDocument document) async {
    if (fail) throw const FileSystemException('injected');
    await super.save(document);
  }
}

void main() {
  late Directory dir;
  late FailingPlayStore store;
  late OrbitController controller;
  var now = DateTime(2026, 11, 14, 23, 55);
  setUp(() async {
    now = DateTime(2026, 11, 14, 23, 55);
    dir = await Directory.systemTemp.createTemp('orbit_play_');
    store = FailingPlayStore(dir);
    controller = OrbitController(store, clock: () => now);
    await controller.initialize();
    await controller.upsert(OrbitTask(id: 'one', title: '读书', createdAt: now));
  });
  tearDown(() async {
    controller.dispose();
    await dir.delete(recursive: true);
  });

  test(
    'failed completion has no souvenir; undo/recomplete reuses identity',
    () async {
      final item = controller.document.active(now).single;
      store.fail = true;
      await expectLater(
        controller.complete(item),
        throwsA(isA<FileSystemException>()),
      );
      expect(controller.document.memories, isEmpty);
      store.fail = false;
      await controller.complete(item);
      final id = controller.document.activeMemories.single.id;
      await controller.complete(item);
      expect(controller.document.activeMemories.length, 1);
      await controller.undo();
      expect(controller.document.activeMemories, isEmpty);
      now = now.add(const Duration(minutes: 10));
      await controller.complete(controller.document.active(now).single);
      expect(controller.document.activeMemories.single.id, id);
      expect(controller.document.activeMemories.single.day, '2026-11-15');
      expect((await store.load()).activeMemories.single.id, id);
    },
  );
  test(
    'delete keeps anonymous collection; undo and restore never duplicate',
    () async {
      await controller.complete(controller.document.active(now).single);
      await controller.delete('one');
      expect(controller.document.tasks, isEmpty);
      expect(controller.document.activeMemories.length, 1);
      await controller.undo();
      expect(controller.document.activeMemories.length, 1);
      final backup = BackupCodec.decode(
        BackupCodec.encode(controller.document),
      );
      await controller.restore(backup);
      await controller.restore(backup);
      expect(controller.document.activeMemories.length, 1);
      await controller.delete('one');
      await controller.clearAnonymousMemories();
      expect(controller.document.memories, isEmpty);
      expect(controller.canUndo, false);
    },
  );
  test(
    'repeat conversion moves source without inventing a new reward',
    () async {
      await controller.complete(controller.document.active(now).single);
      final id = controller.document.activeMemories.single.id;
      await controller.upsert(
        controller.document.tasks.single.copyWith(
          repeat: RepeatKind.daily,
          date: dateOnly(now),
        ),
      );
      await controller.upsert(
        controller.document.tasks.single.copyWith(repeat: RepeatKind.none),
      );
      expect(controller.document.activeMemories.single.id, id);
      await controller.complete(controller.document.active(now).single);
      expect(controller.document.activeMemories.length, 2);
      expect(controller.document.memories.map((m) => m.id).toSet().length, 2);
      final history = controller.document
          .history(now)
          .firstWhere((h) => h.key != 'once');
      await controller.reopen(history);
      expect(controller.document.activeMemories.length, 1);
    },
  );
  test(
    'valid legacy completion instants outside task calendar limits still migrate',
    () {
      final value = OrbitDocument(
        tasks: [
          OrbitTask(
            id: 'historic',
            title: '旧纪念',
            createdAt: DateTime(1999),
            records: {'once': '1999-01-01T12:00:00Z'},
          ),
        ],
      );
      expect(
        BackupCodec.decode(BackupCodec.encode(value)).activeMemories.single.day,
        '1999-01-01',
      );
    },
  );
  test(
    'island placement survives backup and completion undo without changing rewards',
    () async {
      await controller.complete(controller.document.active(now).single);
      final memoryId = controller.document.activeMemories.single.id;
      await controller.moveDecoration('sprout', .4, .7);
      expect(controller.document.activeMemories.single.id, memoryId);
      final restored = BackupCodec.decode(
        BackupCodec.encode(controller.document),
      );
      expect(restored.islandLayout['sprout'], [.4, .7]);
      await controller.undo();
      expect(controller.document.activeMemories, isEmpty);
      expect(controller.document.islandLayout['sprout'], [.4, .7]);
      await controller.complete(controller.document.active(now).single);
      expect(controller.document.activeMemories.single.id, memoryId);
      await controller.tidyIsland();
      expect(controller.document.islandLayout, isEmpty);
      expect(controller.document.activeMemories.length, 1);
    },
  );
  test(
    'legacy bytes preserved before upgrade; inferred dates stable',
    () async {
      final raw = OrbitDocument(
        tasks: [
          OrbitTask(
            id: 'old',
            title: '旧记录',
            createdAt: now,
            records: {'once': '2026-11-13T20:00:00Z'},
          ),
        ],
      ).toJson();
      raw.remove('memories');
      raw.remove('islandLayout');
      raw.remove('collectionVersion');
      final payload = jsonEncode(raw);
      final old = jsonEncode({
        'format': 'small-orbit',
        'version': 1,
        'payload': payload,
        'sha256': sha256.convert(utf8.encode(payload)).toString(),
      });
      await store.current.writeAsString(old);
      store = FailingPlayStore(dir);
      final loaded = await store.load();
      expect(loaded.memories.single.inferred, true);
      await store.save(loaded);
      expect(await (await store.backups()).single.readAsString(), old);
      expect(jsonDecode(await store.current.readAsString())['version'], 2);
      expect(
        (await store.load()).memories.single.day,
        loaded.memories.single.day,
      );
    },
  );
  test(
    'legacy recovery copy is archived before automatic format upgrade',
    () async {
      final envelope =
          jsonDecode(BackupCodec.encode(controller.document)) as Map;
      envelope['version'] = 1;
      final original =
          '${const JsonEncoder.withIndent('  ').convert(envelope)}\n';
      await store.previous.writeAsString(original);
      await store.current.writeAsString('damaged current');
      final recovering = LocalStore(dir);
      final loaded = await recovering.load();
      await recovering.save(loaded);
      expect(
        await (await recovering.backups()).single.readAsString(),
        original,
      );
      expect(
        BackupCodec.decode(
          await recovering.current.readAsString(),
        ).tasks.single.id,
        'one',
      );
    },
  );
  test(
    'failed legacy recovery archive leaves both source files untouched',
    () async {
      final envelope =
          jsonDecode(BackupCodec.encode(controller.document)) as Map;
      envelope['version'] = 1;
      final original = jsonEncode(envelope);
      await store.previous.writeAsString(original);
      await store.current.writeAsString('damaged current');
      await File(
        '${dir.path}/backups',
      ).writeAsString('block archive directory');
      await expectLater(
        LocalStore(dir).load(),
        throwsA(isA<FileSystemException>()),
      );
      expect(await store.current.readAsString(), 'damaged current');
      expect(await store.previous.readAsString(), original);
    },
  );
}
