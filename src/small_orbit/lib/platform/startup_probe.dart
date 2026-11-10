import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../core/local_store.dart';

/// Opt-in measurement hook for isolated Windows release tests. Normal launches
/// and Android never create diagnostics or auto-exit.
Future<void> recordStartupProbe(
  LocalStore store,
  Duration dataReady,
  Duration firstFrame,
  int taskCount,
  Future<void> Function() quit,
) async {
  if (!Platform.isWindows ||
      Platform.environment['SMALL_ORBIT_DIAGNOSTICS'] != '1' ||
      Platform.environment['SMALL_ORBIT_DATA_DIR'] == null)
    return;
  try {
    final signal = File('${store.directory.path}/readiness.json');
    final pending = File('${signal.path}.pending');
    await pending.writeAsString(
      jsonEncode({
        'readyAtUtc': DateTime.now().toUtc().toIso8601String(),
        'dataReadyMs': dataReady.inMicroseconds / 1000,
        'firstFrameMs': firstFrame.inMicroseconds / 1000,
        'tasks': taskCount,
        'marker':
            'Dart first post-frame callback; not visible-window interaction',
      }),
      flush: true,
    );
    await pending.rename(signal.path);
  } catch (_) {
    // Measurement errors must not break the application under test.
  }
  Timer(const Duration(seconds: 8), () async {
    try {
      await quit();
    } catch (_) {
      /* The runner checks for a clean exit. */
    }
  });
}
