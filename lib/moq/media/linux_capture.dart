import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:camera/camera.dart' show ResolutionPreset;
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'camera_capture.dart';
import 'audio_capture.dart';

/// Converts YUV420P frame data to RGBA for display
/// This is done in an isolate to avoid blocking the UI thread
class Yuv420ToRgbaConverter {
  /// Convert YUV420P to RGBA bytes
  /// YUV420P layout: Y plane (width*height), U plane (width*height/4), V plane (width*height/4)
  static Uint8List convert(Uint8List yuv420p, int width, int height) {
    final ySize = width * height;
    final uvSize = ySize ~/ 4;

    // Validate input size
    final expectedSize = ySize + uvSize * 2;
    if (yuv420p.length < expectedSize) {
      throw ArgumentError('YUV420P data too small: ${yuv420p.length} < $expectedSize');
    }

    final rgba = Uint8List(width * height * 4);

    final yPlane = yuv420p;
    final uOffset = ySize;
    final vOffset = ySize + uvSize;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final yIndex = y * width + x;
        final uvIndex = (y ~/ 2) * (width ~/ 2) + (x ~/ 2);

        final yValue = yPlane[yIndex];
        final uValue = yuv420p[uOffset + uvIndex] - 128;
        final vValue = yuv420p[vOffset + uvIndex] - 128;

        // YUV to RGB conversion (BT.601)
        int r = (yValue + 1.402 * vValue).round().clamp(0, 255);
        int g = (yValue - 0.344 * uValue - 0.714 * vValue).round().clamp(0, 255);
        int b = (yValue + 1.772 * uValue).round().clamp(0, 255);

        final rgbaIndex = yIndex * 4;
        rgba[rgbaIndex] = r;
        rgba[rgbaIndex + 1] = g;
        rgba[rgbaIndex + 2] = b;
        rgba[rgbaIndex + 3] = 255; // Alpha
      }
    }

    return rgba;
  }

  /// Convert in an isolate for better performance
  static Future<Uint8List> convertAsync(Uint8List yuv420p, int width, int height) {
    return compute(_convertInIsolate, _ConvertParams(yuv420p, width, height));
  }

  static Uint8List _convertInIsolate(_ConvertParams params) {
    return convert(params.yuv420p, params.width, params.height);
  }
}

class _ConvertParams {
  final Uint8List yuv420p;
  final int width;
  final int height;

  _ConvertParams(this.yuv420p, this.width, this.height);
}

/// Represents an RGBA frame for preview display
class PreviewFrame {
  final Uint8List rgbaData;
  final int width;
  final int height;
  final int timestampMs;

  PreviewFrame({
    required this.rgbaData,
    required this.width,
    required this.height,
    required this.timestampMs,
  });

  /// Create a Flutter Image from this frame
  Future<ui.Image> toImage() async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgbaData,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }
}

/// Information about a V4L2 camera device
class LinuxCameraInfo {
  final String devicePath;
  final String name;
  final String driver;
  final String busInfo;

  LinuxCameraInfo({
    required this.devicePath,
    required this.name,
    required this.driver,
    required this.busInfo,
  });

  @override
  String toString() => '$name ($devicePath)';
}

/// Linux video capture using FFmpeg with V4L2 input
///
/// Captures raw video frames from a webcam using FFmpeg's v4l2 input.
/// Outputs YUV420P frames suitable for H.264 encoding.
/// Also provides RGBA preview frames for UI display.
class LinuxVideoCapture implements VideoCapture {
  final CaptureConfig config;
  final Logger _logger;

  final _videoFrameController = StreamController<VideoFrame>.broadcast();
  final _previewFrameController = StreamController<PreviewFrame>.broadcast();
  bool _isCapturing = false;
  int _startTimeMs = 0;

  // FFmpeg process for video capture
  Process? _ffmpegProcess;
  String _selectedDevice = '/dev/video0';

  // Frame buffer for parsing FFmpeg output
  Uint8List? _frameBuffer;
  int _frameBufferOffset = 0;
  int _expectedFrameSize = 0;

  // Preview frame generation
  int _frameCount = 0;
  static const int _previewFrameInterval = 3; // Convert every Nth frame for preview
  bool _isConvertingPreview = false;

  // Audio capture
  AudioCapture? _audioCapture;

  LinuxVideoCapture({
    CaptureConfig? config,
    Logger? logger,
  })  : config = config ?? const CaptureConfig(),
        _logger = logger ?? Logger();

  @override
  Stream<VideoFrame> get videoFrames => _videoFrameController.stream;

  /// Stream of RGBA preview frames for UI display
  Stream<PreviewFrame> get previewFrames => _previewFrameController.stream;

  @override
  Stream<AudioSamples>? get audioSamples => _audioCapture?.audioStream;

  @override
  bool get isCapturing => _isCapturing;

  /// Get list of available V4L2 video devices
  static Future<List<LinuxCameraInfo>> getAvailableCameras({Logger? logger}) async {
    final cameras = <LinuxCameraInfo>[];
    final log = logger ?? Logger();

    try {
      // Find all video devices
      final videoDir = Directory('/dev');
      await for (final entity in videoDir.list()) {
        if (entity is File && entity.path.contains('/dev/video')) {
          final devicePath = entity.path;

          // Try to get device info using v4l2-ctl
          try {
            final result = await Process.run('v4l2-ctl', [
              '--device=$devicePath',
              '--all',
            ]);

            if (result.exitCode == 0) {
              final output = result.stdout as String;
              String name = devicePath;
              String driver = 'v4l2';
              String busInfo = '';

              // Parse device info
              for (final line in output.split('\n')) {
                if (line.contains('Card type')) {
                  name = line.split(':').last.trim();
                } else if (line.contains('Driver name')) {
                  driver = line.split(':').last.trim();
                } else if (line.contains('Bus info')) {
                  busInfo = line.split(':').last.trim();
                }
              }

              cameras.add(LinuxCameraInfo(
                devicePath: devicePath,
                name: name,
                driver: driver,
                busInfo: busInfo,
              ));
            }
          } catch (e) {
            // Device exists but can't query details
            cameras.add(LinuxCameraInfo(
              devicePath: devicePath,
              name: 'Video Device ${devicePath.split('/').last}',
              driver: 'unknown',
              busInfo: '',
            ));
          }
        }
      }
    } catch (e) {
      log.w('Error enumerating video devices: $e');
    }

    // Sort by device path
    cameras.sort((a, b) => a.devicePath.compareTo(b.devicePath));
    return cameras;
  }

  /// Initialize video capture with optional device selection
  Future<void> initialize({String? devicePath}) async {
    if (devicePath != null) {
      _selectedDevice = devicePath;
    }

    // Calculate expected frame size for YUV420P
    final (width, height) = _resolutionFromPreset(config.resolution);
    _expectedFrameSize = width * height * 3 ~/ 2; // YUV420P: Y + U/4 + V/4
    _frameBuffer = Uint8List(_expectedFrameSize);
    _frameBufferOffset = 0;

    // Check if FFmpeg is available
    try {
      final result = await Process.run('which', ['ffmpeg']);
      if (result.exitCode != 0) {
        throw StateError('FFmpeg not found. Install with: sudo apt install ffmpeg');
      }
    } catch (e) {
      throw StateError('Failed to check FFmpeg availability: $e');
    }

    // Check if selected device exists
    if (!await File(_selectedDevice).exists()) {
      _logger.w('Video device $_selectedDevice not found');

      // Try to find an alternative
      final cameras = await getAvailableCameras(logger: _logger);
      if (cameras.isNotEmpty) {
        _selectedDevice = cameras.first.devicePath;
        _logger.i('Using alternative device: $_selectedDevice');
      } else {
        throw StateError('No video devices found');
      }
    }

    // Initialize audio capture if enabled
    if (config.enableAudio) {
      _audioCapture = AudioCapture(
        config: AudioCaptureConfig(
          sampleRate: config.audioSampleRate,
          channels: config.audioChannels,
        ),
        logger: _logger,
      );
      await _audioCapture!.initialize();
    }

    _logger.i('Linux video capture initialized: $_selectedDevice');
  }

  /// Select a specific camera device
  Future<void> selectCamera(String devicePath) async {
    if (_isCapturing) {
      throw StateError('Cannot change camera while capturing');
    }
    _selectedDevice = devicePath;
    _logger.i('Selected camera: $devicePath');
  }

  (int, int) _resolutionFromPreset(ResolutionPreset preset) {
    switch (preset) {
      case ResolutionPreset.low:
        return (320, 240);
      case ResolutionPreset.medium:
        return (640, 480);
      case ResolutionPreset.high:
        return (1280, 720);
      case ResolutionPreset.veryHigh:
        return (1920, 1080);
      case ResolutionPreset.ultraHigh:
        return (3840, 2160);
      case ResolutionPreset.max:
        return (3840, 2160);
    }
  }

  @override
  Future<void> startCapture() async {
    if (_isCapturing) {
      _logger.w('Already capturing');
      return;
    }

    _isCapturing = true;
    _startTimeMs = DateTime.now().millisecondsSinceEpoch;
    _frameBufferOffset = 0;

    final (width, height) = _resolutionFromPreset(config.resolution);

    try {
      // Start FFmpeg to capture from V4L2 and output raw YUV420P frames
      // -f v4l2: input format
      // -video_size: resolution
      // -framerate: frame rate
      // -i: input device
      // -f rawvideo: output format
      // -pix_fmt yuv420p: pixel format
      // -: output to stdout
      _ffmpegProcess = await Process.start('ffmpeg', [
        '-f', 'v4l2',
        '-video_size', '${width}x$height',
        '-framerate', '30',
        '-input_format', 'mjpeg', // Many webcams support MJPEG well
        '-i', _selectedDevice,
        '-f', 'rawvideo',
        '-pix_fmt', 'yuv420p',
        '-',
      ]);

      // Read video data from stdout
      _ffmpegProcess!.stdout.listen(
        (List<int> data) => _onVideoData(Uint8List.fromList(data)),
        onError: (error) {
          _logger.e('FFmpeg video stream error: $error');
        },
        onDone: () {
          _logger.i('FFmpeg video stream ended');
          if (_isCapturing) {
            _isCapturing = false;
          }
        },
      );

      _ffmpegProcess!.stderr.listen((data) {
        final message = String.fromCharCodes(data);
        // FFmpeg outputs progress to stderr, filter out noise
        if (message.contains('Error') || message.contains('error')) {
          _logger.w('FFmpeg: $message');
        }
      });

      _logger.i('Linux video capture started: $width x $height @ 30fps');

      // Start audio capture if enabled
      if (config.enableAudio && _audioCapture != null) {
        await _audioCapture!.startCapture();
        _logger.i('Linux audio capture started');
      }
    } catch (e) {
      _isCapturing = false;
      _logger.e('Failed to start Linux video capture: $e');
      rethrow;
    }
  }

  void _onVideoData(Uint8List data) {
    if (!_isCapturing) return;

    // Accumulate data into frame buffer
    int dataOffset = 0;
    while (dataOffset < data.length) {
      final remaining = _expectedFrameSize - _frameBufferOffset;
      final toCopy = (data.length - dataOffset).clamp(0, remaining);

      _frameBuffer!.setRange(
        _frameBufferOffset,
        _frameBufferOffset + toCopy,
        data,
        dataOffset,
      );

      _frameBufferOffset += toCopy;
      dataOffset += toCopy;

      // If we have a complete frame, emit it
      if (_frameBufferOffset >= _expectedFrameSize) {
        final timestampMs = DateTime.now().millisecondsSinceEpoch - _startTimeMs;
        final (width, height) = _resolutionFromPreset(config.resolution);

        final frameData = Uint8List.fromList(_frameBuffer!);

        final frame = VideoFrame(
          data: frameData,
          width: width,
          height: height,
          timestampMs: timestampMs,
          format: 'yuv420p',
        );

        _videoFrameController.add(frame);

        // Generate preview frame every Nth frame (to reduce CPU load)
        _frameCount++;
        if (_frameCount % _previewFrameInterval == 0 && !_isConvertingPreview) {
          _isConvertingPreview = true;
          // Convert YUV420P to RGBA in an isolate
          Yuv420ToRgbaConverter.convertAsync(frameData, width, height).then((rgbaData) {
            if (_isCapturing && !_previewFrameController.isClosed) {
              _previewFrameController.add(PreviewFrame(
                rgbaData: rgbaData,
                width: width,
                height: height,
                timestampMs: timestampMs,
              ));
            }
            _isConvertingPreview = false;
          }).catchError((e) {
            _logger.w('Preview frame conversion failed: $e');
            _isConvertingPreview = false;
          });
        }

        // Reset buffer for next frame
        _frameBufferOffset = 0;
      }
    }
  }

  @override
  Future<void> stopCapture() async {
    if (!_isCapturing) return;

    _isCapturing = false;

    // Stop FFmpeg
    if (_ffmpegProcess != null) {
      _ffmpegProcess!.kill(ProcessSignal.sigterm);
      await _ffmpegProcess!.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          _ffmpegProcess!.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      _ffmpegProcess = null;
    }

    // Stop audio capture
    if (_audioCapture != null) {
      await _audioCapture!.stopCapture();
    }

    _logger.i('Linux video capture stopped');
  }

  @override
  void dispose() {
    stopCapture();
    _audioCapture?.dispose();
    _videoFrameController.close();
    _previewFrameController.close();
  }

  /// Get the audio capture instance (for direct access)
  AudioCapture? get audioCapture => _audioCapture;
}
