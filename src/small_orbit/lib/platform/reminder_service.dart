import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import '../core/task_model.dart';
import '../core/orbit_controller.dart';

class ReminderService {
  ReminderService(this.controller);
  final OrbitController controller;
  static const channel = MethodChannel('small_orbit/platform');
  Timer? _timer;
  final Set<String> _delivered = {};
  bool _checking = false;
  File get _receiptFile =>
      File('${controller.store.directory.path}/reminders.json');
  Future<void> start() async {
    if (Platform.isWindows && await _receiptFile.exists()) {
      try {
        _delivered.addAll(
          (jsonDecode(await _receiptFile.readAsString()) as List)
              .cast<String>(),
        );
      } catch (_) {
        /* A corrupt receipt file must not stop the task database. */
      }
    }
    controller.onCommitted = synchronize;
    await synchronize(controller.document);
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => tick());
  }

  Future<void> tick() async {
    if (_checking) return;
    _checking = true;
    try {
      await controller.rollover();
      if (Platform.isWindows) await _checkWindows();
    } catch (_) {
      /* UI operations expose write failures; next timer retries. */
    } finally {
      _checking = false;
    }
  }

  Future<void> synchronize(OrbitDocument document) async {
    if (Platform.isAndroid) {
      await channel.invokeMethod(
        'syncReminders',
        jsonEncode({
          'enabled': document.settings.remindersEnabled,
          'tasks': document.tasks
              .where((task) => task.reminderMinute != null)
              .map((task) => task.toJson())
              .toList(),
        }),
      );
    }
  }

  Future<void> _checkWindows() async {
    if (!controller.document.settings.remindersEnabled) return;
    final now = controller.clock();
    for (final task in controller.document.tasks) {
      final occurrence = task.activeAt(now);
      final at = occurrence?.reminderAt;
      if (occurrence == null || at == null || at.isAfter(now)) continue;
      // Past days remain visible in the app, without a burst of stale alerts.
      if (dayKey(at) != dayKey(now)) continue;
      final receipt = '${occurrence.identity}:${at.millisecondsSinceEpoch}';
      if (_delivered.contains(receipt)) continue;
      await channel.invokeMethod('showNotification', {
        'title': '小事星球 · 该做这件小事啦',
        'body': task.title,
      });
      _delivered.add(receipt);
      if (_delivered.length > 20000) _delivered.remove(_delivered.first);
      await _receiptFile.writeAsString(
        jsonEncode(_delivered.toList()),
        flush: true,
      );
    }
  }

  Future<Map<String, dynamic>> status() async {
    final raw = await channel.invokeMapMethod<String, dynamic>(
      'getNotificationStatus',
    );
    return raw ?? {};
  }

  Future<void> requestNotifications() =>
      channel.invokeMethod('requestNotifications');
  Future<void> requestExactAlarms() =>
      channel.invokeMethod('requestExactAlarms');
  void dispose() {
    _timer?.cancel();
  }
}
