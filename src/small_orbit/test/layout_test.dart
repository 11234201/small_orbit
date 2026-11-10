import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/main.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/platform/reminder_service.dart';
import 'widget_test.dart' show MemoryStore;

void main() {
  testWidgets(
    'all three modes fit phone and desktop; keyboard and editor remain usable',
    (tester) async {
      final previewDirectory = Platform.environment['ORBIT_PREVIEW_DIR'];
      if (previewDirectory != null) {
        await tester.runAsync(() async {
          final font = File(
            '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
          );
          if (await font.exists()) {
            for (final family in ['Roboto', 'Ahem']) {
              final loader = FontLoader(family)
                ..addFont(
                  font.readAsBytes().then(
                    (bytes) => ByteData.sublistView(bytes),
                  ),
                );
              await loader.load();
            }
            final icons = File(
              '/home/wzh/open_source/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            );
            final iconLoader = FontLoader('MaterialIcons')
              ..addFont(
                icons.readAsBytes().then(
                  (bytes) => ByteData.sublistView(bytes),
                ),
              );
            await iconLoader.load();
          }
          await Directory(previewDirectory).create(recursive: true);
        });
      }
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.view.resetViewInsets();
      });
      final controller = OrbitController(MemoryStore());
      await controller.initialize();
      final titles = Platform.environment['ORBIT_LONG_TITLES'] == '1'
          ? [
              '整理下周的工作安排，把最重要的三件事先写下来',
              '下班后去公园散步二十分钟，顺路买点水果',
              '给阳台上的绿植浇水，看看新叶子长出来没有',
              '读完正在看的这一章，再记下一句喜欢的话',
              '把项目评审需要的资料整理好，确认遗漏的问题',
              '给自己留点发呆的时间，不需要安排得太满',
            ]
          : ['把今天的想法写下来', '散步 20 分钟', '给绿植浇水', '读一小节书', '整理桌面', '留点时间发呆'];
      for (var i = 0; i < titles.length; i++) {
        await controller.upsert(
          OrbitTask(
            id: 'preview$i',
            title: titles[i],
            createdAt: DateTime(2026, 11, 10),
            importance: i % 3 + 1,
            urgency: i % 3 + 1,
          ),
        );
      }
      for (final size in [
        const Size(480, 760),
        const Size(390, 844),
        const Size(320, 640),
      ]) {
        tester.view.physicalSize = size;
        for (final mode in DisplayMode.values) {
          await controller.settings(
            controller.document.settings.copyWith(display: mode, paused: true),
          );
          final boundaryKey = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundaryKey,
              child: OrbitApp(
                controller: controller,
                reminders: ReminderService(controller),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
          expect(tester.takeException(), isNull, reason: '$size $mode');
          if (previewDirectory != null) {
            final boundary =
                boundaryKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = boundary.toImageSync();
            await tester.runAsync(() async {
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '$previewDirectory/${mode.name}-${size.width.toInt()}.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
            });
            image.dispose();
          }
        }
      }
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pump();
      await tester.tap(find.byTooltip('日期、提醒和重要程度'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('放进一件小事'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
