import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/main.dart';
import 'package:small_orbit/platform/reminder_service.dart';
import 'package:small_orbit/platform/window_service.dart';
import 'package:small_orbit/ui/task_editor.dart';
import 'widget_test.dart' show MemoryStore;

class DesktopFixture {
  DesktopFixture({this.compact = false});
  static const channel = MethodChannel('small_orbit/compact_test');
  final controller = OrbitController(MemoryStore());
  late final reminders = ReminderService(controller);
  late final window = WindowService(
    enabled: true,
    bridge: channel,
    onPrepareToQuit: () async {},
  );
  bool compact, top = false, fail = false;
  int drags = 0;
  Future<void> initialize({int tasks = 1}) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'isVisible') return true;
          if (call.method == 'setCompact') {
            if (fail) throw PlatformException(code: 'disk');
            compact = call.arguments as bool;
          }
          if (call.method == 'setAlwaysOnTop') top = call.arguments as bool;
          if (call.method == 'startDragging') {
            drags++;
            return null;
          }
          return {'compact': compact, 'alwaysOnTop': top};
        });
    await controller.initialize();
    await controller.settings(
      controller.document.settings.copyWith(reduceMotion: true),
    );
    for (var i = 0; i < tasks; i++) {
      await controller.upsert(
        OrbitTask(
          id: 'compact$i',
          title: '待办事项$i',
          createdAt: DateTime(2026, 11, 10),
        ),
      );
    }
    window.register();
    await window.refreshOptions();
  }

  Widget get app =>
      OrbitApp(controller: controller, reminders: reminders, window: window);
  void dispose() {
    window.dispose();
    reminders.dispose();
    controller.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

Future<void> selectMenu(WidgetTester tester, String text) async {
  await tester.tap(find.byTooltip('窗口选项'));
  await tester.pumpAndSettle();
  await tester.tap(
    find
        .ancestor(
          of: find.text(text),
          matching: find.byWidgetPredicate(
            (widget) => widget is PopupMenuItem<String>,
          ),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'compact hides controls and Esc restores the unsaved input draft',
    (tester) async {
      final fixture = DesktopFixture();
      await fixture.initialize();
      await tester.pumpWidget(fixture.app);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '尚未提交的草稿');
      await selectMenu(tester, '仅显示待办');
      expect(find.text('小事星球'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('设置与备份'), findsNothing);
      expect(find.text('看看全部 1 件小事'), findsNothing);
      expect(find.text('待办事项0'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('小事星球'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        '尚未提交的草稿',
      );
      await tester.pumpWidget(const SizedBox());
      fixture.dispose();
    },
  );

  testWidgets(
    'pin is independent, compact completion supports undo and adding',
    (tester) async {
      final fixture = DesktopFixture(compact: true);
      await fixture.initialize();
      await tester.pumpWidget(fixture.app);
      await tester.pumpAndSettle();
      await selectMenu(tester, '窗口置顶');
      expect(fixture.window.alwaysOnTop, isTrue);
      expect(fixture.window.compact, isTrue);
      await tester.tap(find.text('待办事项0'));
      await tester.pumpAndSettle();
      expect(fixture.controller.document.active(DateTime.now()), isEmpty);
      await selectMenu(tester, '撤销上一步');
      expect(find.text('待办事项0'), findsOneWidget);
      await selectMenu(tester, '添加小事');
      expect(find.byType(TaskEditor), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      fixture.dispose();
    },
  );

  testWidgets(
    'compact groups remain reachable and drag handle requests native movement',
    (tester) async {
      tester.view.physicalSize = const Size(300, 320);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final fixture = DesktopFixture(compact: true);
      await fixture.initialize(tasks: 9);
      await tester.pumpWidget(fixture.app);
      await tester.pumpAndSettle();
      expect(find.text('1 / 3 · 共 9 件'), findsOneWidget);
      await tester.tap(find.byTooltip('下一组'));
      await tester.pumpAndSettle();
      expect(find.text('2 / 3 · 共 9 件'), findsOneWidget);
      await tester.drag(find.byTooltip('拖动窗口'), const Offset(30, 10));
      await tester.pumpAndSettle();
      expect(fixture.drags, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      fixture.dispose();
    },
  );

  testWidgets('compact native failure keeps the full view usable', (
    tester,
  ) async {
    final fixture = DesktopFixture();
    await fixture.initialize();
    fixture.fail = true;
    await tester.pumpWidget(fixture.app);
    await tester.pumpAndSettle();
    await selectMenu(tester, '仅显示待办');
    expect(find.text('小事星球'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(fixture.window.compact, isFalse);
    fixture.fail = false;
    await selectMenu(tester, '仅显示待办');
    expect(fixture.window.compact, isTrue);
    await tester.pumpWidget(const SizedBox());
    fixture.dispose();
  });

  testWidgets('all compact modes fit the small window and large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(260, 300);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final fixture = DesktopFixture(compact: true);
    await fixture.initialize(tasks: 7);
    await tester.pumpWidget(fixture.app);
    await tester.pumpAndSettle();
    for (final mode in DisplayMode.values) {
      await fixture.controller.settings(
        fixture.controller.document.settings.copyWith(display: mode),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: mode.name);
    }
    await tester.pumpWidget(const SizedBox());
    fixture.dispose();
  });
}
