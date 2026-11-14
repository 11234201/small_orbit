import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/focus_session.dart';
import 'package:small_orbit/core/local_store.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/platform/focus_service.dart';

class GatedFocusFile implements File {
  GatedFocusFile(this.delegate, this.entered, this.gate);
  final File delegate;
  final Completer<void> entered, gate;
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    if (!entered.isCompleted) entered.complete();
    await gate.future;
    return delegate.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
  }

  @override
  Future<File> rename(String newPath) => delegate.rename(newPath);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 11, 14, 12);
  for (final mutation in ['delete', 'restore']) {
    test(
      'focus begin rechecks $mutation while its file write is pending',
      () async {
        final dir = await Directory.systemTemp.createTemp('focus_target_race_');
        final controller = OrbitController(LocalStore(dir), clock: () => now);
        final focus = FocusService(controller);
        final entered = Completer<void>(), gate = Completer<void>();
        final parent = Zone.current;
        try {
          await controller.initialize();
          await controller.upsert(
            OrbitTask(id: 'target', title: 'read', createdAt: now),
          );
          await focus.start();
          final item = controller.document.active(now).single;
          await IOOverrides.runZoned(
            () async {
              final starting = focus.begin(item, 5);
              await entered.future;
              if (mutation == 'delete') {
                await controller.delete(item.task.id);
              } else {
                // Even a backup containing the same task must end local focus.
                await controller.restore(controller.document);
              }
              gate.complete();
              await starting;
              await focus.flush();
              expect(focus.session!.phase, FocusPhase.ended);
              final saved = jsonDecode(
                await File('${dir.path}/focus.json').readAsString(),
              );
              expect(saved['session']['phase'], 'ended');
            },
            createFile: (path) {
              final file = parent.run(() => File(path));
              return path == '${dir.path}/focus.json.pending'
                  ? GatedFocusFile(file, entered, gate)
                  : file;
            },
          );
        } finally {
          if (!gate.isCompleted) gate.complete();
          focus.dispose();
          controller.dispose();
          await dir.delete(recursive: true);
        }
      },
    );
  }

  test(
    'startup invalidates an expired focus target before publishing finished',
    () async {
      final dir = await Directory.systemTemp.createTemp('focus_stale_start_');
      final controller = OrbitController(LocalStore(dir), clock: () => now);
      final focus = FocusService(controller);
      try {
        await controller.initialize();
        final previous = FocusSession(
          id: 'old',
          taskId: 'deleted',
          key: 'once',
          taskDay: null,
          repeat: RepeatKind.none,
          durationSeconds: 60,
          remainingSeconds: 60,
          deadline: now.subtract(const Duration(minutes: 1)),
          phase: FocusPhase.running,
        );
        await File(
          '${dir.path}/focus.json',
        ).writeAsString(jsonEncode({'session': previous.toJson()}));
        await focus.start();
        await focus.flush();
        expect(focus.session!.phase, FocusPhase.ended);
      } finally {
        focus.dispose();
        controller.dispose();
        await dir.delete(recursive: true);
      }
    },
  );
}
