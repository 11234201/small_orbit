import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/bubble_engine.dart';
import 'package:small_orbit/core/task_model.dart';
import 'interaction_polish_test.dart' show occurrence;

BubbleEngine single({MotionMode mode = MotionMode.lively}) => BubbleEngine()
  ..configure([occurrence('flow')], const Size(1000, 1000), mode, false)
  ..bodies.single.position = const Offset(500, 500);

void main() {
  test('free flight curves without a collision and stays speed bounded', () {
    final engine = single(mode: MotionMode.gentle);
    engine.bodies.single.velocity = const Offset(20, 0);
    for (var i = 0; i < 240; i++) {
      engine.step(1 / 120);
      expect(engine.bodies.single.velocity.distance, lessThanOrEqualTo(27.01));
    }
    expect(engine.bodies.single.position.dx, greaterThan(500));
    expect((engine.bodies.single.position.dy - 500).abs(), greaterThan(2));
    engine.dispose();
  });

  test('30 Hz and 120 Hz advance the same flight and collision path', () {
    final slow = single(), fast = single();
    slow.bodies.single.position = Offset(slow.bodies.single.radius + 3, 500);
    fast.bodies.single.position = slow.bodies.single.position;
    slow.bodies.single.velocity = fast.bodies.single.velocity = const Offset(
      -90,
      20,
    );
    for (var i = 0; i < 90; i++) {
      slow.step(1 / 30);
      for (var j = 0; j < 4; j++) {
        fast.step(1 / 120);
      }
      expect(
        (slow.bodies.single.position - fast.bodies.single.position).distance,
        lessThan(.0001),
      );
      expect(
        (slow.bodies.single.strain - fast.bodies.single.strain).distance,
        lessThan(.0001),
      );
    }
    slow.dispose();
    fast.dispose();
  });

  test(
    'wall impact compresses the membrane then settles without distorting text geometry',
    () {
      final engine = single();
      final body = engine.bodies.single;
      final radius = body.radius;
      body.position = Offset(radius + .1, 500);
      body.velocity = const Offset(-100, 0);
      engine.step(1 / 60);
      expect(body.velocity.dx, greaterThan(0));
      expect(body.strain.dx, lessThan(0));
      for (var i = 0; i < 180; i++) {
        engine.step(1 / 120);
      }
      expect(body.strain.distance, lessThan(.0001));
      expect(body.radius, radius);
      engine.dispose();
    },
  );

  test('contact never moves or injects animation into a held target', () {
    final engine = BubbleEngine()
      ..configure(
        [occurrence('held'), occurrence('incoming')],
        const Size(1000, 1000),
        MotionMode.lively,
        false,
      );
    final held = engine.bodies.first, incoming = engine.bodies.last;
    held.position = const Offset(400, 500);
    held.velocity = const Offset(120, 0);
    engine.holdIdentity(held.id, 'press', true);
    incoming.position = Offset(400 + held.radius + incoming.radius + 1, 500);
    incoming.velocity = const Offset(-90, 0);
    for (var i = 0; i < 60; i++) {
      engine.step(1 / 120);
    }
    expect(held.position, const Offset(400, 500));
    expect(held.strain, Offset.zero);
    expect(held.breath, 0);
    expect(incoming.position.dx, greaterThan(held.position.dx + held.radius));
    engine.dispose();
  });

  test('invalid clocks and resumed frames cannot teleport bubbles', () {
    final engine = single();
    final start = engine.bodies.single.position;
    for (final invalid in [double.nan, double.infinity, -1.0, 0.0]) {
      engine.step(invalid);
    }
    expect(engine.bodies.single.position, start);
    engine.step(30);
    expect(engine.elapsed, closeTo(.1, .00001));
    expect(
      (engine.bodies.single.position - start).distance,
      lessThanOrEqualTo(12),
    );
    engine.dispose();
  });

  test(
    'opening settles completely and reduced motion freezes all dynamics',
    () {
      final engine = single(mode: MotionMode.opening);
      for (var i = 0; i < 200; i++) {
        engine.step(1 / 30);
      }
      final body = engine.bodies.single;
      expect(engine.moving, isFalse);
      expect(body.strain, Offset.zero);
      expect(body.breath, 0);
      final position = body.position;
      engine.step(.1);
      expect(body.position, position);
      engine.replay();
      engine.paused = true;
      engine.step(.1);
      expect(body.position, position);
      expect(body.strain, Offset.zero);
      engine.dispose();
    },
  );
}
