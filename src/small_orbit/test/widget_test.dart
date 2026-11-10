import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/main.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/local_store.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/platform/reminder_service.dart';

class MemoryStore extends LocalStore {
  MemoryStore() : super(Directory.systemTemp);
  OrbitDocument value = OrbitDocument();
  @override
  Future<OrbitDocument> load() async => value;
  @override
  Future<void> save(OrbitDocument document) async {
    value = BackupCodec.decode(BackupCodec.encode(document));
  }
}

void main() {
  testWidgets(
    'card deck changes focus without completion, and swipe supports undo',
    (tester) async {
      final controller = OrbitController(MemoryStore());
      await controller.initialize();
      await controller.upsert(
        OrbitTask(id: 'first', title: '第一件', createdAt: DateTime(2026, 1, 1)),
      );
      await controller.upsert(
        OrbitTask(id: 'second', title: '第二件', createdAt: DateTime(2026, 1, 2)),
      );
      await controller.settings(
        controller.document.settings.copyWith(display: DisplayMode.cards),
      );
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        OrbitApp(
          controller: controller,
          reminders: ReminderService(controller),
        ),
      );
      expect(find.text('第一件'), findsOneWidget);
      await tester.tap(find.text('换一件'));
      await tester.pump();
      expect(find.text('第二件'), findsOneWidget);
      expect(controller.document.active(DateTime.now()), hasLength(2));
      await tester.tap(find.text('看看其他小事'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, '第一件'));
      await tester.pumpAndSettle();
      expect(find.text('第一件'), findsOneWidget);
      await tester.drag(find.byType(Dismissible), const Offset(400, 0));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(controller.document.active(DateTime.now()), hasLength(1));
      await tester.tap(find.text('撤销'));
      await tester.pump();
      expect(controller.document.active(DateTime.now()), hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets(
    'quick add, finish, switch mode, undo and restart share the same data',
    (tester) async {
      final controller = OrbitController(MemoryStore());
      await controller.initialize();
      tester.view.physicalSize = const Size(480, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        OrbitApp(
          controller: controller,
          reminders: ReminderService(controller),
        ),
      );
      await tester.enterText(find.byType(TextField).first, '买牛奶');
      await tester.tap(find.byTooltip('添加小事'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();
      expect(find.text('买牛奶'), findsOneWidget);
      await tester.tap(find.text('买牛奶'));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();
      expect(controller.document.active(DateTime.now()), isEmpty);
      await tester.runAsync(
        () => controller.settings(
          controller.document.settings.copyWith(display: DisplayMode.cards),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('撤销'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();
      expect(find.text('买牛奶'), findsOneWidget);
      final saved = await tester.runAsync(() => controller.store.load());
      expect(saved!.settings.display, DisplayMode.cards);
      expect(saved.active(DateTime.now()), hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
