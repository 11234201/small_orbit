import 'dart:math';
import 'package:characters/characters.dart';

enum DisplayMode { bubbles, papers, cards }

enum MotionMode { opening, gentle, lively }

enum RepeatKind { none, daily, weekly }

DateTime dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);
String dayKey(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
final _dayPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

List<int> _dayParts(String value) {
  if (!_dayPattern.hasMatch(value)) {
    throw const FormatException('日期格式无效');
  }
  final parts = value.split('-').map(int.parse).toList();
  final year = parts[0], month = parts[1], day = parts[2];
  if (year < 2000 || year > 2200 || month < 1 || month > 12) {
    throw const FormatException('日期超出有效范围');
  }
  final leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
  const daysInMonth = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  final maximumDay = month == 2 && leap ? 29 : daysInMonth[month - 1];
  if (day < 1 || day > maximumDay) {
    throw const FormatException('日期超出有效范围');
  }
  return parts;
}

DateTime parseDay(String value) {
  final parts = _dayParts(value);
  final result = DateTime(parts[0], parts[1], parts[2]);
  if (dayKey(result) != value) {
    throw const FormatException('日期超出有效范围');
  }
  return result;
}

int daysBetween(DateTime start, DateTime end) => DateTime.utc(
  end.year,
  end.month,
  end.day,
).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
DateTime addDays(DateTime value, int days) =>
    DateTime(value.year, value.month, value.day + days);
String newTaskId() {
  final random = Random.secure();
  return '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-'
      '${List.generate(12, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}

T enumValue<T extends Enum>(List<T> values, Object? value, String field) {
  for (final entry in values) {
    if (entry.name == value) return entry;
  }
  throw FormatException('$field 无效');
}

class AppSettings {
  const AppSettings({
    this.display = DisplayMode.bubbles,
    this.motion = MotionMode.opening,
    this.paused = false,
    this.reduceMotion = false,
    this.remindersEnabled = true,
    this.windowGeometry,
  });
  final DisplayMode display;
  final MotionMode motion;
  final bool paused;
  final bool reduceMotion;
  final bool remindersEnabled;
  final Map<String, int>? windowGeometry;

  AppSettings copyWith({
    DisplayMode? display,
    MotionMode? motion,
    bool? paused,
    bool? reduceMotion,
    bool? remindersEnabled,
    Map<String, int>? windowGeometry,
  }) => AppSettings(
    display: display ?? this.display,
    motion: motion ?? this.motion,
    paused: paused ?? this.paused,
    reduceMotion: reduceMotion ?? this.reduceMotion,
    remindersEnabled: remindersEnabled ?? this.remindersEnabled,
    windowGeometry: windowGeometry ?? this.windowGeometry,
  );

  Map<String, Object?> toJson() => {
    'display': display.name,
    'motion': motion.name,
    'paused': paused,
    'reduceMotion': reduceMotion,
    'remindersEnabled': remindersEnabled,
    if (windowGeometry != null) 'windowGeometry': windowGeometry,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    for (final key in ['paused', 'reduceMotion', 'remindersEnabled']) {
      if (json[key] is! bool) throw FormatException('设置 $key 无效');
    }
    Map<String, int>? geometry;
    if (json['windowGeometry'] != null) {
      final raw = Map<String, dynamic>.from(json['windowGeometry'] as Map);
      if (!['x', 'y', 'width', 'height'].every((key) => raw[key] is int)) {
        throw const FormatException('窗口位置无效');
      }
      geometry = raw.map((key, value) => MapEntry(key, value as int));
    }
    return AppSettings(
      display: enumValue(DisplayMode.values, json['display'], '展示方式'),
      motion: enumValue(MotionMode.values, json['motion'], '运动方式'),
      paused: json['paused'] as bool,
      reduceMotion: json['reduceMotion'] as bool,
      remindersEnabled: json['remindersEnabled'] as bool,
      windowGeometry: geometry,
    );
  }
}

class OrbitTask {
  OrbitTask({
    required this.id,
    required this.title,
    required this.createdAt,
    this.date,
    this.reminderMinute,
    this.repeat = RepeatKind.none,
    this.importance = 2,
    this.urgency = 2,
    Map<String, String?> records = const {},
  }) : records = Map.unmodifiable(records);
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime? date;
  final int? reminderMinute;
  final RepeatKind repeat;
  final int importance;
  final int urgency;

  /// A null value is a missed occurrence; an ISO timestamp is a completion.
  final Map<String, String?> records;

  // An in-memory coverage marker for this immutable history. It is never
  // serialized: imported or edited histories are checked before being cached.
  DateTime? _materializedBefore;

  OrbitTask copyWith({
    String? title,
    DateTime? date,
    bool clearDate = false,
    int? reminderMinute,
    bool clearReminder = false,
    RepeatKind? repeat,
    int? importance,
    int? urgency,
    Map<String, String?>? records,
  }) {
    final result = OrbitTask(
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      date: clearDate ? null : date ?? this.date,
      reminderMinute: clearReminder
          ? null
          : reminderMinute ?? this.reminderMinute,
      repeat: repeat ?? this.repeat,
      importance: importance ?? this.importance,
      urgency: urgency ?? this.urgency,
      records: records ?? this.records,
    );
    if (result.date == this.date &&
        result.repeat == this.repeat &&
        (records == null || identical(records, this.records))) {
      result._materializedBefore = _materializedBefore;
    }
    return result;
  }

  int get intervalDays => repeat == RepeatKind.weekly ? 7 : 1;
  int get priority => importance + urgency;
  String get repeatLabel => switch (repeat) {
    RepeatKind.none => '不重复',
    RepeatKind.daily => '每天',
    RepeatKind.weekly =>
      '每周${['一', '二', '三', '四', '五', '六', '日'][date!.weekday - 1]}',
  };
  DateTime? periodAt(DateTime now) {
    if (date == null || repeat == RepeatKind.none) return date;
    final today = dateOnly(now);
    if (today.isBefore(date!)) return date;
    return addDays(
      date!,
      (daysBetween(date!, today) ~/ intervalDays) * intervalDays,
    );
  }

  TaskOccurrence? activeAt(DateTime now) {
    if (repeat == RepeatKind.none) {
      return records['once'] != null
          ? null
          : TaskOccurrence(this, 'once', date);
    }
    var day = periodAt(now)!;
    for (var i = 0; i <= records.length; i++) {
      if (records[dayKey(day)] == null)
        return TaskOccurrence(this, dayKey(day), day);
      day = addDays(day, intervalDays);
    }
    throw StateError('重复周期无法推进');
  }

  OrbitTask materializeMissed(DateTime now) {
    if (repeat == RepeatKind.none ||
        date == null ||
        dateOnly(now).isBefore(date!))
      return this;
    final period = periodAt(now)!;
    final covered = _materializedBefore;
    // Compare calendar components, so a timezone change cannot invalidate the
    // coverage of the same date labels or truncate history after clock rollback.
    if (covered != null && daysBetween(period, covered) >= 0) return this;
    Map<String, String?>? updated;
    for (
      var day = covered ?? date!;
      day.isBefore(period);
      day = addDays(day, intervalDays)
    ) {
      final key = dayKey(day);
      if (!records.containsKey(key)) (updated ??= Map.of(records))[key] = null;
    }
    final result = updated == null ? this : copyWith(records: updated);
    result._materializedBefore = period;
    return result;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'date': date == null ? null : dayKey(date!),
    'reminderMinute': reminderMinute,
    'repeat': repeat.name,
    'importance': importance,
    'urgency': urgency,
    'records': records,
  };

  factory OrbitTask.fromJson(Map<String, dynamic> json) {
    if (json['id'] is! String ||
        !(json['id'] as String).contains(RegExp(r'^[a-zA-Z0-9_-]{1,100}$'))) {
      throw const FormatException('任务标识无效');
    }
    if (json['title'] is! String ||
        (json['title'] as String).trim().isEmpty ||
        (json['title'] as String).characters.length > 240) {
      throw const FormatException('任务标题无效或超过 240 字符');
    }
    for (final key in ['importance', 'urgency']) {
      if (json[key] is! int ||
          (json[key] as int) < 1 ||
          (json[key] as int) > 3) {
        throw FormatException('$key 必须为 1–3');
      }
    }
    final created = DateTime.tryParse(
      json['createdAt'] is String ? json['createdAt'] as String : '',
    );
    if (created == null) throw const FormatException('创建时间无效');
    final date = json['date'] == null ? null : parseDay(json['date'] as String);
    final repeat = enumValue(RepeatKind.values, json['repeat'], '重复规则');
    final minute = json['reminderMinute'];
    if (minute != null && (minute is! int || minute < 0 || minute >= 1440)) {
      throw const FormatException('提醒时间无效');
    }
    if ((repeat != RepeatKind.none || minute != null) && date == null) {
      throw const FormatException('重复或提醒任务缺少日期');
    }
    if (json['records'] is! Map || (json['records'] as Map).length > 80000) {
      throw const FormatException('历史记录无效或过多');
    }
    final records = <String, String?>{};
    for (final entry in (json['records'] as Map).entries) {
      if (entry.key is! String) throw const FormatException('历史日期无效');
      final key = entry.key as String;
      // History keys are calendar labels, not instants in the current timezone.
      // Validate their Gregorian date without constructing thousands of local
      // DateTimes. Actual task dates are still converted through parseDay above.
      if (key != 'once') _dayParts(key);
      if (entry.value != null &&
          (entry.value is! String ||
              DateTime.tryParse(entry.value as String) == null)) {
        throw const FormatException('完成时间无效');
      }
      records[key] = entry.value as String?;
    }
    return OrbitTask(
      id: json['id'] as String,
      title: (json['title'] as String).trim(),
      createdAt: created,
      date: date,
      repeat: repeat,
      reminderMinute: minute as int?,
      importance: json['importance'] as int,
      urgency: json['urgency'] as int,
      records: records,
    );
  }
}

class TaskOccurrence {
  const TaskOccurrence(this.task, this.key, this.day);
  final OrbitTask task;
  final String key;
  final DateTime? day;
  String get identity => '${task.id}:$key';
  bool visibleToday(DateTime now) =>
      day == null || !day!.isAfter(dateOnly(now));
  DateTime? get reminderAt => day == null || task.reminderMinute == null
      ? null
      : DateTime(
          day!.year,
          day!.month,
          day!.day,
          task.reminderMinute! ~/ 60,
          task.reminderMinute! % 60,
        );
}

class HistoryEntry {
  const HistoryEntry(this.task, this.key, this.day, this.completedAt);
  final OrbitTask task;
  final String key;
  final DateTime day;
  final DateTime? completedAt;
  bool get completed => completedAt != null;
}

class OrbitDocument {
  OrbitDocument({
    Iterable<OrbitTask> tasks = const [],
    this.settings = const AppSettings(),
  }) : tasks = List.unmodifiable(tasks);
  final List<OrbitTask> tasks;
  final AppSettings settings;
  OrbitDocument copyWith({Iterable<OrbitTask>? tasks, AppSettings? settings}) =>
      OrbitDocument(
        tasks: tasks ?? this.tasks,
        settings: settings ?? this.settings,
      );

  OrbitDocument materialize(DateTime now) {
    List<OrbitTask>? updated;
    for (var i = 0; i < tasks.length; i++) {
      final task = tasks[i].materializeMissed(now);
      if (!identical(tasks[i], task)) {
        (updated ??= tasks.toList())[i] = task;
      }
    }
    return updated == null ? this : copyWith(tasks: updated);
  }

  List<TaskOccurrence> active(DateTime now, {bool todayOnly = true}) {
    final result = <TaskOccurrence>[];
    for (final task in tasks) {
      final occurrence = task.activeAt(now);
      if (occurrence != null && (!todayOnly || occurrence.visibleToday(now)))
        result.add(occurrence);
    }
    result.sort((a, b) {
      final priority = b.task.priority.compareTo(a.task.priority);
      if (priority != 0) return priority;
      return a.task.createdAt.compareTo(b.task.createdAt);
    });
    return result;
  }

  List<HistoryEntry> history(DateTime now, {int days = 30}) {
    final first = addDays(dateOnly(now), -days + 1), result = <HistoryEntry>[];
    final firstKey = dayKey(first), lastKey = dayKey(now);
    for (final task in tasks) {
      for (final entry in task.records.entries) {
        // Validated YYYY-MM-DD keys sort in calendar order. Avoid parsing
        // timestamps and constructing local dates for history outside the view.
        if (entry.key != 'once' &&
            (entry.key.compareTo(firstKey) < 0 ||
                entry.key.compareTo(lastKey) > 0)) {
          continue;
        }
        final completedAt = entry.value == null
            ? null
            : DateTime.parse(entry.value!).toLocal();
        final day = entry.key == 'once'
            ? dateOnly(completedAt ?? task.createdAt)
            : parseDay(entry.key);
        if (!day.isBefore(first) && !day.isAfter(dateOnly(now))) {
          result.add(HistoryEntry(task, entry.key, day, completedAt));
        }
      }
    }
    result.sort((a, b) => b.day.compareTo(a.day));
    return result;
  }

  Map<String, Object?> toJson() => {
    'settings': settings.toJson(),
    'tasks': tasks.map((task) => task.toJson()).toList(),
  };
  factory OrbitDocument.fromJson(Map<String, dynamic> json) {
    if (json['tasks'] is! List ||
        (json['tasks'] as List).length > 10000 ||
        json['settings'] is! Map) {
      throw const FormatException('任务文件结构无效');
    }
    final tasks = (json['tasks'] as List)
        .map(
          (item) => OrbitTask.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
    if (tasks.map((task) => task.id).toSet().length != tasks.length)
      throw const FormatException('存在重复任务标识');
    if (tasks.fold<int>(0, (sum, task) => sum + task.records.length) > 250000)
      throw const FormatException('历史记录过多');
    return OrbitDocument(
      tasks: tasks,
      settings: AppSettings.fromJson(
        Map<String, dynamic>.from(json['settings'] as Map),
      ),
    );
  }
}
