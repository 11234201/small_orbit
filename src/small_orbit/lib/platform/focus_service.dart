import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/focus_session.dart';
import '../core/orbit_controller.dart';
import '../core/task_model.dart';

class FocusService extends ChangeNotifier {
  FocusService(
    this.controller, {
    MethodChannel? bridge,
    TargetPlatform? platform,
  }) : bridge = bridge ?? const MethodChannel('small_orbit/platform'),
       platform =
           platform ??
           (Platform.isAndroid
               ? TargetPlatform.android
               : Platform.isWindows
               ? TargetPlatform.windows
               : TargetPlatform.linux);
  final OrbitController controller;
  final MethodChannel bridge;
  final TargetPlatform platform;
  FocusSession? session;
  bool sound = false, haptics = false;
  String? notice;
  Timer? _timer;
  final Stopwatch _monotonic = Stopwatch();
  DateTime? _anchor;
  int _anchorRemaining = 0, _restoreGeneration = 0;
  bool _disposed = false, _checking = false, _stopping = false;
  String? _notifiedId;
  bool _receiptDirty = false;
  int _failedOperations = 0;
  Future<void> _queue = Future.value();
  DateTime get now => controller.clock();
  int get remaining => session?.phase == FocusPhase.running && _anchor != null
      ? (_anchorRemaining - _monotonic.elapsed.inSeconds).clamp(
          0,
          session!.durationSeconds,
        )
      : session?.remaining(now) ?? 0;
  File get _file => File('${controller.store.directory.path}/focus.json');

  Future<void> start() async {
    _restoreGeneration = controller.restoreGeneration;
    controller.addListener(_documentChanged);
    try {
      if (await _file.exists()) {
        if (await _file.length() > 16384) throw const FormatException('专注文件过大');
        final raw =
            jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
        sound = raw['sound'] == true;
        haptics = raw['haptics'] == true;
        final notified = raw['notifiedId'];
        if (notified != null &&
            (notified is! String || notified.length > 240)) {
          throw const FormatException('专注提示回执无效');
        }
        _notifiedId = notified as String?;
        if (raw['session'] != null)
          session = FocusSession.fromJson(
            Map<String, dynamic>.from(raw['session'] as Map),
          );
        if (session?.phase == FocusPhase.running &&
            session!.deadline.difference(now).inSeconds >
                session!.durationSeconds + 90) {
          session = session!.change(
            FocusPhase.paused,
            now,
            remaining: session!.remainingSeconds,
          );
          notice = '系统时间发生变化，专注已暂停，请确认后继续。';
        }
        if (session?.phase == FocusPhase.running &&
            session!.remaining(now) == 0) {
          session = session!.change(FocusPhase.finished, now);
        }
        await _saveValidated(session);
        await _syncNative();
      }
    } catch (_) {
      notice = '上次专注暂时无法恢复；待办数据仍然可用。';
    }
    if (_disposed) return;
    if (session == null) await _syncNative();
    if (_disposed) return;
    _arm();
    _documentChanged();
    notifyListeners();
  }

  Future<void> _enqueue(Future<void> Function() action) {
    if (_disposed || _stopping) return Future.error(StateError('专注正在保存并退出'));
    final result = _queue.then((_) {
      if (_disposed) throw StateError('专注已关闭');
      return action();
    });
    _queue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {
        _failedOperations++;
      },
    );
    return result;
  }

  Future<void> _save(FocusSession? next, {bool? sound, bool? haptics}) async {
    final receipt = _notifiedId;
    await controller.store.directory.create(recursive: true);
    final pending = File('${_file.path}.pending');
    await pending.writeAsString(
      jsonEncode({
        'session': next?.toJson(),
        'sound': sound ?? this.sound,
        'haptics': haptics ?? this.haptics,
        'notifiedId': receipt,
      }),
      flush: true,
    );
    await pending.rename(_file.path);
    session = next;
    this.sound = sound ?? this.sound;
    this.haptics = haptics ?? this.haptics;
    if (_notifiedId == receipt) _receiptDirty = false;
  }

  Future<void> _syncNative() async {
    if (kIsWeb ||
        !(platform == TargetPlatform.android ||
            platform == TargetPlatform.windows))
      return;
    try {
      if (session != null &&
          session!.phase != FocusPhase.ended &&
          !_hasActiveTarget(session!)) {
        await _save(session!.change(FocusPhase.ended, now));
        _arm();
      }
      final value = session;
      await bridge.invokeMethod<void>(
        'syncFocus',
        value == null
            ? null
            : {
                'id': value.id,
                'deadline': value.deadline.millisecondsSinceEpoch,
                'phase': value.phase.name,
              },
      );
      // Android owns its durable notification receipt. Windows needs a local
      // receipt because the native bridge's in-memory dedup ends with the app.
      if (platform == TargetPlatform.windows &&
          value?.phase == FocusPhase.finished &&
          _notifiedId != value!.id) {
        await bridge.invokeMethod<void>('showFocusNotification', {
          'id': value.id,
        });
        _notifiedId = value.id;
        _receiptDirty = true;
      }
      await _flushReceipt();
      if (notice?.startsWith('专注已保存，后台提示') ?? false) notice = null;
    } catch (_) {
      notice = '专注已保存，后台提示暂未就绪；回到应用可查看进度。';
    }
  }

  Future<void> _flushReceipt() async {
    if (_receiptDirty) await _save(session);
  }

  bool _hasActiveTarget(FocusSession value) =>
      controller.document.active(now, todayOnly: false).any(value.matches);

  Future<void> _saveValidated(FocusSession? next) async {
    final generation = controller.restoreGeneration;
    await _save(next);
    // Task writes use a separate queue. A delete/complete/restore can finish
    // while this file is being flushed, before session becomes observable.
    // Recheck before arming the clock or publishing any native alarm.
    if (next != null &&
        next.phase != FocusPhase.ended &&
        (generation != controller.restoreGeneration ||
            !_hasActiveTarget(next))) {
      await _save(next.change(FocusPhase.ended, now));
      notice = '任务或备份已变化，这段专注已结束。';
    }
  }

  void _arm() {
    _timer?.cancel();
    _timer = null;
    _monotonic.reset();
    _anchor = null;
    if (!_disposed && !_stopping && session?.phase == FocusPhase.running) {
      _anchor = now;
      _anchorRemaining = session!.remaining(now);
      _monotonic.start();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } else {
      _monotonic.stop();
    }
  }

  Future<void> _commit(FocusSession? next) async {
    await _saveValidated(next);
    _arm();
    await _syncNative();
    if (!_disposed) notifyListeners();
  }

  void _tick() {
    if (_checking ||
        _disposed ||
        _stopping ||
        session?.phase != FocusPhase.running)
      return;
    final drift =
        now.difference(_anchor!).inSeconds - _monotonic.elapsed.inSeconds;
    if (drift.abs() > 90 || remaining == 0) {
      final observedSession = session;
      _checking = true;
      unawaited(
        _enqueue(() async {
              // A replacement, pause or resume may already be ahead of this
              // event in the persistence queue. Never apply its old clock data.
              if (!identical(session, observedSession) ||
                  session?.phase != FocusPhase.running)
                return;
              if (drift.abs() > 90) {
                notice = '系统时间发生变化，专注已暂停，请确认后继续。';
                await _commit(
                  session!.change(FocusPhase.paused, now, remaining: remaining),
                );
              } else {
                final id = session!.id;
                await _commit(session!.change(FocusPhase.finished, now));
                if (session?.id != id || session?.phase != FocusPhase.finished)
                  return;
                await feedback();
              }
            })
            .catchError((Object e) {
              notice = '专注状态暂未保存：$e';
            })
            .whenComplete(() {
              _checking = false;
            }),
      );
    } else {
      notifyListeners();
    }
  }

  void _documentChanged() {
    if (_disposed || _stopping) return;
    final changed = _restoreGeneration != controller.restoreGeneration;
    _restoreGeneration = controller.restoreGeneration;
    if (session == null || session!.phase == FocusPhase.ended) return;
    final valid = controller.document
        .active(now, todayOnly: false)
        .any(session!.matches);
    if (changed || !valid) {
      final sessionId = session!.id;
      unawaited(
        _enqueue(() async {
          if (session?.id == sessionId && session?.phase != FocusPhase.ended) {
            await _commit(
              session!.change(FocusPhase.ended, now, remaining: remaining),
            );
          }
        }).catchError((Object e) {
          notice = '专注结束状态暂未保存：$e';
        }),
      );
    }
  }

  Future<void> begin(TaskOccurrence item, int minutes) => _enqueue(() async {
    if (minutes < 1 || minutes > 180) throw ArgumentError('专注时长为 1～180 分钟');
    if (!controller.document
        .active(now, todayOnly: false)
        .any(
          (i) =>
              i.identity == item.identity &&
              i.day == item.day &&
              i.task.repeat == item.task.repeat,
        )) {
      throw StateError('这件小事已变化，请重新选择');
    }
    await _commit(
      FocusSession(
        id: newTaskId(),
        taskId: item.task.id,
        key: item.key,
        taskDay: item.day == null ? null : dayKey(item.day!),
        repeat: item.task.repeat,
        durationSeconds: minutes * 60,
        remainingSeconds: minutes * 60,
        deadline: now.add(Duration(minutes: minutes)),
        phase: FocusPhase.running,
      ),
    );
    if (platform == TargetPlatform.android) {
      try {
        await bridge.invokeMethod<void>('requestNotifications');
        final status = await bridge.invokeMapMethod<String, dynamic>(
          'getNotificationStatus',
        );
        if (status?['notifications'] != true) {
          notice = '通知未开启，专注结束后可回到应用查看。';
        }
        await _syncNative();
      } catch (_) {
        notice = '专注已经开始，通知权限可在设置中检查。';
      }
      if (!_disposed) notifyListeners();
    }
  });
  Future<void> pause() => _enqueue(() async {
    if (session?.phase == FocusPhase.running)
      await _commit(
        session!.change(FocusPhase.paused, now, remaining: remaining),
      );
  });
  Future<void> resume() => _enqueue(() async {
    if (session?.phase == FocusPhase.paused)
      await _commit(session!.change(FocusPhase.running, now));
  });
  Future<void> end() => _enqueue(() async {
    if (session != null)
      await _commit(
        session!.change(FocusPhase.ended, now, remaining: remaining),
      );
  });
  Future<void> preferences({bool? sound, bool? haptics}) => _enqueue(() async {
    await _save(session, sound: sound, haptics: haptics);
    if (!_disposed) notifyListeners();
  });
  Future<void> feedback() async {
    try {
      if (sound) await bridge.invokeMethod<void>('playFeedback');
      if (haptics && platform == TargetPlatform.android)
        await HapticFeedback.lightImpact();
    } catch (_) {
      /* Optional feedback must never roll back a completed task. */
    }
  }

  Future<void> retryNotifications() => _enqueue(_syncNative);
  Future<void> stop() async {
    // Reject new work while allowing all already accepted writes to finish.
    final failuresBeforeClose = _failedOperations;
    _stopping = true;
    _timer?.cancel();
    _timer = null;
    try {
      await _queue;
      if (_failedOperations != failuresBeforeClose) {
        throw StateError('专注状态尚未保存，请重试后退出');
      }
      await _flushReceipt();
    } catch (_) {
      resumeClock();
      rethrow;
    }
  }

  void resumeClock() {
    _stopping = false;
    _arm();
  }

  Future<void> flush() async {
    await _queue;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _monotonic.stop();
    controller.removeListener(_documentChanged);
    super.dispose();
  }
}
