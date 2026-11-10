import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/main.dart';
import 'package:small_orbit/platform/reminder_service.dart';
import 'package:small_orbit/ui/task_editor.dart';
import 'package:small_orbit/ui/task_stage.dart';
import 'interaction_polish_test.dart' show occurrence, stage;
import 'widget_test.dart' show MemoryStore;

void main() {
  testWidgets(
    'full long title can be scrolled in the task menu and edit remains reachable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final title = '整理资料，确认所有需要跟进的问题。' * 12;
      final controller = OrbitController(MemoryStore());
      await controller.initialize();
      await controller.upsert(
        OrbitTask(id: 'full', title: title, createdAt: DateTime(2026, 11, 10)),
      );
      await controller.settings(
        controller.document.settings.copyWith(reduceMotion: true),
      );
      final reminders = ReminderService(controller);
      await tester.pumpWidget(
        OrbitApp(controller: controller, reminders: reminders),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('编辑 $title'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('编辑这件小事').hitTestable(), findsOneWidget);
      expect(find.text('删除任务').hitTestable(), findsOneWidget);
      await tester.tap(find.text('编辑这件小事'));
      await tester.pumpAndSettle();
      final field = find.descendant(
        of: find.byType(TaskEditor),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(field).controller!.text, title);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      reminders.dispose();
      controller.dispose();
    },
  );

  testWidgets(
    'long titles stay compact at normal and large text sizes, with the original available to edit',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final original = '整理项目资料\n确认评审时间，并把上次会议里没有完成的事情重新安排好。' * 5;
      final compact = original.replaceAll(RegExp(r'\s+'), ' ');
      String? edited;
      var completed = 0;
      for (final scale in [1.0, 1.8]) {
        await tester.pumpWidget(
          stage(
            items: [
              occurrence('long', title: original, importance: 1, urgency: 1),
            ],
            textScale: scale,
            edit: (task) => edited = task.title,
            complete: (_) async {
              completed++;
            },
          ),
        );
        await tester.pumpAndSettle();
        final label = find.text(compact);
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: label, matching: find.byType(RichText)),
        );
        expect(paragraph.didExceedMaxLines, isTrue);
        expect(
          paragraph.size.height,
          lessThanOrEqualTo(15 * scale * 1.25 * 2 + 1),
        );
        expect(tester.widget<Text>(label).semanticsLabel, original);
        await tester.tap(find.byTooltip('编辑 $original'));
        await tester.pump();
        expect(edited, original);
        expect(completed, 0);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'desktop hover reveals the whole title and clears it when the window loses focus',
    (tester) async {
      final item = occurrence(
        'hover-title',
        title: '准备周五的项目评审，把演示材料和待确认的问题整理到一起',
      );
      await tester.pumpWidget(stage(items: [item], reduceMotion: false));
      await tester.pump(const Duration(milliseconds: 50));
      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer();
      await pointer.moveTo(tester.getCenter(find.text(item.task.title)));
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pump(const Duration(milliseconds: 200));
      final full = find.text(
        '${item.task.title}\n${priorityCaption(item.task)}',
      );
      expect(full, findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(milliseconds: 250));
      expect(full, findsNothing);
      await pointer.removePointer();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('touch long press keeps opening the full title for editing', (
    tester,
  ) async {
    final item = occurrence(
      'touch-title',
      title: '记录一个很长的想法，明天再逐步拆开执行，今天先把内容保存下来',
    );
    String? edited;
    var completed = 0;
    await tester.pumpWidget(
      stage(
        items: [item],
        edit: (task) => edited = task.title,
        complete: (_) async {
          completed++;
        },
      ),
    );
    await tester.longPress(find.text(item.task.title));
    await tester.pumpAndSettle();
    expect(edited, item.task.title);
    expect(completed, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
