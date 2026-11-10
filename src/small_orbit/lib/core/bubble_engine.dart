import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'task_model.dart';

class BubbleBody {
  BubbleBody(this.id, this.radius, this.position, this.velocity)
    : phase =
          (id.codeUnits.fold(0, (a, b) => (a * 31 + b) % 997) / 997) * pi * 2;
  final String id;
  double radius;
  Offset position;
  Offset velocity;
  final double phase;
  // A symmetric, area-preserving deformation, separate from the text/hit area.
  Offset strain = Offset.zero;
  Offset strainVelocity = Offset.zero;
  double breath = 0;
  final Set<String> holds = {};
  bool get held => holds.isNotEmpty;
}

class BubbleEngine extends ChangeNotifier {
  final List<BubbleBody> bodies = [];
  Size size = Size.zero;
  MotionMode motion = MotionMode.opening;
  bool paused = false;
  double elapsed = 0;
  String _signature = '';
  final Random _random = Random(73);
  bool get moving =>
      !paused &&
      !size.isEmpty &&
      bodies.any((body) => !body.held) &&
      (motion != MotionMode.opening || elapsed < 6.5);
  void configure(
    List<TaskOccurrence> tasks,
    Size bounds,
    MotionMode mode,
    bool stop, {
    int? capacity,
  }) {
    final taskSignature = tasks
        .map((task) => '${task.identity}:${task.task.priority}')
        .join('|');
    final signature = '${capacity ?? tasks.length}:$taskSignature';
    final changed = bounds != size || signature != _signature;
    _signature = signature;
    if (mode != motion) {
      motion = mode;
      elapsed = 0;
      _kick();
    }
    paused = stop;
    if (!changed) return;
    final previousSize = size;
    final previous = {for (final body in bodies) body.id: body};
    size = bounds;
    // Removing or reprioritizing one task should not throw every other task
    // back to the opening grid, especially while the user is pressing one.
    if (previous.isEmpty ||
        tasks.any((task) => !previous.containsKey(task.identity))) {
      elapsed = 0;
    }
    bodies.clear();
    final columns = bounds.width >= 540 ? 3 : 2;
    final rows = max(2, ((capacity ?? tasks.length) / columns).ceil());
    final cellWidth = bounds.width / columns, cellHeight = bounds.height / rows;
    final maxRadius = max(16.0, min(cellWidth, cellHeight) * .43);
    for (var i = 0; i < tasks.length; i++) {
      final radius = maxRadius * sqrt((tasks[i].task.priority + 1) / 7);
      final retained = previous[tasks[i].identity];
      final body =
          retained ??
          BubbleBody(
            tasks[i].identity,
            radius,
            Offset(
              cellWidth * (i % columns + .5),
              cellHeight * (i ~/ columns + .5),
            ),
            _velocity(),
          );
      body.radius = radius;
      if (retained == null) {
        body.position += Offset(
          sin(body.phase) * cellWidth * .075,
          cos(body.phase * 1.3) * cellHeight * .065,
        );
      }
      if (retained != null && previousSize != bounds && !previousSize.isEmpty) {
        body.position = Offset(
          body.position.dx * bounds.width / previousSize.width,
          body.position.dy * bounds.height / previousSize.height,
        );
      }
      _wall(body, feedback: false);
      bodies.add(body);
    }
  }

  Offset _velocity() {
    final angle = _random.nextDouble() * pi * 2;
    final speed =
        (switch (motion) {
          MotionMode.gentle => 17.0,
          MotionMode.lively => 65.0,
          MotionMode.opening => 108.0,
        }) *
        (.78 + _random.nextDouble() * .44);
    return Offset(cos(angle) * speed, sin(angle) * speed);
  }

  void _kick() {
    for (final body in bodies) {
      body.velocity = _velocity();
    }
  }

  void replay() {
    elapsed = 0;
    _kick();
    notifyListeners();
  }

  void hold(int index, String reason, bool value) {
    if (index < 0 || index >= bodies.length) return;
    holdIdentity(bodies[index].id, reason, value);
  }

  void holdIdentity(String id, String reason, bool value) {
    final body = bodies.where((body) => body.id == id).firstOrNull;
    if (body == null) return;
    if (value) {
      body.holds.add(reason);
    } else {
      body.holds.remove(reason);
    }
  }

  void step(double seconds) {
    if (!moving || !seconds.isFinite || seconds <= 0) return;
    // Stable on both 30 Hz phones and high-refresh displays. A resumed window
    // advances at most 100 ms instead of jumping across the whole stage.
    var remaining = min(seconds, .1);
    while (remaining > .000001 && moving) {
      final dt = min(remaining, 1 / 120);
      _integrate(dt);
      remaining -= dt;
    }
    notifyListeners();
  }

  void _integrate(double dt) {
    elapsed += dt;
    final envelope = motion == MotionMode.opening
        ? pow(max(0.0, 1 - elapsed / 6.5), 2).toDouble()
        : 1.0;
    for (final body in bodies) {
      if (body.held) continue;
      final flow = Offset(
        sin(elapsed * .67 + body.phase) +
            .35 * cos(elapsed * 1.13 - body.phase),
        .78 * cos(elapsed * .53 + body.phase * 1.7),
      );
      final acceleration = motion == MotionMode.gentle ? 11.0 : 25.0;
      body.velocity += flow * acceleration * envelope * dt;
      final drag = motion == MotionMode.opening
          ? .62 + 1.3 * (1 - envelope)
          : .30;
      body.velocity *= exp(-drag * dt);
      final limit = motion == MotionMode.gentle ? 27.0 : 120.0;
      if (body.velocity.distance > limit) {
        body.velocity = body.velocity / body.velocity.distance * limit;
      }
      body.position += body.velocity * dt;
      _wall(body);
      body.strainVelocity +=
          (body.strain * -155 - body.strainVelocity * 13) * dt;
      body.strain += body.strainVelocity * dt;
      if (body.strain.distance > .075) {
        body.strain = body.strain / body.strain.distance * .075;
      }
      body.breath = sin(elapsed * 1.45 + body.phase) * .008 * envelope;
    }
    for (var i = 0; i < bodies.length; i++) {
      for (var j = i + 1; j < bodies.length; j++) {
        _collide(bodies[i], bodies[j], dt);
      }
    }
    if (motion == MotionMode.opening && elapsed >= 6.5) {
      elapsed = 6.5;
      for (final body in bodies) {
        body.velocity = Offset.zero;
        body.strain = Offset.zero;
        body.strainVelocity = Offset.zero;
        body.breath = 0;
      }
    }
  }

  void _collide(BubbleBody a, BubbleBody b, double dt) {
    if (a.held && b.held) return;
    final delta = b.position - a.position;
    final distance = delta.distance;
    final minimum = a.radius + b.radius + 3;
    if (distance >= minimum + 12) return;
    final normal = distance < .001 ? const Offset(1, 0) : delta / distance;
    final aMass = a.held ? 0.0 : 1 / (a.radius * a.radius);
    final bMass = b.held ? 0.0 : 1 / (b.radius * b.radius);
    final aShare = aMass / (aMass + bMass), bShare = 1 - aShare;
    final relative =
        (b.held ? Offset.zero : b.velocity) -
        (a.held ? Offset.zero : a.velocity);
    final closing = relative.dx * normal.dx + relative.dy * normal.dy;
    if (distance >= minimum) {
      // Ease into contact, rather than abruptly swapping direction.
      if (closing < 0) {
        final cushion = pow(1 - (distance - minimum) / 12, 2) * 110 * dt;
        if (!a.held) a.velocity -= normal * cushion * aShare;
        if (!b.held) b.velocity += normal * cushion * bShare;
      }
      return;
    }
    final correction = min((minimum - distance) * .65, 3.0);
    if (!a.held) a.position -= normal * correction * aShare;
    if (!b.held) b.position += normal * correction * bShare;
    if (closing < 0) {
      if (!a.held) a.velocity += normal * closing * 1.74 * aShare;
      if (!b.held) b.velocity -= normal * closing * 1.74 * bShare;
      _squish(a, normal, -closing);
      _squish(b, normal, -closing);
    }
    if (!a.held) _wall(a);
    if (!b.held) _wall(b);
  }

  void _squish(BubbleBody body, Offset normal, double speed) {
    if (body.held || speed < 3) return;
    final angle = atan2(normal.dy, normal.dx);
    body.strainVelocity -=
        Offset(cos(2 * angle), sin(2 * angle)) * min(speed / 100, 1.2);
  }

  void _wall(BubbleBody body, {bool feedback = true}) {
    final x = body.position.dx.clamp(
      body.radius,
      max(body.radius, size.width - body.radius),
    );
    final y = body.position.dy.clamp(
      body.radius,
      max(body.radius, size.height - body.radius),
    );
    if (x != body.position.dx) {
      if (feedback) _squish(body, const Offset(1, 0), body.velocity.dx.abs());
      body.velocity = Offset(
        body.velocity.dx.abs() * (x == body.radius ? .78 : -.78),
        body.velocity.dy,
      );
    }
    if (y != body.position.dy) {
      if (feedback) _squish(body, const Offset(0, 1), body.velocity.dy.abs());
      body.velocity = Offset(
        body.velocity.dx,
        body.velocity.dy.abs() * (y == body.radius ? .78 : -.78),
      );
    }
    body.position = Offset(x.toDouble(), y.toDouble());
  }
}
