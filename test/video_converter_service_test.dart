import 'package:flutter_test/flutter_test.dart';
import 'package:video_converter_app/src/video_converter_service.dart';

void main() {
  test('resolveDisplayDimensions swaps encoded size for rotated portrait video',
      () {
    final dimensions = resolveDisplayDimensions(
      encodedWidth: 1920,
      encodedHeight: 1080,
      rotationDegrees: -90,
    );

    expect(dimensions.width, 1080);
    expect(dimensions.height, 1920);
  });

  test('calculateTargetDimensionsForDisplay keeps portrait output bounds', () {
    final targetDimensions = calculateTargetDimensionsForDisplay(
      inputWidth: 1080,
      inputHeight: 1920,
      targetPixels: 720,
    );

    expect(targetDimensions.width, 720);
    expect(targetDimensions.height, 1280);
  });

  test('buildScaleFilter forces even output dimensions', () {
    expect(
      buildScaleFilter(maxWidth: 720, maxHeight: 1280),
      contains('force_divisible_by=2'),
    );
  });
}
