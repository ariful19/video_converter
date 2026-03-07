import 'package:flutter_test/flutter_test.dart';
import 'package:video_converter_app/src/video_converter_service.dart';

void main() {
  test('buildConversionCommand enforces encoder-safe scaling output', () {
    final service = VideoConverterService();

    final command = service.buildConversionCommand(
      inputPath: '/tmp/input.mp4',
      outputPath: '/tmp/output.mp4',
      targetWidth: 1280,
      targetHeight: 720,
      videoKbps: 4000,
      audioKbps: 128,
      crf: 27,
    );

    expect(
      command,
      contains(
        '"scale=w=1280:h=720:force_original_aspect_ratio=decrease:force_divisible_by=2,setsar=1"',
      ),
    );
  });
}
