import 'dart:async';
import 'package:flutter/foundation.dart';
import 'task_model.dart';
import 'local_store.dart';

class OrbitController extends ChangeNotifier {
  OrbitController(this.store, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  final LocalStore store;
  final DateTime Function() clock;
  OrbitDocument document = OrbitDocument();
  Future<void> _queue = Future.value();
  Future<void> Function(OrbitDocument)? onCommitted;
  OrbitTask? _undoTask;
  String? _undoId;
  String? undoLabel;
  String? notice;
  bool get canUndo => _undoId != null;

  Future<void> initialize() async {
    final loaded = await store.load();
    document = loaded.materialize(clock());
    if (!identical(loaded, document)) await store.save(document);
    notice = store.recoveryNotice;
    notifyListeners();
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.catchError((Object _) {});
    return result;
  }

  Future<void> _publish(OrbitDocument next) async {
    await store.save(next);
    document = next;
    notifyListeners();
    try {
      await onCommitted?.call(document);
    } catch (_) {
      notice = '数据已保存，提醒暂未更新，请在设置中重试。';
      notifyListeners();
    }
  }

  Future<void> upsert(OrbitTask task) => _enqueue(() async {
    final existing = document.materialize(clock());
    final tasks = existing.tasks.toList();
    final index = tasks.indexWhere((item) => item.id == task.id);
    if (index >= 0) {
      // Preserve newly materialized missed history when editing an open dialog.
      task = task.copyWith(records: {...tasks[index].records, ...task.records});
      tasks[index] = task;
    } else {
      tasks.add(task);
    }
    if (_undoId == task.id) {
      _undoId = null;
      undoLabel = null;
    }
    await _publish(existing.copyWith(tasks: tasks));
  });

  Future<void> complete(TaskOccurrence occurrence) => _enqueue(() async {
    final existing = document.materialize(clock());
    final index = existing.tasks.indexWhere(
      (task) => task.id == occurrence.task.id,
    );
    if (index < 0) return;
    final task = existing.tasks[index];
    if (task.records[occurrence.key] != null) return;
    final tasks = existing.tasks.toList();
    tasks[index] = task.copyWith(
      records: {
        ...task.records,
        occurrence.key: clock().toUtc().toIso8601String(),
      },
    );
    await _publish(existing.copyWith(tasks: tasks));
    _undoTask = task;
    _undoId = task.id;
    undoLabel = '完成了「${task.title}」';
    notifyListeners();
  });

  Future<void> delete(String id) => _enqueue(() async {
    final task = document.tasks.where((task) => task.id == id).firstOrNull;
    if (task == null) return;
    await _publish(
      document.copyWith(tasks: document.tasks.where((task) => task.id != id)),
    );
    _undoTask = task;
    _undoId = id;
    undoLabel = '已删除「${task.title}」';
    notifyListeners();
  });

  Future<void> undo() => _enqueue(() async {
    if (_undoId == null || _undoTask == null) return;
    final tasks = document.tasks.toList();
    final index = tasks.indexWhere((task) => task.id == _undoId);
    final restored = _undoTask!.materializeMissed(clock());
    if (index < 0) {
      tasks.add(restored);
    } else {
      tasks[index] = restored;
    }
    await _publish(document.copyWith(tasks: tasks));
    _undoTask = null;
    _undoId = null;
    undoLabel = null;
    notifyListeners();
  });

  Future<void> reopen(HistoryEntry entry) => _enqueue(() async {
    final tasks = document.tasks.toList();
    final index = tasks.indexWhere((task) => task.id == entry.task.id);
    if (index < 0) return;
    final records = Map.of(tasks[index].records)..remove(entry.key);
    tasks[index] = tasks[index]
        .copyWith(records: records)
        .materializeMissed(clock());
    await _publish(document.copyWith(tasks: tasks));
    _undoId = null;
    undoLabel = null;
    notifyListeners();
  });

  Future<void> settings(AppSettings settings) =>
      _enqueue(() => _publish(document.copyWith(settings: settings)));
  Future<void> rollover() => _enqueue(() async {
    final next = document.materialize(clock());
    if (!identical(next, document))
      await _publish(next);
    else {
      notifyListeners();
    }
  });
  Future<void> restore(OrbitDocument incoming) => _enqueue(() async {
    final next = incoming.materialize(clock());
    final backup = await store.restore(next, document);
    document = next;
    _undoId = null;
    undoLabel = null;
    notice = '恢复完成。替换前数据已备份：${backup.uri.pathSegments.last}';
    notifyListeners();
    try {
      await onCommitted?.call(document);
    } catch (_) {
      notice = '恢复完成，提醒更新失败，请在设置中重试。';
      notifyListeners();
    }
  });
}
