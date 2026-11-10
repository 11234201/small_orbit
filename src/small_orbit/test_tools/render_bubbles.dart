// Manual real-Flutter preview capture, outside the automatic regression suite.
// ORBIT_MOTION_PREVIEW_DIR=... flutter test test_tools/render_bubbles.dart
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/orbit_controller.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/main.dart';
import 'package:small_orbit/platform/reminder_service.dart';
import '../test/widget_test.dart' show MemoryStore;

void main() {
  testWidgets('render six seconds of the actual bubble interface', (
    tester,
  ) async {
    final directory = Platform.environment['ORBIT_MOTION_PREVIEW_DIR']!;
    await tester.runAsync(() async {
      for (final family in ['Roboto', 'Ahem', 'MaterialIcons']) {
        final file = File(
          family == 'MaterialIcons'
              ? '/home/wzh/open_source/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'
              : '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
        );
        await (FontLoader(
          family,
        )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
      }
      await Directory(directory).create(recursive: true);
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    final controller = OrbitController(MemoryStore());
    await controller.initialize();
    const titles = ['把想法写下来', '散步 20 分钟', '给绿植浇水', '读一小节书', '整理桌面', '留点时间发呆'];
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
    await controller.settings(
      controller.document.settings.copyWith(motion: MotionMode.lively),
    );
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: OrbitApp(
          controller: controller,
          reminders: ReminderService(controller),
        ),
      ),
    );
    await tester.pump();
    for (var frame = 0; frame < 120; frame++) {
      if (frame == 96) {
        await tester.tap(find.text('给绿植浇水'));
      }
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = boundary.toImageSync();
      await tester.runAsync(() async {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$directory/frame_${frame.toString().padLeft(3, '0')}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      });
      image.dispose();
    }
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
