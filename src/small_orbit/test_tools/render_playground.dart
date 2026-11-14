// ORBIT_PLAY_PREVIEW_DIR=... flutter test test_tools/render_playground.dart
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../test/playground_ui_test.dart' show PlayFixture;

void main() {
  testWidgets('render five real playground pages', (tester) async {
    final output = Platform.environment['ORBIT_PLAY_PREVIEW_DIR']!;
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
      final emoji = File('/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf');
      if (await emoji.exists())
        await (FontLoader(
          'NotoColorEmoji',
        )..addFont(emoji.readAsBytes().then(ByteData.sublistView))).load();
      await Directory(output).create(recursive: true);
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(440, 820);
    final fixture = PlayFixture();
    await fixture.initialize();
    const names = ['materials', 'constellation', 'focus', 'draw', 'island'];
    for (var page = 0; page < 5; page++) {
      await tester.pumpWidget(const SizedBox());
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(key: key, child: fixture.app(page)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final image =
          (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
              .toImageSync();
      await tester.runAsync(() async {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$output/${names[page]}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      });
      image.dispose();
    }
    await tester.pumpWidget(const SizedBox());
    fixture.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
