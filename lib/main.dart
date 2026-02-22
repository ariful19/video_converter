import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'src/video_converter_service.dart';

void main() {
  runApp(const VideoConverterApp());
}

class VideoConverterApp extends StatelessWidget {
  const VideoConverterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Video Converter',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B4CCA)),
        useMaterial3: true,
      ),
      home: const VideoConverterHomePage(),
    );
  }
}

class VideoConverterHomePage extends StatefulWidget {
  const VideoConverterHomePage({super.key});

  @override
  State<VideoConverterHomePage> createState() => _VideoConverterHomePageState();
}

class _VideoConverterHomePageState extends State<VideoConverterHomePage> {
  final VideoConverterService _service = VideoConverterService();
  static const MethodChannel _platformChannel =
      MethodChannel('video_converter/platform');

  String? _selectedFilePath;
  String? _selectedDisplayName;
  String? _sourceRelativePath;
  String? _outputTreeUri;
  String? _outputFolderLabel;
  VideoMetadata? _metadata;
  ResolutionPreset _preset = ResolutionPreset.p720;
  ConversionResult? _result;
  String? _statusMessage;
  bool _isPickingFile = false;
  bool _isConverting = false;
  double _progress = 0;

  Future<void> _selectVideo() async {
    if (_isConverting || _isPickingFile) {
      return;
    }

    setState(() {
      _isPickingFile = true;
      _statusMessage = null;
    });

    try {
      final pickedData = await _platformChannel
          .invokeMapMethod<String, dynamic>('pickVideoWithContext');
      if (pickedData == null) {
        setState(() => _isPickingFile = false);
        return;
      }

      final path = pickedData['inputPath'] as String?;
      if (path == null) {
        setState(() => _isPickingFile = false);
        return;
      }
      final displayName = pickedData['displayName'] as String?;
      final relativePath = pickedData['relativePath'] as String?;
      _OutputFolderAccess? outputFolderAccess;
      if (relativePath == null || relativePath.trim().isEmpty) {
        outputFolderAccess = await _ensureOutputFolderAccess();
      }

      final metadata = await _service.probeVideo(path);
      if (!mounted) {
        return;
      }

      setState(() {
        _selectedFilePath = path;
        _selectedDisplayName = displayName;
        _sourceRelativePath = relativePath;
        _outputTreeUri = outputFolderAccess?.treeUri;
        _outputFolderLabel = outputFolderAccess?.label;
        _metadata = metadata;
        _result = null;
        _progress = 0;
        _statusMessage = relativePath != null && relativePath.trim().isNotEmpty
            ? 'Video loaded from $relativePath'
            : outputFolderAccess != null
                ? 'Video loaded. Output will be saved to ${outputFolderAccess.label ?? 'selected folder'}.'
                : 'Video loaded. Grant folder access to save output.';
        _isPickingFile = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isPickingFile = false;
        _statusMessage = 'Could not load video: $error';
      });
    }
  }

  Future<void> _convertVideo() async {
    final inputPath = _selectedFilePath;
    final metadata = _metadata;
    final relativePath = _sourceRelativePath;
    final outputTreeUri = _outputTreeUri;
    final sourceShortEdge =
        metadata == null ? 0 : math.min(metadata.width, metadata.height);
    final isDownscaleSelection =
        metadata != null && _preset.targetPixels < sourceShortEdge;
    final hasOutputTarget =
        (relativePath != null && relativePath.trim().isNotEmpty) ||
            (outputTreeUri != null && outputTreeUri.trim().isNotEmpty);
    if (inputPath == null || metadata == null || _isConverting) {
      return;
    }
    if (!isDownscaleSelection) {
      setState(() {
        _statusMessage =
            'Choose a lower resolution than source (${sourceShortEdge}p short edge) to reduce file size.';
      });
      return;
    }
    if (!hasOutputTarget) {
      setState(() {
        _statusMessage =
            'Cannot determine output folder. Please grant folder access and try again.';
      });
      return;
    }

    setState(() {
      _isConverting = true;
      _progress = 0;
      _result = null;
      _statusMessage = 'Converting video...';
    });

    try {
      final tempResult = await _service.convertVideo(
        inputPath: inputPath,
        metadata: metadata,
        preset: _preset,
        onProgress: (progress) {
          if (!mounted) {
            return;
          }
          setState(() {
            _progress = progress;
          });
        },
      );
      final savedResult = await _saveConvertedVideoToSourceFolder(
        tempResult,
        relativePath: relativePath,
        outputTreeUri: outputTreeUri,
      );
      if (!mounted) {
        return;
      }
      final savedFolder =
          relativePath ?? _outputFolderLabel ?? 'selected folder';

      setState(() {
        _isConverting = false;
        _progress = 1;
        _result = savedResult;
        _statusMessage = 'Conversion completed and saved to $savedFolder';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isConverting = false;
        _statusMessage = 'Conversion failed: $error';
      });
    }
  }

  Future<ConversionResult> _saveConvertedVideoToSourceFolder(
    ConversionResult tempResult, {
    required String? relativePath,
    required String? outputTreeUri,
  }) async {
    final saveData = await _platformChannel
        .invokeMapMethod<String, dynamic>('saveOutputToSourceFolder', {
      'tempOutputPath': tempResult.outputPath,
      'relativePath': relativePath,
      'outputTreeUri': outputTreeUri,
      'displayName': _buildOutputDisplayName(),
    });

    if (saveData == null) {
      throw Exception('Could not save converted video to source folder.');
    }

    final outputUri = saveData['outputUri'] as String?;
    final outputPath = saveData['outputPath'] as String?;
    final finalLocation = outputPath ?? outputUri;
    if (finalLocation == null || finalLocation.isEmpty) {
      throw Exception('Output location was not returned by Android.');
    }

    try {
      final tempFile = File(tempResult.outputPath);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    } catch (_) {
      // Keep conversion success even if temp cleanup fails.
    }

    return ConversionResult(
      outputPath: finalLocation,
      outputSizeBytes: tempResult.outputSizeBytes,
      targetWidth: tempResult.targetWidth,
      targetHeight: tempResult.targetHeight,
      videoBitrate: tempResult.videoBitrate,
      audioBitrate: tempResult.audioBitrate,
    );
  }

  String _buildOutputDisplayName() {
    final selectedName = _selectedDisplayName;
    final baseName = selectedName == null
        ? 'video'
        : p.basenameWithoutExtension(selectedName).trim();
    final safeBaseName = baseName.isEmpty ? 'video' : baseName;
    final presetTag = _preset.name.replaceFirst('p', '');
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return '${safeBaseName}_${presetTag}p_$timestamp.mp4';
  }

  Future<_OutputFolderAccess?> _ensureOutputFolderAccess() async {
    final accessData = await _platformChannel
        .invokeMapMethod<String, dynamic>('ensureOutputFolderAccess');
    if (accessData == null) {
      return null;
    }
    final treeUri = accessData['treeUri'] as String?;
    if (treeUri == null || treeUri.trim().isEmpty) {
      return null;
    }
    return _OutputFolderAccess(
      treeUri: treeUri,
      label: accessData['label'] as String?,
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedFilePath = _selectedFilePath;
    final metadata = _metadata;
    final result = _result;
    final sourceRelativePath = _sourceRelativePath;
    final outputTreeUri = _outputTreeUri;
    final hasSourceFolder =
        (sourceRelativePath != null && sourceRelativePath.trim().isNotEmpty) ||
            (outputTreeUri != null && outputTreeUri.trim().isNotEmpty);
    final isDownscaleSelection = metadata != null &&
        _preset.targetPixels < math.min(metadata.width, metadata.height);
    final canConvert = metadata != null &&
        !_isConverting &&
        hasSourceFolder &&
        isDownscaleSelection;
    final outputFolderLabel = sourceRelativePath ?? _outputFolderLabel;
    final fileName = _selectedDisplayName ??
        (selectedFilePath == null ? null : p.basename(selectedFilePath));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Video Converter'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ElevatedButton.icon(
                onPressed: _isConverting ? null : _selectVideo,
                icon: _isPickingFile
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.video_file_outlined),
                label: const Text('Select Video'),
              ),
              const SizedBox(height: 16),
              if (metadata != null && fileName != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fileName,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Input: ${metadata.width}x${metadata.height} • ${_formatDuration(metadata.duration)} • ${_formatBytes(metadata.fileSizeBytes)}',
                        ),
                        const SizedBox(height: 4),
                        Text(
                            'Source bitrate: ${_formatBitrate(metadata.videoBitrate)}'),
                        const SizedBox(height: 4),
                        Text(
                          'Output folder: ${hasSourceFolder ? outputFolderLabel : 'Permission required'}',
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              DropdownButtonFormField<ResolutionPreset>(
                value: _preset,
                decoration: const InputDecoration(
                  labelText: 'Target resolution',
                  border: OutlineInputBorder(),
                ),
                items: ResolutionPreset.values
                    .map(
                      (preset) => DropdownMenuItem<ResolutionPreset>(
                        value: preset,
                        child: Text(preset.label),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _isConverting
                    ? null
                    : (value) {
                        if (value == null) {
                          return;
                        }
                        setState(() => _preset = value);
                      },
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: canConvert ? _convertVideo : null,
                icon: const Icon(Icons.transform),
                label: const Text('Convert'),
              ),
              if (metadata != null && !isDownscaleSelection) ...[
                const SizedBox(height: 8),
                Text(
                  'Selected target is not lower than source (${math.min(metadata.width, metadata.height)}p short edge). Choose a lower preset for size reduction.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 16),
              if (_isConverting || _progress > 0)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(
                      value: _isConverting
                          ? (_progress > 0 ? _progress : null)
                          : _progress,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isConverting
                          ? _progress > 0
                              ? '${(_progress * 100).toStringAsFixed(0)}% complete'
                              : 'Starting conversion...'
                          : '100% complete',
                    ),
                  ],
                ),
              if (_statusMessage != null) ...[
                const SizedBox(height: 16),
                Text(_statusMessage!),
              ],
              if (result != null && metadata != null) ...[
                const SizedBox(height: 16),
                _ResultCard(
                    result: result, inputSizeBytes: metadata.fileSizeBytes),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.result,
    required this.inputSizeBytes,
  });

  final ConversionResult result;
  final int inputSizeBytes;

  @override
  Widget build(BuildContext context) {
    final reductionPercent = inputSizeBytes == 0
        ? 0.0
        : ((1 - (result.outputSizeBytes / inputSizeBytes)) * 100);
    final reductionLabel = reductionPercent > 0
        ? '${reductionPercent.toStringAsFixed(1)}% smaller'
        : 'Output may be larger than input';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Output ready',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text('Path: ${result.outputPath}'),
            const SizedBox(height: 4),
            Text(
              'Resolution: ${result.targetWidth}x${result.targetHeight} • Video bitrate: ${_formatBitrate(result.videoBitrate)}',
            ),
            const SizedBox(height: 4),
            Text(
                'Size: ${_formatBytes(result.outputSizeBytes)} ($reductionLabel)'),
          ],
        ),
      ),
    );
  }
}

String _formatDuration(Duration duration) {
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  final hours = duration.inHours;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  const suffixes = ['KB', 'MB', 'GB', 'TB'];
  double value = bytes / 1024;
  int suffixIndex = 0;
  while (value >= 1024 && suffixIndex < suffixes.length - 1) {
    value /= 1024;
    suffixIndex++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${suffixes[suffixIndex]}';
}

String _formatBitrate(int bitsPerSecond) {
  final kbps = bitsPerSecond / 1000;
  if (kbps < 1000) {
    return '${kbps.toStringAsFixed(0)} kbps';
  }
  final mbps = kbps / 1000;
  return '${mbps.toStringAsFixed(2)} Mbps';
}

class _OutputFolderAccess {
  const _OutputFolderAccess({
    required this.treeUri,
    required this.label,
  });

  final String treeUri;
  final String? label;
}
