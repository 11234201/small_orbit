import 'dart:math';
import 'task_model.dart';
import 'play_settings.dart';

enum PickRule { random, fiveMinutes, light, important }

const pickLabels = ['随便抽一件', '只有 5 分钟', '想做轻松的', '今天最重要的'];

class TaskPicker {
  TaskPicker({Random? random}) : random = random ?? Random();
  final Random random;
  final Set<String> _seen = {};
  String _scope = '';
  List<TaskOccurrence> candidates(
    OrbitDocument document,
    DateTime now,
    PickRule rule, {
    bool todayOnly = true,
  }) {
    var items = document.active(
      now,
      todayOnly: rule == PickRule.important || todayOnly,
    );
    items = items
        .where(
          (item) => switch (rule) {
            PickRule.fiveMinutes =>
              item.task.estimatedMinutes != null &&
                  item.task.estimatedMinutes! <= 5,
            PickRule.light => item.task.energy == TaskEnergy.light,
            _ => true,
          },
        )
        .toList();
    if (rule == PickRule.important && items.isNotEmpty) {
      final best = items
          .map((i) => i.task.importance * 10 + i.task.urgency)
          .reduce(max);
      items = items
          .where((i) => i.task.importance * 10 + i.task.urgency == best)
          .toList();
    }
    return items;
  }

  TaskOccurrence? draw(
    OrbitDocument document,
    DateTime now,
    PickRule rule, {
    bool todayOnly = true,
  }) {
    final scope = '${rule.name}:$todayOnly';
    if (_scope != scope) {
      _seen.clear();
      _scope = scope;
    }
    final items = candidates(document, now, rule, todayOnly: todayOnly);
    if (items.isEmpty) return null;
    final ids = items.map((i) => i.identity).toSet();
    _seen.removeWhere((id) => !ids.contains(id));
    var remaining = items.where((i) => !_seen.contains(i.identity)).toList();
    if (remaining.isEmpty) {
      _seen.clear();
      remaining = items;
    }
    final item = remaining[random.nextInt(remaining.length)];
    _seen.add(item.identity);
    return item;
  }
}
