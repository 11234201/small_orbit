import 'task_model.dart';

enum FocusPhase { running, paused, finished, ended }

class FocusSession {
  const FocusSession({
    required this.id,
    required this.taskId,
    required this.key,
    required this.taskDay,
    required this.repeat,
    required this.durationSeconds,
    required this.remainingSeconds,
    required this.deadline,
    required this.phase,
  });
  final String id, taskId, key;
  final String? taskDay;
  final RepeatKind repeat;
  final int durationSeconds, remainingSeconds;
  final DateTime deadline;
  final FocusPhase phase;
  bool get ongoing => phase == FocusPhase.running || phase == FocusPhase.paused;
  int remaining(DateTime now) => phase == FocusPhase.running
      ? ((deadline.difference(now).inMilliseconds + 999) ~/ 1000).clamp(
          0,
          durationSeconds,
        )
      : remainingSeconds;
  bool matches(TaskOccurrence item) =>
      taskId == item.task.id &&
      key == item.key &&
      taskDay == (item.day == null ? null : dayKey(item.day!)) &&
      repeat == item.task.repeat;
  FocusSession change(FocusPhase phase, DateTime now, {int? remaining}) {
    final seconds = remaining ?? this.remaining(now);
    return FocusSession(
      id: id,
      taskId: taskId,
      key: key,
      taskDay: taskDay,
      repeat: repeat,
      durationSeconds: durationSeconds,
      remainingSeconds: phase == FocusPhase.finished ? 0 : seconds,
      deadline: now.add(Duration(seconds: seconds)),
      phase: phase,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'taskId': taskId,
    'key': key,
    'taskDay': taskDay,
    'repeat': repeat.name,
    'duration': durationSeconds,
    'remaining': remainingSeconds,
    'deadline': deadline.toUtc().toIso8601String(),
    'phase': phase.name,
  };
  factory FocusSession.fromJson(Map<String, dynamic> raw) {
    for (final field in ['id', 'taskId', 'key']) {
      if (raw[field] is! String || (raw[field] as String).length > 240)
        throw const FormatException('专注记录无效');
    }
    final duration = raw['duration'], remaining = raw['remaining'];
    if (duration is! int ||
        duration < 60 ||
        duration > 10800 ||
        remaining is! int ||
        remaining < 0 ||
        remaining > duration) {
      throw const FormatException('专注时长无效');
    }
    if (raw['taskDay'] != null) parseDay(raw['taskDay'] as String);
    return FocusSession(
      id: raw['id'] as String,
      taskId: raw['taskId'] as String,
      key: raw['key'] as String,
      taskDay: raw['taskDay'] as String?,
      repeat: enumValue(RepeatKind.values, raw['repeat'], '专注周期'),
      durationSeconds: duration,
      remainingSeconds: remaining,
      deadline: DateTime.parse(raw['deadline'] as String),
      phase: enumValue(FocusPhase.values, raw['phase'], '专注状态'),
    );
  }
}
