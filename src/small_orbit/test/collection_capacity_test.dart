import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/core/local_store.dart';

void main() {
  test('format 2 retains 10000 tasks and 250000 completed history rows', () {
    final tasks = <OrbitTask>[];
    final timer = Stopwatch()..start();
    for (var i = 0; i < 10000; i++) {
      final records = <String, String?>{};
      if (i < 4) {
        for (var day = 0; day < 62500; day++) {
          final date = DateTime.utc(2000, 1, 1).add(Duration(days: day));
          records[dayKey(date)] = date.toIso8601String();
        }
      }
      tasks.add(
        OrbitTask(
          id: 'task_${i}_${'x' * 80}',
          title: '长标题' * 80,
          createdAt: DateTime(2026, 1, 1),
          records: records,
        ),
      );
    }
    final source = BackupCodec.encode(OrbitDocument(tasks: tasks));
    final bytes = utf8.encode(source).length;
    expect(bytes, lessThan(BackupCodec.maxBytes));
    final decoded = BackupCodec.decode(source);
    expect(decoded.tasks.length, 10000);
    expect(decoded.activeMemories.length, 250000);
    // Evidence printed to the remote test log; not a whole-app benchmark.
    // ignore: avoid_print
    print(
      'Collection capacity: $bytes bytes; ${timer.elapsedMilliseconds} ms encode/decode/model; max ${BackupCodec.maxBytes}',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
