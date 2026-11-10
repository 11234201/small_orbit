import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'task_model.dart';

class BubbleBody {
  BubbleBody(this.id, this.radius, this.position, this.velocity);
  final String id;
  final double radius;
  Offset position;
  Offset velocity;
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
  void configure(
    List<TaskOccurrence> tasks,
    Size bounds,
    MotionMode mode,
    bool stop,
  ) {
    final signature = tasks
        .map((task) => '${task.identity}:${task.task.priority}')
        .join('|');
    final changed = bounds != size || signature != _signature;
    _signature = signature;
    if (mode != motion) {
      motion = mode;
      elapsed = 0;
      _kick();
    }
    paused = stop;
    if (!changed) return;
    size = bounds;
    elapsed = 0;
    bodies.clear();
    final columns = bounds.width >= 540 ? 3 : 2;
    final rows = max(2, (tasks.length / columns).ceil());
    final cellWidth = bounds.width / columns, cellHeight = bounds.height / rows;
    final maxRadius = max(16.0, min(cellWidth, cellHeight) * .43);
    for (var i = 0; i < tasks.length; i++) {
      final radius = maxRadius * sqrt((tasks[i].task.priority + 1) / 7);
      bodies.add(
        BubbleBody(
          tasks[i].identity,
          radius,
          Offset(
            cellWidth * (i % columns + .5),
            cellHeight * (i ~/ columns + .5),
          ),
          _velocity(),
        ),
      );
    }
  }

  Offset _velocity() {
    final angle = _random.nextDouble() * pi * 2;
    final speed = motion == MotionMode.gentle ? 15.0 : 95.0;
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
    if (index >= bodies.length) return;
    if (value) {
      bodies[index].holds.add(reason);
    } else {
      bodies[index].holds.remove(reason);
    }
  }

  void step(double seconds) {
    if (paused ||
        size.isEmpty ||
        (motion == MotionMode.opening && elapsed >= 6.5))
      return;
    final dt = seconds.clamp(0.0, .032);
    elapsed += dt;
    for (final body in bodies) {
      if (body.held) continue;
      if (motion == MotionMode.opening)
        body.velocity *= exp(-.48 * dt);
      else {
        final target = motion == MotionMode.gentle ? 15.0 : 80.0;
        if (body.velocity.distance < target * .85) {
          body.velocity = body.velocity.distance < 1
              ? _velocity()
              : body.velocity * (1 + .6 * dt);
        }
      }
      body.position += body.velocity * dt;
      _wall(body);
    }
    for (var i = 0; i < bodies.length; i++) {
      for (var j = i + 1; j < bodies.length; j++) {
        final a = bodies[i], b = bodies[j];
        final delta = b.position - a.position;
        final distance = delta.distance;
        final minimum = a.radius + b.radius + 3;
        if (distance >= minimum || (a.held && b.held)) continue;
        final normal = distance < .001 ? const Offset(1, 0) : delta / distance;
        final overlap = minimum - distance;
        final aShare = a.held
            ? 0.0
            : b.held
            ? 1.0
            : .5;
        final bShare = b.held
            ? 0.0
            : a.held
            ? 1.0
            : .5;
        a.position -= normal * overlap * aShare;
        b.position += normal * overlap * bShare;
        final relative =
            (b.velocity.dx - a.velocity.dx) * normal.dx +
            (b.velocity.dy - a.velocity.dy) * normal.dy;
        if (relative < 0) {
          a.velocity -= normal * (-relative * 1.8 * aShare);
          b.velocity += normal * (-relative * 1.8 * bShare);
        }
        _wall(a);
        _wall(b);
      }
    }
    notifyListeners();
  }

  void _wall(BubbleBody body) {
    final x = body.position.dx.clamp(
      body.radius,
      max(body.radius, size.width - body.radius),
    );
    final y = body.position.dy.clamp(
      body.radius,
      max(body.radius, size.height - body.radius),
    );
    if (x != body.position.dx)
      body.velocity = Offset(-body.velocity.dx * .92, body.velocity.dy);
    if (y != body.position.dy)
      body.velocity = Offset(body.velocity.dx, -body.velocity.dy * .92);
    body.position = Offset(x.toDouble(), y.toDouble());
  }
}
