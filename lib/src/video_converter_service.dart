import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:path/path.dart' as p;

typedef ProgressCallback = void Function(double progress);

enum ResolutionPreset {
  p2160('2160p (4K)', 2160),
  p1440('1440p', 1440),
  p1080('1080p', 1080),
  p720('720p', 720),
  p480('480p', 480);

  const ResolutionPreset(this.label, this.targetPixels);

  final String label;
  final int targetPixels;
}

class VideoMetadata {
  const VideoMetadata({
    required this.width,
    required this.height,
    required this.duration,
    required this.fileSizeBytes,
    required this.videoBitrate,
    required this.audioBitrate,
  });

  final int width;
  final int height;
  final Duration duration;
  final int fileSizeBytes;
  final int videoBitrate;
  final int audioBitrate;
}

class ConversionResult {
  const ConversionResult({
    required this.outputPath,
    required this.outputSizeBytes,
    required this.targetWidth,
    required this.targetHeight,
    required this.videoBitrate,
    required this.audioBitrate,
  });

  final String outputPath;
  final int outputSizeBytes;
  final int targetWidth;
  final int targetHeight;
  final int videoBitrate;
  final int audioBitrate;
}

class VideoConverterService {
  Future<VideoMetadata> probeVideo(String inputPath) async {
    final file = File(inputPath);
    if (!await file.exists()) {
      throw Exception('Selected file was not found.');
    }

    final fileSizeBytes = await file.length();
    final session = await FFprobeKit.getMediaInformation(inputPath);
    final mediaInformation = session.getMediaInformation();

    if (mediaInformation == null) {
      throw Exception('Could not read video metadata.');
    }

    final properties = _toMap(mediaInformation.getAllProperties());
    final streams = _toList(properties['streams']);
    final format = _toMap(properties['format']);
    final videoStream = _findStream(streams, 'video');
    final audioStream = _findStream(streams, 'audio');

    final width = _parseInt(videoStream['width']);
    final height = _parseInt(videoStream['height']);
    if (width <= 0 || height <= 0) {
      throw Exception('Could not detect video resolution.');
    }

    final durationSeconds = _parseDouble(format['duration']);
    final duration = Duration(
      milliseconds: (durationSeconds > 0 ? durationSeconds * 1000 : 0).round(),
    );
    if (duration <= Duration.zero) {
      throw Exception('Could not detect video duration.');
    }

    final formatBitrate = _parseInt(format['bit_rate']);
    final videoBitrate = _resolveVideoBitrate(videoStream, formatBitrate);
    final audioBitrate = _resolveAudioBitrate(audioStream);

    return VideoMetadata(
      width: width,
      height: height,
      duration: duration,
      fileSizeBytes: fileSizeBytes,
      videoBitrate: videoBitrate,
      audioBitrate: audioBitrate,
    );
  }

  Future<ConversionResult> convertVideo({
    required String inputPath,
    required VideoMetadata metadata,
    required ResolutionPreset preset,
    required ProgressCallback onProgress,
  }) async {
    final targetDimensions = _calculateTargetDimensions(
      inputWidth: metadata.width,
      inputHeight: metadata.height,
      targetPixels: preset.targetPixels,
    );
    final targetBitrates = _calculateTargetBitrates(
      metadata: metadata,
      targetWidth: targetDimensions.width,
      targetHeight: targetDimensions.height,
    );

    final outputPath = _buildOutputPath(inputPath, preset);
    final durationMs = metadata.duration.inMilliseconds;
    final isDownscaling = targetDimensions.width < metadata.width ||
        targetDimensions.height < metadata.height;
    var appliedBitrates = targetBitrates;

    FFmpegKitConfig.enableStatisticsCallback((statistics) {
      final processedMs = _parseInt(statistics.getTime());
      if (processedMs <= 0 || durationMs <= 0) {
        return;
      }
      final progress = (processedMs / durationMs).clamp(0.0, 0.99);
      onProgress(progress);
    });

    await _runConversionCommand(
      inputPath: inputPath,
      outputPath: outputPath,
      targetDimensions: targetDimensions,
      bitrates: targetBitrates,
      crf: isDownscaling ? 27 : 24,
    );

    final outputFile = File(outputPath);
    if (!await outputFile.exists()) {
      throw Exception('Converted file was not created.');
    }

    if (isDownscaling && await outputFile.length() >= metadata.fileSizeBytes) {
      appliedBitrates = targetBitrates.tightened();
      await _runConversionCommand(
        inputPath: inputPath,
        outputPath: outputPath,
        targetDimensions: targetDimensions,
        bitrates: appliedBitrates,
        crf: 30,
      );
    }

    onProgress(1.0);
    return ConversionResult(
      outputPath: outputPath,
      outputSizeBytes: await outputFile.length(),
      targetWidth: targetDimensions.width,
      targetHeight: targetDimensions.height,
      videoBitrate: appliedBitrates.videoKbps * 1000,
      audioBitrate: appliedBitrates.audioKbps * 1000,
    );
  }

  Future<void> _runConversionCommand({
    required String inputPath,
    required String outputPath,
    required _TargetDimensions targetDimensions,
    required _TargetBitrates bitrates,
    required int crf,
  }) async {
    final videoFilter =
        'scale=w=${targetDimensions.width}:h=${targetDimensions.height}:force_original_aspect_ratio=decrease';
    final command = [
      '-y',
      '-i',
      _quote(inputPath),
      '-vf',
      '"$videoFilter"',
      '-c:v',
      'libx264',
      '-preset',
      'medium',
      '-crf',
      '$crf',
      '-b:v',
      '${bitrates.videoKbps}k',
      '-maxrate',
      '${(bitrates.videoKbps * 1.22).round()}k',
      '-bufsize',
      '${(bitrates.videoKbps * 2).round()}k',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      '-b:a',
      '${bitrates.audioKbps}k',
      '-movflags',
      '+faststart',
      _quote(outputPath),
    ].join(' ');

    final session = await FFmpegKit.execute(command);
    final returnCode = await session.getReturnCode();
    if (!ReturnCode.isSuccess(returnCode)) {
      final output = await session.getOutput();
      throw Exception(output ?? 'Video conversion did not complete.');
    }
  }

  String _buildOutputPath(String inputPath, ResolutionPreset preset) {
    final inputDirectory = p.dirname(inputPath);
    final baseName = p.basenameWithoutExtension(inputPath);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final presetTag = preset.name.replaceFirst('p', '');
    return p.join(
      inputDirectory,
      '${baseName}_${presetTag}p_$timestamp.mp4',
    );
  }

  _TargetDimensions _calculateTargetDimensions({
    required int inputWidth,
    required int inputHeight,
    required int targetPixels,
  }) {
    if (inputWidth >= inputHeight) {
      final targetHeight = math.min(targetPixels, inputHeight);
      final targetWidth = (inputWidth * targetHeight / inputHeight).round();
      return _TargetDimensions(
        width: _ensureEven(targetWidth),
        height: _ensureEven(targetHeight),
      );
    }

    final targetWidth = math.min(targetPixels, inputWidth);
    final targetHeight = (inputHeight * targetWidth / inputWidth).round();
    return _TargetDimensions(
      width: _ensureEven(targetWidth),
      height: _ensureEven(targetHeight),
    );
  }

  _TargetBitrates _calculateTargetBitrates({
    required VideoMetadata metadata,
    required int targetWidth,
    required int targetHeight,
  }) {
    final inputPixels = metadata.width * metadata.height;
    final outputPixels = targetWidth * targetHeight;
    final scaleRatio = inputPixels == 0 ? 1.0 : outputPixels / inputPixels;
    final durationSeconds =
        math.max(metadata.duration.inMilliseconds / 1000.0, 1.0);
    final sourceTotalBitrate =
        ((metadata.fileSizeBytes * 8) / durationSeconds).round();
    final normalizedSourceTotal = sourceTotalBitrate.clamp(300000, 100000000);

    final sourceAudioBitrate =
        metadata.audioBitrate > 0 ? metadata.audioBitrate : 128000;
    final sourceVideoBitrate = metadata.videoBitrate > 0
        ? metadata.videoBitrate
        : math.max(250000, normalizedSourceTotal - sourceAudioBitrate);

    final ratioForCompression = scaleRatio.clamp(0.06, 1.0);
    final reductionFactor = scaleRatio < 1
        ? math.pow(ratioForCompression, 0.88).toDouble().clamp(0.12, 0.95)
        : 1.0;
    var targetTotalBitrate = (normalizedSourceTotal * reductionFactor).round();
    if (scaleRatio < 1) {
      final strictCap =
          (normalizedSourceTotal * math.max(scaleRatio * 1.12, 0.14)).round();
      targetTotalBitrate = math.min(targetTotalBitrate, strictCap);
    }
    targetTotalBitrate =
        targetTotalBitrate.clamp(240000, normalizedSourceTotal);

    var targetAudioBitrate = (sourceAudioBitrate *
            math.max(0.6, math.sqrt(scaleRatio.clamp(0.08, 1.0))))
        .round();
    if (scaleRatio < 1) {
      targetAudioBitrate = math.min(targetAudioBitrate, 128000);
    }
    targetAudioBitrate = targetAudioBitrate.clamp(64000, 192000);

    final sourceVideoCap = scaleRatio < 1
        ? (sourceVideoBitrate * math.min(0.9, math.max(scaleRatio * 1.25, 0.2)))
            .round()
        : sourceVideoBitrate;
    final videoFloor = scaleRatio < 1 ? 180000 : 250000;
    var targetVideoBitrate = targetTotalBitrate - targetAudioBitrate;
    targetVideoBitrate = targetVideoBitrate.clamp(
        videoFloor, math.max(videoFloor, sourceVideoCap));
    if (scaleRatio < 1 && targetVideoBitrate >= sourceVideoBitrate) {
      targetVideoBitrate = (sourceVideoBitrate * 0.85).round();
    }

    return _TargetBitrates(
      videoKbps: (targetVideoBitrate / 1000).round(),
      audioKbps: (targetAudioBitrate / 1000).round(),
    );
  }
}

class _TargetDimensions {
  const _TargetDimensions({
    required this.width,
    required this.height,
  });

  final int width;
  final int height;
}

class _TargetBitrates {
  const _TargetBitrates({
    required this.videoKbps,
    required this.audioKbps,
  });

  final int videoKbps;
  final int audioKbps;

  _TargetBitrates tightened() {
    return _TargetBitrates(
      videoKbps: math.max((videoKbps * 0.72).round(), 180),
      audioKbps: math.max((audioKbps * 0.85).round(), 64),
    );
  }
}

Map<String, dynamic> _toMap(dynamic value) {
  if (value is Map) {
    return value.map((key, entry) => MapEntry(key.toString(), entry));
  }
  return const <String, dynamic>{};
}

List<dynamic> _toList(dynamic value) {
  if (value is List) {
    return value;
  }
  return const <dynamic>[];
}

Map<String, dynamic> _findStream(List<dynamic> streams, String codecType) {
  for (final stream in streams) {
    final streamMap = _toMap(stream);
    if (streamMap['codec_type']?.toString() == codecType) {
      return streamMap;
    }
  }
  return const <String, dynamic>{};
}

int _parseInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is double) {
    return value.round();
  }
  if (value is String) {
    return int.tryParse(value) ?? (double.tryParse(value)?.round() ?? 0);
  }
  return 0;
}

double _parseDouble(dynamic value) {
  if (value is double) {
    return value;
  }
  if (value is int) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value) ?? 0;
  }
  return 0;
}

int _resolveVideoBitrate(
  Map<String, dynamic> videoStream,
  int formatBitrate,
) {
  final streamBitrate = _parseInt(videoStream['bit_rate']);
  if (streamBitrate > 0) {
    return streamBitrate;
  }
  if (formatBitrate > 0) {
    return (formatBitrate * 0.85).round();
  }
  return 2500000;
}

int _resolveAudioBitrate(Map<String, dynamic> audioStream) {
  final streamBitrate = _parseInt(audioStream['bit_rate']);
  if (streamBitrate > 0) {
    return streamBitrate;
  }
  return 128000;
}

int _ensureEven(int value) {
  if (value <= 2) {
    return 2;
  }
  return value.isEven ? value : value - 1;
}

String _quote(String value) {
  return '"${value.replaceAll('"', r'\"')}"';
}
