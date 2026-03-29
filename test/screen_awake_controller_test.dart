import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_converter_app/src/screen_awake_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScreenAwakeController', () {
    test('toggles keep-screen-on around a successful action', () async {
      const channel = MethodChannel('test/screen_awake/success');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });

      final controller = ScreenAwakeController(channel: channel);
      final result = await controller.whileAwake(() async => 7);

      expect(result, 7);
      expect(
        calls,
        <Matcher>[
          isMethodCall('setKeepScreenOn', arguments: true),
          isMethodCall('setKeepScreenOn', arguments: false),
        ],
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('releases keep-screen-on when the action throws', () async {
      const channel = MethodChannel('test/screen_awake/error');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });

      final controller = ScreenAwakeController(channel: channel);

      await expectLater(
        controller.whileAwake<int>(() async => throw StateError('boom')),
        throwsStateError,
      );
      expect(
        calls,
        <Matcher>[
          isMethodCall('setKeepScreenOn', arguments: true),
          isMethodCall('setKeepScreenOn', arguments: false),
        ],
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
  });
}
