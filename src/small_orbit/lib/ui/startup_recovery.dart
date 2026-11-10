import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../core/local_store.dart';

class StartupRecovery extends StatefulWidget {
  const StartupRecovery({
    super.key,
    required this.error,
    required this.store,
    required this.onRetry,
  });
  final Object error;
  final LocalStore? store;
  final Future<void> Function() onRetry;
  @override
  State<StartupRecovery> createState() => _StartupRecoveryState();
}

class _StartupRecoveryState extends State<StartupRecovery> {
  bool _busy = false;
  String? _message;

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

  Future<void> _recover() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: '选择小事星球备份',
      type: FileType.any,
    );
    if (picked == null || picked.files.single.path == null) return;
    final incoming = BackupCodec.decode(
      await widget.store!.readBounded(File(picked.files.single.path!)),
    );
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保留原文件并恢复？'),
        content: Text(
          '备份中有 ${incoming.tasks.length} 个任务。先原样保留当前文件，再用这份备份恢复任务和设置。原文件保留失败时不会替换。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保留并恢复'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    await widget.store!.recover(incoming);
    await widget.onRetry();
  }

  @override
  Widget build(BuildContext context) {
    final newer = widget.error is UnsupportedBackupVersion;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.folder_copy_outlined,
                    size: 44,
                    color: Color(0xff8b72ab),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    newer ? '请用较新版本打开' : '暂时没能打开小事',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    newer
                        ? '当前文件来自较新版本。请更新应用后重试，原文件会保留。'
                        : '请检查存储空间和文件权限后重试。如果已有导出的 .orbit 备份，也可以保留原文件后恢复。',
                  ),
                  const SizedBox(height: 16),
                  SelectableText(
                    '原因：${widget.error}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (widget.store != null) ...[
                    const SizedBox(height: 8),
                    SelectableText(
                      '本地目录：${widget.store!.directory.path}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton(
                        onPressed: _busy ? null : () => _run(widget.onRetry),
                        child: const Text('重试打开'),
                      ),
                      if (!newer && widget.store != null)
                        OutlinedButton(
                          onPressed: _busy ? null : () => _run(_recover),
                          child: const Text('从备份恢复'),
                        ),
                    ],
                  ),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: LinearProgressIndicator(),
                    ),
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(_message!),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
