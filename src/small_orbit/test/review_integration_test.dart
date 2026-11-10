import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/main.dart';
import 'package:small_orbit/platform/reminder_service.dart';
import 'package:small_orbit/ui/task_editor.dart';
import 'widget_test.dart' show MemoryStore;

class GatedReviewStore extends MemoryStore {
  Completer<void>? gate;
  bool failNext = false;

  @override
  Future<void> save(OrbitDocument document) async {
    await gate?.future;
    if (failNext) {
      failNext = false;
      throw const FileSystemException('disk temporarily unavailable');
    }
    await super.save(document);
  }
}

void main() {
  testWidgets('quick add cannot open a second editor for its pending draft', (
    tester,
  ) async {
    final store = GatedReviewStore();
    final controller = OrbitController(store);
    await controller.initialize();
    final reminders = ReminderService(controller);
    await tester.pumpWidget(
      OrbitApp(controller: controller, reminders: reminders),
    );
    store.gate = Completer<void>();
    await tester.enterText(find.byType(TextField).first, '买牛奶');
    await tester.tap(find.byTooltip('添加小事'));
    await tester.pump();
    final editorButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.tune).last,
    );
    expect(editorButton.onPressed, isNull);
    expect(find.byType(TaskEditor), findsNothing);
    await tester.enterText(find.byType(TextField).first, '另一个新草稿');
    store.gate!.complete();
    await tester.pump();
    await tester.pump();
    expect(controller.document.tasks.single.title, '买牛奶');
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '另一个新草稿',
    );
    await tester.pumpWidget(const SizedBox());
    reminders.dispose();
    controller.dispose();
  });

  testWidgets(
    'home editor keeps failed writes open and saves one task on retry',
    (tester) async {
      final store = GatedReviewStore();
      final controller = OrbitController(store);
      await controller.initialize();
      final reminders = ReminderService(controller);
      await tester.pumpWidget(
        OrbitApp(controller: controller, reminders: reminders),
      );
      await tester.enterText(find.byType(TextField).first, '散步');
      await tester.tap(find.byTooltip('日期、提醒和重要程度'));
      await tester.pumpAndSettle();
      final editorField = find.descendant(
        of: find.byType(TaskEditor),
        matching: find.byType(TextField),
      );
      await tester.enterText(editorField, '散步半小时');
      store.failNext = true;
      await tester.tap(find.text('放进去'));
      await tester.pumpAndSettle();
      expect(find.byType(TaskEditor), findsOneWidget);
      expect(tester.widget<TextField>(editorField).controller!.text, '散步半小时');
      expect(controller.document.tasks, isEmpty);
      await tester.tap(find.text('放进去'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(TaskEditor), findsNothing);
      expect(controller.document.tasks.single.title, '散步半小时');
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      reminders.dispose();
      controller.dispose();
    },
  );
}
