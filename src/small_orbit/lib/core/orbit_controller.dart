import 'dart:async';
import 'package:flutter/foundation.dart';
import 'task_model.dart';
import 'local_store.dart';
import 'completion_collection.dart';

class OrbitController extends ChangeNotifier {
  OrbitController(this.store, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  final LocalStore store;
  final DateTime Function() clock;
  OrbitDocument document = OrbitDocument();
  Future<void> _queue = Future.value();
  bool _closing = false;
  int _failedOperations = 0;
  Future<void> Function(OrbitDocument)? onCommitted;
  OrbitTask? _undoTask;
  String? _undoId;
  String? undoLabel;
  String? notice;
  String? _startupRolloverNotice;
  int restoreGeneration = 0;
  bool get canUndo => _undoId != null;

  Future<void> initialize() async {
    final loaded = await store.load();
    document = loaded;
    notice = store.recoveryNotice;
    _startupRolloverNotice = null;
    final next = loaded.materialize(clock());
    if (!identical(loaded, next)) {
      try {
        await store.save(next);
        document = next;
      } catch (error) {
        // Loading a valid database succeeded. Optional startup maintenance can
        // still fail because the disk is full or history reached its limit.
        // Keep the durable state accessible for export/deletion/retry instead
        // of sending it to the corrupt-file recovery screen.
        notice =
            '${notice == null ? '' : '$notice\n'}'
            '小事已打开，但跨天历史暂未保存。可先导出备份、检查存储空间或删除不需要的任务后重试：$error';
        _startupRolloverNotice = notice;
      }
    }
    notifyListeners();
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    if (_closing) return Future.error(StateError('正在保存并退出，请稍候'));
    final result = _queue.then((_) => action());
    _queue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {
        _failedOperations++;
      },
    );
    return result;
  }

  /// Export the state after all previously requested writes have finished.
  Future<OrbitDocument> snapshot() => _enqueue(() async => document);

  /// Stop accepting new writes before a native explicit-exit request. Every
  /// operation already accepted is allowed to finish before the window closes.
  Future<void> closeWrites({Future<void> Function()? afterDrain}) async {
    final failuresBeforeClose = _failedOperations;
    _closing = true;
    try {
      await _queue;
      if (_failedOperations != failuresBeforeClose) {
        throw StateError('保存没有完成，已保留窗口，请重试');
      }
      await afterDrain?.call();
    } catch (_) {
      // Native shutdown can also fail while flushing reminder receipts. A
      // rejected quit must leave the existing window able to accept writes.
      _closing = false;
      rethrow;
    }
  }

  Future<void> _publish(OrbitDocument next) async {
    next = next.copyWith(memories: reconcileMemories(document, next, clock()));
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
      // The editor owns task fields, never history. Its snapshot may predate a
      // completion, undo, or midnight rollover made while it was open.
      final previous = tasks[index];
      var records = previous.records;
      if (previous.repeat != RepeatKind.none &&
          task.repeat == RepeatKind.none) {
        records = Map.of(records);
        final once = records.remove('once');
        if (once != null) {
          // A task that went once -> recurring -> once starts its new single
          // occurrence pending. Preserve the earlier completion in day-level
          // history; if that day is already complete, retain that existing
          // completion instead of producing two rows for the same task/day.
          final completedDay = dayKey(DateTime.parse(once).toLocal());
          records[completedDay] ??= once;
        }
      }
      task = task.copyWith(records: records);
      tasks[index] = task;
    } else {
      tasks.add(task);
    }
    // A newly created or rescheduled recurrence may start in the past. Its
    // history must be complete immediately, including an export or history
    // view opened before the next reminder/rollover tick.
    await _publish(existing.copyWith(tasks: tasks).materialize(clock()));
    if (_undoId == task.id) {
      _undoId = null;
      undoLabel = null;
      notifyListeners();
    }
  });

  Future<void> complete(TaskOccurrence occurrence) => _enqueue(() async {
    final existing = document.materialize(clock());
    final index = existing.tasks.indexWhere(
      (task) => task.id == occurrence.task.id,
    );
    if (index < 0) return;
    final task = existing.tasks[index];
    final active = task.activeAt(clock());
    // A delayed tap/animation must not complete an occurrence that was moved
    // to another day, changed to a different recurrence, or already rolled over.
    if (active == null ||
        active.key != occurrence.key ||
        active.day != occurrence.day ||
        task.repeat != occurrence.task.repeat)
      return;
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

  Future<void> moveDecoration(String id, double x, double y) => _enqueue(
    () => _publish(
      document.copyWith(
        islandLayout: {
          ...document.islandLayout,
          id: [x.clamp(0.0, 1.0), y.clamp(0.0, 1.0)],
        },
      ),
    ),
  );
  Future<void> tidyIsland() =>
      _enqueue(() => _publish(document.copyWith(islandLayout: {})));
  Future<void> clearAnonymousMemories() => _enqueue(() async {
    final ids = document.tasks.map((t) => t.id).toSet();
    await _publish(
      document.copyWith(
        memories: document.memories
            .where((m) => ids.contains(m.taskId))
            .toList(),
      ),
    );
    _undoTask = null;
    _undoId = null;
    undoLabel = null;
    notifyListeners();
  });

  Future<void> settings(AppSettings settings) =>
      _enqueue(() => _publish(document.copyWith(settings: settings)));

  /// Apply a UI preference change to the latest committed settings rather than
  /// a snapshot captured before other queued writes. This preserves unrelated
  /// changes and also lets a pending selection be changed back to its old value.
  Future<void> updateSettings(AppSettings Function(AppSettings) update) =>
      _enqueue(
        () => _publish(document.copyWith(settings: update(document.settings))),
      );
  Future<void> rollover() => _enqueue(() async {
    final next = document.materialize(clock());
    if (!identical(next, document))
      await _publish(next);
    else {
      notifyListeners();
    }
    if (_startupRolloverNotice != null) {
      if (notice == _startupRolloverNotice) {
        notice = store.recoveryNotice;
        notifyListeners();
      }
      _startupRolloverNotice = null;
    }
  });
  Future<void> restore(OrbitDocument incoming) => _enqueue(() async {
    final next = incoming.materialize(clock());
    final backup = await store.restore(next, document);
    document = next;
    restoreGeneration++;
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
