import 'dart:math';
import 'package:flutter/material.dart';
import '../core/bubble_engine.dart';

/// Only the membrane deforms. Task text, semantics and tap targets stay steady.
class BubbleSurface extends CustomPainter {
  BubbleSurface({required this.engine, required this.body, required this.color})
    : super(repaint: engine);

  final BubbleEngine engine;
  final BubbleBody body;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = min(size.width, size.height) * .5;
    // Reserve room for the elastic rim inside the circular interaction area.
    final r = radius * .92;
    final rect = Rect.fromCircle(center: Offset.zero, radius: r);
    final tint = HSLColor.fromColor(color);
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
            color.withValues(alpha: .74),
            edge.withValues(alpha: .55),
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
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant BubbleSurface oldDelegate) =>
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
