// ORBIT_WINDOW_PREVIEW_DIR=... flutter test test_tools/render_window_modes.dart
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/task_model.dart';
import '../test/compact_view_test.dart' show DesktopFixture;

void main() {
  testWidgets('render full, compact and pinned menu layouts', (tester) async {
    final directory = Platform.environment['ORBIT_WINDOW_PREVIEW_DIR']!;
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
    tester.view.physicalSize = const Size(440, 700);
    final fixture = DesktopFixture();
    await fixture.initialize(tasks: 0);
    const titles = ['把想法写下来', '散步20分钟', '给绿植浇水', '读一小节书', '整理桌面', '留点时间发呆'];
    for (var i = 0; i < titles.length; i++) {
      await fixture.controller.upsert(
        OrbitTask(
          id: 'preview$i',
          title: titles[i],
          createdAt: DateTime(2026, 11, 10),
          importance: i % 3 + 1,
          urgency: i % 3 + 1,
        ),
      );
    }
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: key, child: fixture.app));
    await tester.pumpAndSettle();
    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = boundary.toImageSync();
      await tester.runAsync(() async {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$directory/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      });
      image.dispose();
    }

    await capture('full');
    await fixture.window.setCompact(true);
    await fixture.window.setAlwaysOnTop(true);
    tester.view.physicalSize = const Size(320, 460);
    await tester.pumpAndSettle();
    await capture('compact');
    await tester.tap(find.byTooltip('窗口选项'));
    await tester.pumpAndSettle();
    await capture('compact_menu');
    await tester.tap(
      find
          .ancestor(
            of: find.text('窗口透明度 · 100%'),
            matching: find.byWidgetPredicate(
              (widget) => widget is PopupMenuItem<String>,
            ),
          )
          .first,
    );
    await tester.pumpAndSettle();
    tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(70);
    await tester.pumpAndSettle();
    await capture('opacity_panel');
    await tester.pumpWidget(const SizedBox());
    fixture.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
