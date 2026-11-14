import 'dart:math';

import 'package:flutter/material.dart';

import '../core/bubble_engine.dart';
import '../core/play_settings.dart';

/// Only the membrane deforms. Task text, semantics and tap targets stay steady.
class BubbleSurface extends CustomPainter {
  BubbleSurface({
    required this.engine,
    required this.body,
    required this.color,
    this.material = BubbleMaterial.classic,
  }) : super(repaint: engine);

  final BubbleMaterial material;
  final BubbleEngine engine;
  final BubbleBody body;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = min(size.width, size.height) * .5;
    // Reserve room for the elastic rim inside the circular interaction area.
    final r = radius * .92;
    final rect = Rect.fromCircle(center: Offset.zero, radius: r);
    final tint = HSLColor.fromColor(
      material == BubbleMaterial.water
          ? Color.lerp(color, const Color(0xffa8dbf5), .55)!
          : color,
    );
    final edge = tint.withSaturation(.62).withLightness(.73).toColor();
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    final strain = engine.paused ? 0.0 : body.strain.distance;
    final breath = engine.paused ? 0.0 : body.breath;
    final angle = atan2(body.strain.dy, body.strain.dx) / 2;
    canvas.rotate(angle);
    canvas.scale((1 + strain) * (1 + breath), (1 + breath) / (1 + strain));
    canvas.rotate(-angle);

    canvas.drawCircle(
      const Offset(0, 2),
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: .08),
            color.withValues(alpha: .24),
            color.withValues(alpha: 0),
          ],
          stops: const [.7, .91, 1],
        ).createShader(rect.inflate(3)),
    );
    canvas.drawCircle(
      Offset.zero,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-.22, -.28),
          radius: .76,
          colors: [
            Color.lerp(color, Colors.white, .86)!,
            Color.lerp(color, Colors.white, .65)!,
            Color.lerp(color, Colors.white, .12)!,
            edge,
          ],
          stops: const [0, .55, .82, 1],
        ).createShader(rect),
    );
    // The quiet centre keeps lettering legible; colour collects at the rim.
    canvas.drawCircle(
      Offset.zero,
      r - 1.1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..shader = SweepGradient(
          colors: [
            edge.withValues(alpha: .20),
            const Color(0xffe9b9df).withValues(alpha: .65),
            Colors.white.withValues(alpha: .95),
            const Color(0xffb5dfe9).withValues(alpha: .55),
            Colors.white.withValues(alpha: .95),
            edge.withValues(alpha: .20),
          ],
          stops: const [0, .18, .37, .59, .78, 1],
        ).createShader(rect),
    );
    final highlight = Rect.fromCenter(
      center: Offset(-r * .29, -r * .43),
      width: r * .92,
      height: r * .47,
    );
    canvas.drawOval(
      highlight,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xd9ffffff), Color(0x00ffffff)],
        ).createShader(highlight),
    );
    canvas.drawArc(
      rect.deflate(4),
      pi * 1.12,
      pi * .46,
      false,
      Paint()
        ..color = Colors.white.withValues(alpha: .88)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawArc(
      rect.deflate(4.5),
      pi * .12,
      pi * .23,
      false,
      Paint()
        ..color = Colors.white.withValues(alpha: .62)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..strokeCap = StrokeCap.round,
    );
    if (material == BubbleMaterial.pudding) {
      canvas.drawArc(
        Rect.fromCenter(
          center: Offset(0, -r * .25),
          width: r * 1.5,
          height: r * .65,
        ),
        pi,
        pi,
        false,
        Paint()
          ..color = const Color(0xffbd8548).withValues(alpha: .4)
          ..strokeWidth = r * .1,
      );
      canvas.drawCircle(
        Offset(r * .3, -r * .48),
        r * .09,
        Paint()..color = const Color(0xffe8a0a8),
      );
    } else if (material == BubbleMaterial.soap) {
      canvas.drawCircle(
        Offset.zero,
        r - 3,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..shader = const SweepGradient(
            colors: [
              Color(0xffeeb3d3),
              Color(0xffb3d8ff),
              Color(0xffb6ecd7),
              Color(0xffffdf9d),
              Color(0xffeeb3d3),
            ],
          ).createShader(rect),
      );
    } else if (material == BubbleMaterial.water) {
      canvas.drawArc(
        rect.deflate(r * .15),
        .2,
        1.5,
        false,
        Paint()
          ..color = const Color(0xff71b8e0).withValues(alpha: .5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant BubbleSurface oldDelegate) =>
      oldDelegate.material != material ||
      oldDelegate.body != body ||
      oldDelegate.color != color ||
      oldDelegate.engine != engine;
}

/// A brief expanding rim and six glints; no particles or ticker after the pop.
class BubbleBurst extends CustomPainter {
  BubbleBurst({required this.color, required this.progress});
  final Color color;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || progress >= 1) return;
    final center = size.center(Offset.zero);
    final radius = min(size.width, size.height) * .5;
    final opacity = sin(progress * pi);
    final tint = HSLColor.fromColor(color).withLightness(.68).toColor();
    canvas.drawCircle(
      center,
      radius * (.83 + .17 * progress),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 * (1 - progress)
        ..color = tint.withValues(alpha: opacity * .6),
    );
    for (var i = 0; i < 6; i++) {
      final direction = Offset(cos(i * pi / 3 + .2), sin(i * pi / 3 + .2));
      canvas.drawCircle(
        center + direction * radius * (.8 + .18 * progress),
        2.2 * (1 - progress),
        Paint()..color = tint.withValues(alpha: opacity),
      );
    }
  }

  @override
  bool shouldRepaint(covariant BubbleBurst oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
