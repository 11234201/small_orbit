import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Coordinates explicit Windows exits with durable task writes.
///
/// Register this even on the startup error page (with an empty preparation), so
/// the tray can still exit. The preparation callback must stop new writes before
/// it waits for pending writes; if it fails, it must re-enable those operations.
class WindowService extends ChangeNotifier {
  WindowService({
    required this.onPrepareToQuit,
    MethodChannel? bridge,
    bool? enabled,
  }) : bridge = bridge ?? const MethodChannel('small_orbit/window'),
       enabled = enabled ?? Platform.isWindows;

  final Future<void> Function() onPrepareToQuit;
  final MethodChannel bridge;
  final bool enabled;
  bool isClosing = false;
  bool isVisible = true;
  String? lastError;
  bool _registered = false;
  bool _disposed = false;
  Future<bool>? _preparation;
  int _visibilityGeneration = 0;

  void register() {
    if (!enabled || _registered || _disposed) return;
    _registered = true;
    bridge.setMethodCallHandler((call) async {
      if (call.method == 'visibilityChanged' && call.arguments is bool) {
        _visibilityGeneration++;
        _setVisibility(call.arguments as bool);
        return null;
      }
      if (call.method != 'prepareToQuit') throw MissingPluginException();
      return _preparation ??= _prepare();
    });
    unawaited(_refreshVisibility());
  }

  Future<void> _refreshVisibility() async {
    final generation = _visibilityGeneration;
    try {
      final visible = await bridge.invokeMethod<bool>('isVisible');
      // A newer native event wins over an in-flight initial query.
      if (visible != null && generation == _visibilityGeneration) {
        _setVisibility(visible);
      }
    } catch (_) {
      // Startup and explicit exit must work even if querying visibility fails.
    }
  }

  void _setVisibility(bool visible) {
    if (_disposed || isVisible == visible) return;
    isVisible = visible;
    notifyListeners();
  }

  Future<bool> _prepare() async {
    isClosing = true;
    lastError = null;
    notifyListeners();
    try {
      await onPrepareToQuit();
      return true;
    } catch (_) {
      if (!_disposed) {
        isClosing = false;
        lastError = '尚未完成保存，窗口已保留。请重试后再退出。';
        notifyListeners();
      }
      // Clear the failed request after its future has been assigned by the
      // method handler, including when preparation throws synchronously.
      Future<void>.microtask(() => _preparation = null);
      return false;
    }
  }

  Future<void> requestQuit() async {
    if (enabled && !_disposed) await bridge.invokeMethod<void>('requestQuit');
  }

  @override
  void dispose() {
    _disposed = true;
    if (_registered) bridge.setMethodCallHandler(null);
    super.dispose();
  }
}
