import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/task_model.dart';
import '../core/orbit_controller.dart';

enum ReminderPlatform { android, windows, unsupported }

class ReminderService extends ChangeNotifier {
  ReminderService(
    this.controller, {
    ReminderPlatform? platform,
    MethodChannel? bridge,
  }) : platform =
           platform ??
           (Platform.isAndroid
               ? ReminderPlatform.android
               : Platform.isWindows
               ? ReminderPlatform.windows
               : ReminderPlatform.unsupported),
       bridge = bridge ?? channel;
  final OrbitController controller;
  final ReminderPlatform platform;
  final MethodChannel bridge;
  static const channel = MethodChannel('small_orbit/platform');
  Timer? _timer;
  final Set<String> _delivered = {};
  bool _receiptsDirty = false;
  Future<void>? _starting;
  Future<void>? _stopFuture;
  Future<void>? _checking;
  Future<void> _syncQueue = Future.value();
  String? _lastConfig;
  String? lastError;
  bool _disposed = false;
  bool _stopping = false;
  bool _historyFailed = false;
  static const _retryMessage = '提醒暂未更新，将自动重试；也可以在设置中重试。';
  static const _historyMessage = '历史暂未保存，提醒仍按现有任务尝试。请检查存储空间或清理旧任务。';

  void _report(String? error) {
    if (_disposed || _stopping || lastError == error) return;
    lastError = error;
    notifyListeners();
  }

  File get _receiptFile =>
      File('${controller.store.directory.path}/reminders.json');
  Future<void> start() {
    if (_disposed || _stopping) return Future.value();
    // Windows receipt loading yields before the timer is installed. Share that
    // work so concurrent starts cannot leave a second periodic timer behind.
    return _starting ??= _start();
  }

  Future<void> _start() async {
    if (platform == ReminderPlatform.windows) {
      try {
        if (await _receiptFile.exists()) {
          _delivered.addAll(
            (jsonDecode(await _receiptFile.readAsString()) as List)
                .cast<String>(),
          );
        }
      } catch (_) {
        /* A corrupt receipt file must not stop the task database. */
      }
    }
    if (_disposed || _stopping) return;
    controller.onCommitted = (_) => synchronize();
    // Keep the retry timer even when the initial platform call fails.
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => tick());
    await tick(forceSync: true);
  }

  Future<void> tick({bool forceSync = false}) async {
    if (_disposed || _stopping) return;
    final checking = _checking;
    if (checking != null) {
      await checking;
      if (forceSync && !_disposed && !_stopping) await tick(forceSync: true);
      return;
    }
    final running = _tick(forceSync: forceSync);
    _checking = running;
    await running;
    if (identical(_checking, running)) _checking = null;
  }

  Future<void> _tick({required bool forceSync}) async {
    var historyFailed = false;
    try {
      await controller.rollover();
    } catch (_) {
      // Missed-history maintenance is not a prerequisite for determining the
      // current reminder. A quota/disk error must not disable valid reminders.
      historyFailed = true;
    }
    _historyFailed = historyFailed;
    if (_disposed || _stopping) return;
    try {
      await synchronize(force: forceSync);
      if (platform == ReminderPlatform.windows) await _checkWindows();
      _report(_historyFailed ? _historyMessage : null);
    } catch (_) {
      _report(_retryMessage);
    }
  }

  Future<void> synchronize({bool force = false}) {
    final result = _syncQueue.then((_) async {
      if (_disposed || _stopping) return;
      try {
        // Read after preceding platform calls, never reuse a stale UI snapshot.
        final document = controller.document;
        if (platform == ReminderPlatform.android) {
          final config = jsonEncode({
            'enabled': document.settings.remindersEnabled,
            'tasks': document.tasks
                .where((task) => task.reminderMinute != null)
                .map((task) => task.toJson())
                .toList(),
          });
          if (force || config != _lastConfig) {
            await bridge.invokeMethod('syncReminders', config);
            _lastConfig = config;
          }
          _report(_historyFailed ? _historyMessage : null);
        }
      } catch (_) {
        // A failed platform reply does not mean nothing changed natively. An
        // undo can return to the last acknowledged configuration while native
        // state still contains part of the failed update, so it must be sent.
        _lastConfig = null;
        _report(_retryMessage);
        rethrow;
      }
    });
    _syncQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> retry() async {
    await tick(forceSync: true);
    if (lastError != null) throw StateError(lastError!);
  }

  Future<void> _checkWindows() async {
    // Delivery and receipt persistence are separate operations. If the latter
    // fails, retain the in-memory receipt and retry its write before reporting
    // recovery, including after reminders have been disabled.
    await _flushReceipts();
    if (!controller.document.settings.remindersEnabled) return;
    final ids = controller.document.tasks.map((task) => task.id).toList();
    for (final id in ids) {
      if (_disposed ||
          _stopping ||
          !controller.document.settings.remindersEnabled)
        return;
      // Earlier notification calls can yield while another task is edited or
      // deleted. Re-read each task before asking the native platform to notify.
      final task = controller.document.tasks
          .where((task) => task.id == id)
          .firstOrNull;
      if (task == null) continue;
      final now = controller.clock();
      final occurrence = task.activeAt(now);
      final at = occurrence?.reminderAt;
      if (occurrence == null || at == null || at.isAfter(now)) continue;
      // Past days remain visible in the app, without a burst of stale alerts.
      if (dayKey(at) != dayKey(now)) continue;
      // Reminders are wall-clock appointments. The same local day/minute must
      // stay delivered when a device changes timezone, even though its UTC
      // instant changes. Retain recognition of receipts written by rc.2.
      final receipt =
          'v2:${occurrence.identity}:${dayKey(at)}:${task.reminderMinute}';
      if (_delivered.contains(receipt)) continue;
      final legacy = '${occurrence.identity}:${at.millisecondsSinceEpoch}';
      if (_delivered.remove(legacy)) {
        _delivered.add(receipt);
        _receiptsDirty = true;
        await _flushReceipts();
        continue;
      }
      await bridge.invokeMethod('showNotification', {
        'title': '小事星球 · 该做这件小事啦',
        'body': task.title,
      });
      _delivered.add(receipt);
      if (_delivered.length > 20000) _delivered.remove(_delivered.first);
      _receiptsDirty = true;
      await _flushReceipts();
    }
  }

  Future<void> _flushReceipts() async {
    if (!_receiptsDirty) return;
    final pending = File('${_receiptFile.path}.pending');
    await pending.writeAsString(jsonEncode(_delivered.toList()), flush: true);
    await pending.rename(_receiptFile.path);
    _receiptsDirty = false;
  }

  Future<Map<String, dynamic>> status() async {
    final raw = await bridge.invokeMapMethod<String, dynamic>(
      'getNotificationStatus',
    );
    return raw ?? {};
  }

  Future<void> requestNotifications() =>
      bridge.invokeMethod('requestNotifications');
  Future<void> requestExactAlarms() =>
      bridge.invokeMethod('requestExactAlarms');
  Future<void> openNotificationSettings() =>
      bridge.invokeMethod('openNotificationSettings');
  Future<void> stop() {
    if (_disposed) return Future.value();
    return _stopFuture ??= _stop();
  }

  Future<void> _stop() async {
    final wasRunning = _timer != null;
    _stopping = true;
    _timer?.cancel();
    _timer = null;
    controller.onCommitted = null;
    try {
      await _starting;
      await _checking;
      await _syncQueue;
      if (platform == ReminderPlatform.windows) await _flushReceipts();
    } catch (_) {
      // Native quit will keep the window open. Restore live reminders as well
      // as the controller's write queue so that retrying does not require a
      // process restart or lose an already delivered receipt.
      _stopping = false;
      if (!_disposed && wasRunning) {
        controller.onCommitted = (_) => synchronize();
        _timer = Timer.periodic(const Duration(seconds: 20), (_) => tick());
      }
      _report(_retryMessage);
      scheduleMicrotask(() => _stopFuture = null);
      rethrow;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stopping = true;
    _timer?.cancel();
    controller.onCommitted = null;
    super.dispose();
  }
}
