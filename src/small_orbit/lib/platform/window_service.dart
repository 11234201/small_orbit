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
  int _optionsGeneration = 0;
  int _pendingOptions = 0;
  Future<void> _optionWrites = Future.value();
  bool compact = false;
  bool alwaysOnTop = false;
  bool optionsLoaded = false;
  bool get updatingOptions => _pendingOptions > 0;

  void register() {
    if (!enabled || _registered || _disposed) return;
    _registered = true;
    bridge.setMethodCallHandler((call) async {
      if (call.method == 'visibilityChanged' && call.arguments is bool) {
        _visibilityGeneration++;
        _setVisibility(call.arguments as bool);
        return null;
      }
      if (call.method == 'optionsChanged') {
        _optionsGeneration++;
        _setOptions(call.arguments);
        return null;
      }
      if (call.method != 'prepareToQuit') throw MissingPluginException();
      return _preparation ??= _prepare();
    });
    unawaited(_refreshVisibility());
    unawaited(refreshOptions());
  }

  Future<void> refreshOptions() async {
    if (!enabled || _disposed) return;
    final generation = _optionsGeneration;
    try {
      final options = await bridge.invokeMethod<Object?>('getOptions');
      if (generation == _optionsGeneration) _setOptions(options);
    } catch (_) {
      // A menu open retries loading; quit and visibility remain independent.
    }
  }

  void _setOptions(Object? options) {
    if (_disposed) return;
    if (options is! Map ||
        options['compact'] is! bool ||
        options['alwaysOnTop'] is! bool) {
      throw const FormatException('Invalid window options');
    }
    final nextCompact = options['compact'] as bool;
    final nextTop = options['alwaysOnTop'] as bool;
    final changed =
        !optionsLoaded || nextCompact != compact || nextTop != alwaysOnTop;
    compact = nextCompact;
    alwaysOnTop = nextTop;
    optionsLoaded = true;
    if (changed) notifyListeners();
  }

  Future<void> setCompact(bool value) => _writeOption('setCompact', value);
  Future<void> setAlwaysOnTop(bool value) =>
      _writeOption('setAlwaysOnTop', value);

  Future<void> _writeOption(String method, bool value) {
    if (!enabled || _disposed || isClosing) return Future.value();
    _pendingOptions++;
    // Invalidate an initial read as soon as a mutation is requested.
    _optionsGeneration++;
    notifyListeners();
    final operation = _optionWrites.then((_) async {
      if (_disposed) return;
      final generation = ++_optionsGeneration;
      final options = await bridge.invokeMethod<Object?>(method, value);
      if (generation == _optionsGeneration) _setOptions(options);
    });
    final settled = operation.whenComplete(() {
      _pendingOptions--;
      if (!_disposed) notifyListeners();
    });
    _optionWrites = settled.catchError((Object _) {});
    return settled;
  }

  Future<void> startDragging() async {
    if (enabled && !_disposed && !isClosing)
      await bridge.invokeMethod<void>('startDragging');
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
      await _optionWrites;
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
