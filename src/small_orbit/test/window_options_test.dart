import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/platform/window_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('small_orbit/options_test');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<void> event(bool compact, bool top) async {
    final done = Completer<void>();
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
        MethodCall('optionsChanged', {'compact': compact, 'alwaysOnTop': top}),
      ),
      (_) => done.complete(),
    );
    await done.future;
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('options load and tray changes update both choices', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'isVisible'
          ? true
          : {'compact': true, 'alwaysOnTop': true},
    );
    final service = WindowService(
      bridge: channel,
      enabled: true,
      onPrepareToQuit: () async {},
    )..register();
    await Future<void>.delayed(Duration.zero);
    expect(service.optionsLoaded, isTrue);
    expect(service.compact, isTrue);
    expect(service.alwaysOnTop, isTrue);
    await event(false, true);
    expect(service.compact, isFalse);
    expect(service.alwaysOnTop, isTrue);
    service.dispose();
  });

  test('initial options query cannot replace a newer write', () async {
    final initial = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isVisible') return true;
      if (call.method == 'getOptions') return initial.future;
      return {'compact': true, 'alwaysOnTop': false};
    });
    final service = WindowService(
      bridge: channel,
      enabled: true,
      onPrepareToQuit: () async {},
    )..register();
    await service.setCompact(true);
    initial.complete({'compact': false, 'alwaysOnTop': false});
    await Future<void>.delayed(Duration.zero);
    expect(service.compact, isTrue);
    service.dispose();
  });

  test(
    'queued independent writes preserve both choices and quit drains them',
    () async {
      var compact = false, top = false, prepared = false;
      final gate = Completer<void>();
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'isVisible') return true;
        if (call.method == 'setCompact') {
          methods.add(call.method);
          await gate.future;
          compact = call.arguments as bool;
        }
        if (call.method == 'setAlwaysOnTop') {
          methods.add(call.method);
          top = call.arguments as bool;
        }
        return {'compact': compact, 'alwaysOnTop': top};
      });
      final service = WindowService(
        bridge: channel,
        enabled: true,
        onPrepareToQuit: () async {
          prepared = true;
        },
      )..register();
      await Future<void>.delayed(Duration.zero);
      final first = service.setCompact(true),
          second = service.setAlwaysOnTop(true);
      final quit = Completer<Object?>();
      unawaited(
        messenger.handlePlatformMessage(
          channel.name,
          codec.encodeMethodCall(const MethodCall('prepareToQuit')),
          (data) => quit.complete(codec.decodeEnvelope(data!)),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(methods, ['setCompact']);
      expect(prepared, isFalse);
      gate.complete();
      await Future.wait([first, second]);
      expect(await quit.future, isTrue);
      expect(service.compact && service.alwaysOnTop, isTrue);
      expect(methods, ['setCompact', 'setAlwaysOnTop']);
      service.dispose();
    },
  );

  test('failed native write preserves settings and queue can retry', () async {
    var fail = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isVisible') return true;
      if (call.method == 'setCompact' && fail)
        throw PlatformException(code: 'disk');
      return {'compact': call.method == 'setCompact', 'alwaysOnTop': false};
    });
    final service = WindowService(
      bridge: channel,
      enabled: true,
      onPrepareToQuit: () async {},
    )..register();
    await Future<void>.delayed(Duration.zero);
    await expectLater(
      service.setCompact(true),
      throwsA(isA<PlatformException>()),
    );
    expect(service.compact, isFalse);
    expect(service.updatingOptions, isFalse);
    fail = false;
    await service.setCompact(true);
    expect(service.compact, isTrue);
    service.dispose();
  });

  test('tray update wins over a late write reply', () async {
    final reply = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isVisible') return true;
      if (call.method == 'setCompact') return reply.future;
      return {'compact': false, 'alwaysOnTop': false};
    });
    final service = WindowService(
      bridge: channel,
      enabled: true,
      onPrepareToQuit: () async {},
    )..register();
    await Future<void>.delayed(Duration.zero);
    final write = service.setCompact(true);
    await Future<void>.delayed(Duration.zero);
    await event(false, true);
    reply.complete({'compact': true, 'alwaysOnTop': false});
    await write;
    expect(service.compact, isFalse);
    expect(service.alwaysOnTop, isTrue);
    service.dispose();
  });
}
