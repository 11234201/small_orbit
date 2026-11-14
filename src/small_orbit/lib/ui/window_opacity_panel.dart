import 'dart:async';

import 'package:flutter/material.dart';

import '../platform/window_service.dart';

class WindowOpacityPanel extends StatefulWidget {
  const WindowOpacityPanel({super.key, required this.window});
  final WindowService window;
  @override
  State<WindowOpacityPanel> createState() => _WindowOpacityPanelState();
}

class _WindowOpacityPanelState extends State<WindowOpacityPanel> {
  late int _value;
  bool _saving = false, _dragging = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _value = widget.window.opacity;
    widget.window.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      if (!_saving && !_dragging) _value = widget.window.opacity;
    });
  }

  @override
  void dispose() {
    widget.window.removeListener(_changed);
    super.dispose();
  }

  Future<void> _apply(int value) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.window.setOpacity(value);
    } catch (_) {
      if (mounted) _error = '透明度未能保存，已保留原设置。请重试。';
    } finally {
      if (mounted)
        setState(() {
          _saving = false;
          _value = widget.window.opacity;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy =
        _saving || widget.window.updatingOptions || widget.window.isClosing;
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: const Text('窗口透明度'),
        content: SizedBox(
          width: 300,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('背景不透明度：$_value%'),
                Slider(
                  value: _value.toDouble(),
                  min: 30,
                  max: 100,
                  divisions: 14,
                  label: '$_value%',
                  semanticFormatterCallback: (value) =>
                      '背景不透明度 ${value.round()}%',
                  onChangeStart: busy ? null : (_) => _dragging = true,
                  onChanged: busy
                      ? null
                      : (value) => setState(() => _value = value.round()),
                  onChangeEnd: busy
                      ? null
                      : (value) {
                          _dragging = false;
                          unawaited(_apply(value.round()));
                        },
                ),
                const Text(
                  '只调节窗口背景，泡泡、纸片和文字保持不透明。30% 更通透，100% 背景完全不透明；松开滑块后自动保存。',
                ),
                if (_saving)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: LinearProgressIndicator(),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => unawaited(_apply(100)),
            child: const Text('恢复不透明'),
          ),
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }
}
