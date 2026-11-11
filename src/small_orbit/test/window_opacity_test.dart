import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'compact_view_test.dart';

void main() {
  testWidgets('full and compact menus adjust whole-window opacity and reset', (
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
      expect(find.text('不透明度：60%'), findsOneWidget);
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
      expect(find.text('不透明度：100%'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      fixture.dispose();
    },
  );
}
