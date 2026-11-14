import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/ui/bubble_surface.dart';

import 'compact_view_test.dart';

void main() {
  for (final mode in [DisplayMode.bubbles, DisplayMode.papers]) {
    testWidgets(
      '$mode pixels keep opaque tasks above a translucent background',
      (tester) async {
        final fixture = DesktopFixture(compact: true);
        await fixture.initialize();
        await fixture.controller.settings(
          fixture.controller.document.settings.copyWith(display: mode),
        );
        await fixture.window.setOpacity(30);
        final key = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(key: key, child: fixture.app));
        await tester.pumpAndSettle();
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final snapshot = boundary.toImageSync();
        final bytes = await tester.runAsync(() => snapshot.toByteData());
        int alpha(Offset point) => bytes!.getUint8(
          (point.dy.floor() * snapshot.width + point.dx.floor()) * 4 + 3,
        );
        expect(alpha(const Offset(1, 100)), closeTo(77, 1));
        final Offset foreground;
        if (mode == DisplayMode.bubbles) {
          final paint = find.byWidgetPredicate(
            (widget) =>
                widget is CustomPaint && widget.painter is BubbleSurface,
          );
          final rect = tester.getRect(paint);
          foreground = Offset(rect.left + rect.width * .9, rect.center.dy);
        } else {
          foreground = tester.getCenter(find.text('待办事项0'));
        }
        expect(alpha(foreground), 255);
        snapshot.dispose();
        await tester.pumpWidget(const SizedBox());
        fixture.dispose();
      },
    );
  }
  testWidgets('full and compact menus adjust background opacity and reset', (
    tester,
  ) async {
    for (final compact in [false, true]) {
      final fixture = DesktopFixture(compact: compact);
      await fixture.initialize();
      await tester.pumpWidget(fixture.app);
      await tester.pumpAndSettle();
      await selectMenu(tester, '窗口透明度 · 100%');
      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChangeStart!(60);
      slider.onChanged!(60);
      await tester.pump();
      expect(
        fixture.window.opacity,
        100,
        reason: 'Dragging alone does not queue disk writes',
      );
      tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(60);
      await tester.pumpAndSettle();
      expect(fixture.window.opacity, 60);
      expect(fixture.window.compact, compact);
      expect(find.text('背景不透明度：60%'), findsOneWidget);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor!.a,
        closeTo(.6, .001),
      );
      await tester.tap(find.text('恢复不透明'));
      await tester.pumpAndSettle();
      expect(fixture.window.opacity, 100);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      fixture.dispose();
    }
  });

  testWidgets('opacity failure restores value and allows retry', (
    tester,
  ) async {
    final fixture = DesktopFixture(compact: true);
    await fixture.initialize();
    await tester.pumpWidget(fixture.app);
    await tester.pumpAndSettle();
    await selectMenu(tester, '窗口透明度 · 100%');
    fixture.fail = true;
    tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(40);
    await tester.pumpAndSettle();
    expect(fixture.window.opacity, 100);
    expect(find.textContaining('透明度未能保存'), findsOneWidget);
    fixture.fail = false;
    tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(40);
    await tester.pumpAndSettle();
    expect(fixture.window.opacity, 40);
    expect(find.textContaining('透明度未能保存'), findsNothing);
    await expectLater(fixture.window.setOpacity(0), throwsRangeError);
    expect(fixture.window.opacity, 40);
    await tester.pumpWidget(const SizedBox());
    fixture.dispose();
  });

  testWidgets(
    'opacity panel fits small large-text window and reflects tray reset',
    (tester) async {
      tester.view.physicalSize = const Size(260, 300);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final fixture = DesktopFixture(compact: true);
      await fixture.initialize();
      await fixture.window.setOpacity(50);
      await tester.pumpWidget(fixture.app);
      await tester.pumpAndSettle();
      await selectMenu(tester, '窗口透明度 · 50%');
      expect(tester.takeException(), isNull);
      fixture.opacity = 100;
      await fixture.window.refreshOptions();
      await tester.pumpAndSettle();
      expect(find.text('背景不透明度：100%'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      fixture.dispose();
    },
  );
}
