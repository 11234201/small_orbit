import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/local_store.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/platform/reminder_service.dart';
import 'package:small_orbit/ui/settings_panel.dart';
import 'package:small_orbit/ui/task_editor.dart';
import 'package:small_orbit/ui/task_stage.dart';
import 'widget_test.dart' show MemoryStore;

class _GatedRestoreStore extends MemoryStore {
  _GatedRestoreStore(this.incoming);
  final OrbitDocument incoming;
  final gate = Completer<void>();
  var restores = 0;
  final backupFile = File('/virtual/before-restore-1762761600000000.orbit');

  @override
  Future<List<File>> backups() async => [backupFile];

  @override
  Future<String> readBounded(File file) async => BackupCodec.encode(incoming);

  @override
  Future<File> restore(OrbitDocument incoming, OrbitDocument existing) async {
    restores++;
    await gate.future;
    await save(incoming);
    return backupFile;
  }
}

class _QuietReminders extends ReminderService {
  _QuietReminders(super.controller);
  @override
  Future<Map<String, dynamic>> status() async => {};
}

void main() {
  testWidgets(
    'selected card survives regrouping while explicit page navigation still works',
    (tester) async {
      final now = DateTime(2026, 11, 10);
      final items = List.generate(
        12,
        (index) => OrbitTask(
          id: 'task-$index',
          title: '任务 $index',
          createdAt: now,
        ).activeAt(now)!,
      );
      var height = 520.0;
      late StateSetter updateHost;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                updateHost = setState;
                return SizedBox(
                  width: 480,
                  height: height,
                  child: TaskStage(
                    items: items,
                    settings: const AppSettings(display: DisplayMode.cards),
                    replay: 0,
                    onComplete: (_) async {},
                    onEdit: (_) {},
                    onDelete: (_) {},
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('下一组'));
      await tester.pump();
      expect(find.text('任务 6'), findsOneWidget);
      await tester.tap(find.text('换一件'));
      await tester.pump();
      expect(find.text('任务 7'), findsOneWidget);
      updateHost(() => height = 290);
      await tester.pump();
      expect(find.text('任务 7'), findsOneWidget);
      updateHost(() => height = 520);
      await tester.pump();
      expect(find.text('任务 7'), findsOneWidget);
      await tester.tap(find.byTooltip('上一组'));
      await tester.pump();
      expect(find.text('任务 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'card selection stays on the chosen task when its predecessor finishes',
    (tester) async {
      final now = DateTime(2026, 11, 10);
      var items = ['A', 'B', 'C']
          .map(
            (id) => OrbitTask(id: id, title: id, createdAt: now).activeAt(now)!,
          )
          .toList();
      final saving = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => TaskStage(
                items: items,
                settings: const AppSettings(display: DisplayMode.cards),
                replay: 0,
                onEdit: (_) {},
                onDelete: (_) {},
                onComplete: (item) async {
                  await saving.future;
                  setState(
                    () => items = items
                        .where((other) => other.identity != item.identity)
                        .toList(),
                  );
                },
              ),
            ),
          ),
        ),
      );
      expect(find.text('A'), findsOneWidget);
      await tester.tap(find.text('完成，划走'));
      await tester.pump();
      await tester.tap(find.text('换一件'));
      await tester.pump();
      expect(find.text('B'), findsOneWidget);
      saving.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.text('B'), findsOneWidget);
      expect(find.text('C'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'pending restore keeps the settings modal above the old task state',
    (tester) async {
      final old = OrbitTask(
        id: 'same-id',
        title: '恢复前的任务',
        createdAt: DateTime(2026, 11, 10),
      );
      final incoming = OrbitDocument(tasks: [old.copyWith(title: '备份中的任务')]);
      final store = _GatedRestoreStore(incoming)
        ..value = OrbitDocument(tasks: [old]);
      final controller = OrbitController(store);
      await controller.initialize();
      final reminders = _QuietReminders(controller);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => SettingsPanel(
                    controller: controller,
                    reminders: reminders,
                  ),
                ),
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开设置'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('自动备份'));
      await tester.tap(find.text('自动备份'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byType(SimpleDialogOption).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('恢复到这份备份'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('备份并恢复'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(store.restores, 1);
      expect(controller.document.tasks.single.title, old.title);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '好了'))
            .onPressed,
        isNull,
      );
      await tester.tapAt(const Offset(2, 2));
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(SettingsPanel), findsOneWidget);
      store.gate.complete();
      await tester.pumpAndSettle();
      expect(controller.document.tasks.single.title, '备份中的任务');
      await tester.tap(find.text('好了'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPanel), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      reminders.dispose();
      controller.dispose();
    },
  );

  testWidgets('weekly editor fits a narrow screen with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: Scaffold(
          body: TaskEditor(
            task: OrbitTask(
              id: 'weekly',
              title: '每周整理',
              createdAt: DateTime(2026, 11, 10),
              date: DateTime(2026, 11, 10),
              repeat: RepeatKind.weekly,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    final repeatField = find.byType(DropdownButtonFormField<RepeatKind>);
    await tester.ensureVisible(repeatField);
    await tester.tap(repeatField);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('每天').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
