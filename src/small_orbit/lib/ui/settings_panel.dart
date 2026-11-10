import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../core/local_store.dart';
import '../core/orbit_controller.dart';
import '../platform/reminder_service.dart';

class SettingsPanel extends StatefulWidget {
  const SettingsPanel({
    super.key,
    required this.controller,
    required this.reminders,
  });
  final OrbitController controller;
  final ReminderService reminders;
  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  Map<String, dynamic> _status = {};
  String? _message;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final status = await widget.reminders.status();
      if (mounted) setState(() => _status = status);
    } catch (_) {
      if (mounted) setState(() => _message = '暂时无法读取系统提醒状态');
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _message = '没有完成操作：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export({File? backup}) async {
    final bytes = backup == null
        ? utf8.encode(BackupCodec.encode(widget.controller.document))
        : await backup.readAsBytes();
    final destination = await FilePicker.platform.saveFile(
      dialogTitle: '保存小事星球备份',
      fileName: '小事星球-${DateTime.now().millisecondsSinceEpoch}.orbit',
      type: FileType.custom,
      allowedExtensions: ['orbit'],
      bytes: Uint8List.fromList(bytes),
    );
    if (destination == null) return;
    if (!Platform.isAndroid && !Platform.isIOS)
      await File(destination).writeAsBytes(bytes, flush: true);
    if (mounted) setState(() => _message = '已导出，可以复制到另一台设备恢复。');
  }

  Future<void> _import({File? backup}) async {
    File? file = backup;
    if (file == null) {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: '选择小事星球备份',
        type: FileType.any,
        withData: false,
      );
      if (result == null || result.files.single.path == null) return;
      file = File(result.files.single.path!);
    }
    final incoming = BackupCodec.decode(
      await widget.controller.store.readBounded(file),
    );
    if (!mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复这份小事？'),
        content: Text(
          '备份包含 ${incoming.tasks.length} 个任务。恢复会替换当前全部任务和设置；替换前会自动备份当前数据。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('备份并恢复'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await widget.controller.restore(incoming);
    await _refresh();
    if (mounted) setState(() => _message = widget.controller.notice);
  }

  Future<void> _backups() async {
    final backups = await widget.controller.store.backups();
    if (!mounted) return;
    if (backups.isEmpty) {
      setState(() => _message = '还没有自动备份。每次恢复前都会自动生成。');
      return;
    }
    final selected = await showDialog<File>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('恢复前的自动备份'),
        children: backups.take(30).map((file) {
          final stamp = int.tryParse(
            file.uri.pathSegments.last.replaceAll(RegExp(r'[^0-9]'), ''),
          );
          final label = stamp == null
              ? file.uri.pathSegments.last
              : DateTime.fromMicrosecondsSinceEpoch(
                  stamp,
                ).toString().substring(0, 19);
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(context, file),
            child: Text(label),
          );
        }).toList(),
      ),
    );
    if (selected == null || !mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('使用这份备份'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'restore'),
            child: const Text('恢复到这份备份'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'export'),
            child: const Text('导出这份备份'),
          ),
        ],
      ),
    );
    if (action == 'restore') await _import(backup: selected);
    if (action == 'export') await _export(backup: selected);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final settings = widget.controller.document.settings;
      return AlertDialog(
        title: const Text('让小事适合你'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('减少动态效果'),
                  subtitle: const Text('泡泡静止，完成反馈更轻'),
                  value: settings.reduceMotion,
                  onChanged: _busy
                      ? null
                      : (value) => _run(
                          () => widget.controller.settings(
                            settings.copyWith(reduceMotion: value),
                          ),
                        ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('开启任务提醒'),
                  value: settings.remindersEnabled,
                  onChanged: _busy
                      ? null
                      : (value) => _run(() async {
                          if (value)
                            await widget.reminders.requestNotifications();
                          await widget.controller.settings(
                            settings.copyWith(remindersEnabled: value),
                          );
                          await _refresh();
                        }),
                ),
                if (Platform.isAndroid) ...[
                  Text(
                    _status['notifications'] == true
                        ? '系统通知：已允许'
                        : '系统通知：未允许，提醒不会显示',
                    style: const TextStyle(fontSize: 12),
                  ),
                  Text(
                    _status['exact'] == true ? '准时提醒：已允许' : '准时提醒：未允许，系统可能延后提醒',
                    style: const TextStyle(fontSize: 12),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _run(() async {
                                await ReminderService.channel.invokeMethod(
                                  'openNotificationSettings',
                                );
                                await _refresh();
                              }),
                        child: const Text('通知权限'),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _run(widget.reminders.requestExactAlarms),
                        child: const Text('准时提醒权限'),
                      ),
                      TextButton(
                        onPressed: _busy ? null : () => _run(_refresh),
                        child: const Text('刷新状态'),
                      ),
                    ],
                  ),
                  const Text(
                    '重启后会重新安排提醒。系统强制停止应用后，需要重新打开；请在手机设置中允许后台运行。',
                    style: TextStyle(fontSize: 12, color: Color(0xff777180)),
                  ),
                ] else
                  const Text(
                    '关闭窗口后留在托盘继续提醒；选择“退出”后停止提醒。Windows 的勿扰模式可能隐藏通知。',
                    style: TextStyle(fontSize: 12, color: Color(0xff777180)),
                  ),
                const Divider(height: 32),
                const Text(
                  '带着小事换个地方',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                const Text(
                  '两台设备分别离线使用，导出文件后在另一台恢复。',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _run(_export),
                      icon: const Icon(Icons.ios_share, size: 18),
                      label: const Text('导出备份'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _run(_import),
                      icon: const Icon(Icons.restore, size: 18),
                      label: const Text('从文件恢复'),
                    ),
                    TextButton(
                      onPressed: _busy ? null : () => _run(_backups),
                      child: const Text('自动备份'),
                    ),
                  ],
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: LinearProgressIndicator(),
                  ),
                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _message!,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 18),
                const Text(
                  '小事星球 0.1.0 · 数据保存在此设备',
                  style: TextStyle(fontSize: 11, color: Color(0xff918895)),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('好了'),
          ),
        ],
      );
    },
  );
}
