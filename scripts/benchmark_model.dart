// Run with the same Dart SDK and execution mode before and after model changes.
// This measures data-model operations, not app launch, UI frames, or battery use.
import 'dart:convert';
import 'dart:io';

import '../src/small_orbit/lib/core/task_model.dart';

final benchmarkDay = DateTime(2026, 11, 10, 12);
var checksum = 0;

OrbitDocument fixture(int taskCount, int recurringCount) => OrbitDocument(
  tasks: List.generate(
    taskCount,
    (index) => OrbitTask(
      id: 'benchmark_$index',
      title: '小事 $index',
      createdAt: DateTime(2021, 1, 1),
      date: index < recurringCount ? DateTime(2021, 1, 1) : null,
      repeat: index < recurringCount ? RepeatKind.daily : RepeatKind.none,
      importance: index % 3 + 1,
      urgency: (index ~/ 3) % 3 + 1,
    ),
  ),
);

Map<String, Object> measure(int iterations, void Function() action) {
  for (var i = 0; i < 3; i++) {
    action();
  }
  final samples = <double>[];
  for (var round = 0; round < 7; round++) {
    final timer = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      action();
    }
    timer.stop();
    samples.add(timer.elapsedMicroseconds / iterations);
  }
  final sorted = [...samples]..sort();
  return {
    'iterations_per_sample': iterations,
    'samples_us_per_op': samples,
    'median_us_per_op': sorted[3],
    'min_us_per_op': sorted.first,
    'max_us_per_op': sorted.last,
  };
}

void main(List<String> arguments) {
  final result = <String, Object>{
    'label': arguments.isEmpty ? 'unspecified' : arguments.first,
    'recorded_at_utc': DateTime.now().toUtc().toIso8601String(),
    'dart': Platform.version,
    'os': Platform.operatingSystemVersion,
    'processors': Platform.numberOfProcessors,
    'fixture_day': dayKey(benchmarkDay),
    'rounds': 7,
    'warmup_operations': 3,
  };
  final cases = <Map<String, Object>>[];
  for (final entry in [
    ('empty', 0, 0),
    ('personal_100', 100, 10),
    ('large_1000', 1000, 25),
    ('long_history_100', 100, 100),
  ]) {
    final doc = fixture(entry.$2, entry.$3).materialize(benchmarkDay);
    final encoded = jsonEncode(doc.toJson());
    final sample = <String, Object>{
      'name': entry.$1,
      'tasks': entry.$2,
      'daily_tasks_since_2021': entry.$3,
      'history_records': doc.tasks.fold<int>(
        0,
        (sum, task) => sum + task.records.length,
      ),
      'json_bytes': utf8.encode(encoded).length,
      'steady_materialize': measure(20, () {
        checksum += doc.materialize(benchmarkDay).tasks.length;
      }),
      'active_list': measure(20, () {
        checksum += doc.active(benchmarkDay).length;
      }),
      'recent_history': measure(5, () {
        checksum += doc.history(benchmarkDay).length;
      }),
      'decode_model': measure(3, () {
        checksum += OrbitDocument.fromJson(
          jsonDecode(encoded) as Map<String, dynamic>,
        ).tasks.length;
      }),
    };
    cases.add(sample);
  }
  result['cases'] = cases;
  result['checksum'] = checksum;
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
}
