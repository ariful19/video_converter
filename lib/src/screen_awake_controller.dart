import 'package:flutter/services.dart';

class ScreenAwakeController {
  const ScreenAwakeController({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('video_converter/platform');

  final MethodChannel _channel;

  Future<T> whileAwake<T>(Future<T> Function() action) async {
    await _setKeepScreenOn(true);
    try {
      return await action();
    } finally {
      await _setKeepScreenOn(false);
    }
  }

  Future<void> _setKeepScreenOn(bool shouldKeepScreenOn) async {
    try {
      await _channel.invokeMethod<void>(
        'setKeepScreenOn',
        shouldKeepScreenOn,
      );
    } on MissingPluginException {
      // Ignore unsupported platforms so conversion can continue.
    } on PlatformException {
      // Ignore platform failures so conversion can continue.
    }
  }
}
