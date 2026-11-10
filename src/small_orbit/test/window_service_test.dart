import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/platform/window_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('small_orbit/window_test');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<Object?> sendFromNative(MethodCall call) async {
    final reply = Completer<Object?>();
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(call),
      (data) =>
          reply.complete(data == null ? null : codec.decodeEnvelope(data)),
    );
    return reply.future;
  }

  Future<Object?> prepareFromNative() =>
      sendFromNative(const MethodCall('prepareToQuit'));
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('hidden startup is learned without blocking registration', () async {
    final query = Completer<bool>();
    messenger.setMockMethodCallHandler(channel, (call) => query.future);
    final service = WindowService(
      enabled: true,
      bridge: channel,
      onPrepareToQuit: () async {},
    );
    service.register();
    try {
      expect(service.isVisible, isTrue);
      query.complete(false);
      await Future<void>.delayed(Duration.zero);
      expect(service.isVisible, isFalse);
      expect(await prepareFromNative(), isTrue);
    } finally {
      service.dispose();
    }
  });

  test('native visibility events notify only when the value changes', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => true);
    final service = WindowService(
      enabled: true,
      bridge: channel,
      onPrepareToQuit: () async {},
    );
    var changes = 0;
    service.addListener(() => changes++);
    service.register();
    try {
      await Future<void>.delayed(Duration.zero);
      await sendFromNative(const MethodCall('visibilityChanged', false));
      expect(service.isVisible, isFalse);
      await sendFromNative(const MethodCall('visibilityChanged', false));
      await sendFromNative(const MethodCall('visibilityChanged', true));
      expect(service.isVisible, isTrue);
      expect(changes, 2);
    } finally {
      service.dispose();
    }
  });

  test(
    'late initial query never overwrites a newer native visibility event',
    () async {
      final query = Completer<bool>();
      messenger.setMockMethodCallHandler(channel, (call) => query.future);
      final service = WindowService(
        enabled: true,
        bridge: channel,
        onPrepareToQuit: () async {},
      );
      service.register();
      try {
        await sendFromNative(const MethodCall('visibilityChanged', true));
        query.complete(false);
        await Future<void>.delayed(Duration.zero);
        expect(service.isVisible, isTrue);
      } finally {
        service.dispose();
      }
    },
  );

  test(
    'native quit waits for pending writes and coalesces duplicate requests',
    () async {
      final pendingWrite = Completer<void>();
      var preparationCount = 0;
      final service = WindowService(
        enabled: true,
        bridge: channel,
        onPrepareToQuit: () async {
          preparationCount++;
          await pendingWrite.future;
        },
      );
      service.register();
      try {
        final first = prepareFromNative();
        final second = prepareFromNative();
        var exited = false;
        unawaited(first.then((_) => exited = true));
        await Future<void>.delayed(Duration.zero);
        expect(service.isClosing, isTrue);
        expect(exited, isFalse);
        expect(preparationCount, 1);
        pendingWrite.complete();
        expect(await first, isTrue);
        expect(await second, isTrue);
      } finally {
        service.dispose();
      }
    },
  );

  test(
    'failed preparation retains the window and allows another exit',
    () async {
      var shouldFail = true;
      final service = WindowService(
        enabled: true,
        bridge: channel,
        onPrepareToQuit: () async {
          if (shouldFail) throw StateError('disk unavailable');
        },
      );
      service.register();
      try {
        expect(await prepareFromNative(), isFalse);
        expect(service.isClosing, isFalse);
        expect(service.lastError, isNotNull);
        shouldFail = false;
        expect(await prepareFromNative(), isTrue);
        expect(service.isClosing, isTrue);
        expect(service.lastError, isNull);
      } finally {
        service.dispose();
      }
    },
  );
}
