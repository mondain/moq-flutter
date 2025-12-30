import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:logger/logger.dart';
import 'audio_capture.dart';

// Re-export AudioSamples from audio_capture.dart
export 'audio_capture.dart' show AudioSamples, AudioCaptureConfig;

/// Raw video frame from camera
class VideoFrame {
  final Uint8List data;
  final int width;
  final int height;
  final int timestampMs;
  final String format; // e.g., 'yuv420', 'nv21', 'bgra8888'

  VideoFrame({
    required this.data,
    required this.width,
    required this.height,
    required this.timestampMs,
    required this.format,
  });
}

/// Camera capture configuration
class CaptureConfig {
  final ResolutionPreset resolution;
  final bool enableAudio;
  final int audioSampleRate;
  final int audioChannels;

  const CaptureConfig({
    this.resolution = ResolutionPreset.high,
    this.enableAudio = true,
    this.audioSampleRate = 48000,
    this.audioChannels = 2,
  });
}

/// Camera and audio capture for MoQ publishing
///
/// Uses platform-specific audio capture:
/// - Android/iOS: audio_streamer package
/// - Linux: PulseAudio via parec
/// - macOS/Windows: Stub (silence) - native capture not yet implemented
class CameraCapture {
  final CaptureConfig config;
  final Logger _logger;

  CameraController? _cameraController;
  List<CameraDescription>? _cameras;

  final _videoFrameController = StreamController<VideoFrame>.broadcast();

  bool _isCapturing = false;
  int _startTimeMs = 0;

  // Platform-specific audio capture
  AudioCapture? _audioCapture;

  CameraCapture({
    CaptureConfig? config,
    Logger? logger,
  })  : config = config ?? const CaptureConfig(),
        _logger = logger ?? Logger();

  /// Get available cameras
  Future<List<CameraDescription>> getAvailableCameras() async {
    _cameras ??= await availableCameras();
    return _cameras!;
  }

  /// Initialize capture with specified camera
  Future<void> initialize({CameraDescription? camera}) async {
    final cameras = await getAvailableCameras();
    if (cameras.isEmpty) {
      throw StateError('No cameras available');
    }

    // Use specified camera or default to first (usually back camera)
    final selectedCamera = camera ?? cameras.first;

    _cameraController = CameraController(
      selectedCamera,
      config.resolution,
      enableAudio: false, // We handle audio separately
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _cameraController!.initialize();
    _logger.i('Camera initialized: ${selectedCamera.name}');

    // Initialize platform-specific audio capture
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
  }

  /// Start capturing video and audio
  Future<void> startCapture() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      throw StateError('Camera not initialized');
    }

    if (_isCapturing) {
      _logger.w('Already capturing');
      return;
    }

    _isCapturing = true;
    _startTimeMs = DateTime.now().millisecondsSinceEpoch;

    // Start video frame streaming
    await _cameraController!.startImageStream(_onVideoFrame);
    _logger.i('Video capture started');

    // Start platform-specific audio capture
    if (config.enableAudio && _audioCapture != null) {
      await _audioCapture!.startCapture();
    }
  }

  /// Stop capturing
  Future<void> stopCapture() async {
    if (!_isCapturing) return;

    _isCapturing = false;

    // Stop video streaming
    if (_cameraController != null && _cameraController!.value.isStreamingImages) {
      await _cameraController!.stopImageStream();
    }
    _logger.i('Video capture stopped');

    // Stop audio capture
    if (_audioCapture != null) {
      await _audioCapture!.stopCapture();
    }
    _logger.i('Audio capture stopped');
  }

  void _onVideoFrame(CameraImage image) {
    if (!_isCapturing) return;

    final timestampMs = DateTime.now().millisecondsSinceEpoch - _startTimeMs;

    // Convert CameraImage to raw bytes
    Uint8List frameData;
    String format;

    if (image.format.group == ImageFormatGroup.yuv420) {
      frameData = _convertYuv420(image);
      format = 'yuv420';
    } else if (image.format.group == ImageFormatGroup.bgra8888) {
      frameData = image.planes.first.bytes;
      format = 'bgra8888';
    } else {
      final totalBytes = image.planes.fold<int>(0, (sum, p) => sum + p.bytes.length);
      frameData = Uint8List(totalBytes);
      int offset = 0;
      for (final plane in image.planes) {
        frameData.setAll(offset, plane.bytes);
        offset += plane.bytes.length;
      }
      format = 'unknown';
    }

    final frame = VideoFrame(
      data: frameData,
      width: image.width,
      height: image.height,
      timestampMs: timestampMs,
      format: format,
    );

    _videoFrameController.add(frame);
  }

  Uint8List _convertYuv420(CameraImage image) {
    final y = image.planes[0].bytes;
    final u = image.planes[1].bytes;
    final v = image.planes[2].bytes;

    final result = Uint8List(y.length + u.length + v.length);
    result.setAll(0, y);
    result.setAll(y.length, u);
    result.setAll(y.length + u.length, v);

    return result;
  }

  /// Stream of video frames
  Stream<VideoFrame> get videoFrames => _videoFrameController.stream;

  /// Stream of audio samples from platform-specific capture
  Stream<AudioSamples>? get audioSamples => _audioCapture?.audioStream;

  /// Get the audio capture instance (for direct access)
  AudioCapture? get audioCapture => _audioCapture;

  /// Get camera preview widget (for UI)
  CameraController? get cameraController => _cameraController;

  /// Check if capturing
  bool get isCapturing => _isCapturing;

  /// Dispose resources
  void dispose() {
    stopCapture();
    _cameraController?.dispose();
    _audioCapture?.dispose();
    _videoFrameController.close();
  }
}
