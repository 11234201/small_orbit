import 'task_model.dart';
import 'play_settings.dart';

/// Compact, versioned souvenirs. No title copies: deleted tasks become anonymous.
class CompletionMemory {
  const CompletionMemory({
    required this.id,
    required this.taskId,
    required this.key,
    required this.completedAt,
    required this.day,
    required this.offsetMinutes,
    this.inferred = false,
    this.active = true,
  });
  final String id, taskId, key, completedAt, day;
  final int offsetMinutes;
  final bool inferred, active;
  int get seed => stableSeed(id);
  CompletionMemory update({
    String? key,
    String? completedAt,
    String? day,
    int? offsetMinutes,
    bool? inferred,
    bool? active,
  }) => CompletionMemory(
    id: id,
    taskId: taskId,
    key: key ?? this.key,
    completedAt: completedAt ?? this.completedAt,
    day: day ?? this.day,
    offsetMinutes: offsetMinutes ?? this.offsetMinutes,
    inferred: inferred ?? this.inferred,
    active: active ?? this.active,
  );
  List<Object> toJson() => [
    id,
    taskId,
    key,
    completedAt,
    day,
    offsetMinutes,
    (active ? 1 : 0) | (inferred ? 2 : 0),
  ];
  factory CompletionMemory.fromJson(Object? raw) {
    if (raw is! List ||
        raw.length != 7 ||
        raw.take(5).any((v) => v is! String) ||
        raw[5] is! int ||
        raw[6] is! int ||
        (raw[6] as int) < 0 ||
        (raw[6] as int) > 3 ||
        (raw[5] as int).abs() > 1440 ||
        (raw[0] as String).length > 240 ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(raw[1] as String) ||
        DateTime.tryParse(raw[3] as String) == null) {
      throw const FormatException('完成纪念无效');
    }
    final completedDay = DateTime.tryParse(raw[4] as String);
    if (completedDay == null || dayKey(completedDay) != raw[4])
      throw const FormatException('纪念日期无效');
    if (raw[2] != 'once') parseDay(raw[2] as String);
    return CompletionMemory(
      id: raw[0] as String,
      taskId: raw[1] as String,
      key: raw[2] as String,
      completedAt: raw[3] as String,
      day: raw[4] as String,
      offsetMinutes: raw[5] as int,
      active: (raw[6] as int) & 1 != 0,
      inferred: (raw[6] as int) & 2 != 0,
    );
  }
}

List<CompletionMemory> migrateMemories(Iterable<OrbitTask> tasks) => [
  for (final task in tasks)
    for (final record in task.records.entries)
      if (record.value != null)
        CompletionMemory(
          id: '${task.id}:${record.key}',
          taskId: task.id,
          key: record.key,
          completedAt: record.value!,
          day: dayKey(DateTime.parse(record.value!).toLocal()),
          offsetMinutes: DateTime.parse(
            record.value!,
          ).toLocal().timeZoneOffset.inMinutes,
          inferred: true,
        ),
];

/// Reconcile only tasks whose history changed; deletion intentionally keeps the
/// anonymous souvenir. The caller persists the result with the task mutation.
List<CompletionMemory> reconcileMemories(
  OrbitDocument before,
  OrbitDocument after,
  DateTime now,
) {
  final oldTasks = {for (final task in before.tasks) task.id: task};
  final changed = <String, OrbitTask>{};
  for (final task in after.tasks) {
    final old = oldTasks[task.id];
    if (old == null || !identical(old.records, task.records)) {
      changed[task.id] = task;
    }
  }
  if (changed.isEmpty) return after.memories;
  final result = after.memories.toList();
  final byTask = <String, List<int>>{};
  for (var i = 0; i < result.length; i++) {
    if (changed.containsKey(result[i].taskId)) {
      (byTask[result[i].taskId] ??= []).add(i);
    }
  }
  for (final task in changed.values) {
    final indexes = byTask[task.id] ?? <int>[];
    final byKey = {for (final i in indexes) result[i].key: i};
    final byTime = <String, List<int>>{};
    for (final i in indexes) {
      (byTime[result[i].completedAt] ??= []).add(i);
    }
    final used = <int>{};
    for (final entry in task.records.entries) {
      if (entry.value == null) continue;
      var index = byKey[entry.key];
      if (index != null && used.contains(index)) index = null;
      // Once -> daily -> once can move a record to a dated history key.
      index ??= byTime[entry.value]
          ?.where((i) => !used.contains(i))
          .firstOrNull;
      if (index != null) {
        used.add(index);
        final old = result[index];
        final sameInstant = old.completedAt == entry.value;
        result[index] = old.update(
          key: entry.key,
          completedAt: entry.value,
          day: sameInstant ? old.day : dayKey(now),
          offsetMinutes: sameInstant
              ? old.offsetMinutes
              : now.timeZoneOffset.inMinutes,
          inferred: sameInstant ? old.inferred : false,
          active: true,
        );
      } else {
        final baseId = '${task.id}:${entry.key}';
        // The original id may now belong to a converted historical occurrence.
        var id = baseId;
        var suffix = 1;
        final ids = indexes.map((i) => result[i].id).toSet();
        while (ids.contains(id)) {
          id = '$baseId-${suffix++}';
        }
        final index = result.length;
        result.add(
          CompletionMemory(
            id: id,
            taskId: task.id,
            key: entry.key,
            completedAt: entry.value!,
            day: dayKey(now),
            offsetMinutes: now.timeZoneOffset.inMinutes,
          ),
        );
        indexes.add(index);
        used.add(index);
      }
    }
    for (final i in indexes) {
      if (!used.contains(i) && result[i].active)
        result[i] = result[i].update(active: false);
    }
  }
  return result;
}
