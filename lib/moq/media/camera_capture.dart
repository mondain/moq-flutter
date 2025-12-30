import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:logger/logger.dart';
import 'audio_capture.dart';
import 'native_capture_channel.dart';

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
class CameraCapture implements VideoCapture {
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

  @override
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

  @override
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

  @override
  Stream<VideoFrame> get videoFrames => _videoFrameController.stream;

  @override
  Stream<AudioSamples>? get audioSamples => _audioCapture?.audioStream;

  /// Get the audio capture instance (for direct access)
  AudioCapture? get audioCapture => _audioCapture;

  /// Get camera preview widget (for UI)
  CameraController? get cameraController => _cameraController;

  @override
  bool get isCapturing => _isCapturing;

  @override
  void dispose() {
    stopCapture();
    _cameraController?.dispose();
    _audioCapture?.dispose();
    _videoFrameController.close();
  }

  /// Factory to create platform-appropriate video capture
  static Future<VideoCapture> createNative({
    CaptureConfig? config,
    Logger? logger,
  }) async {
    final cfg = config ?? const CaptureConfig();
    final log = logger ?? Logger();

    if (Platform.isIOS || Platform.isMacOS) {
      return NativeVideoCapture(config: cfg, logger: log);
    } else {
      // For other platforms, use the camera package-based CameraCapture
      final capture = CameraCapture(config: cfg, logger: log);
      await capture.initialize();
      return capture;
    }
  }
}

/// Abstract interface for video capture (allows native implementations)
abstract class VideoCapture {
  /// Stream of video frames
  Stream<VideoFrame> get videoFrames;

  /// Stream of audio samples
  Stream<AudioSamples>? get audioSamples;

  /// Whether capture is currently active
  bool get isCapturing;

  /// Start capturing
  Future<void> startCapture();

  /// Stop capturing
  Future<void> stopCapture();

  /// Dispose resources
  void dispose();
}


/// Native video capture for macOS and iOS using AVFoundation via Platform Channels
class NativeVideoCapture implements VideoCapture {
  final CaptureConfig config;
  final Logger _logger;

  final _videoFrameController = StreamController<VideoFrame>.broadcast();
  bool _isCapturing = false;
  NativeCaptureChannel? _nativeChannel;
  StreamSubscription<NativeVideoFrame>? _videoSubscription;
  bool _nativeAvailable = true;

  // Audio capture (using native channel as well)
  final _audioController = StreamController<AudioSamples>.broadcast();
  StreamSubscription<NativeAudioSamples>? _audioSubscription;

  NativeVideoCapture({
    CaptureConfig? config,
    Logger? logger,
  })  : config = config ?? const CaptureConfig(),
        _logger = logger ?? Logger();

  @override
  Stream<VideoFrame> get videoFrames => _videoFrameController.stream;

  @override
  Stream<AudioSamples>? get audioSamples =>
      config.enableAudio ? _audioController.stream : null;

  @override
  bool get isCapturing => _isCapturing;

  /// Get list of available cameras
  Future<List<NativeCameraInfo>> getAvailableCameras() async {
    _nativeChannel ??= NativeCaptureChannel(logger: _logger);
    return _nativeChannel!.getAvailableCameras();
  }

  /// Initialize with optional camera selection
  Future<void> initialize({String? cameraId}) async {
    try {
      _nativeChannel = NativeCaptureChannel(logger: _logger);

      // Request camera permission
      final hasCameraPermission = await _nativeChannel!.hasCameraPermission();
      if (!hasCameraPermission) {
        final granted = await _nativeChannel!.requestCameraPermission();
        if (!granted) {
          _logger.w('Camera permission denied');
          _nativeAvailable = false;
          return;
        }
      }

      // Request microphone permission if audio is enabled
      if (config.enableAudio) {
        final hasMicPermission = await _nativeChannel!.hasMicrophonePermission();
        if (!hasMicPermission) {
          final granted = await _nativeChannel!.requestMicrophonePermission();
          if (!granted) {
            _logger.w('Microphone permission denied');
          }
        }
      }

      // Get resolution dimensions from preset
      final (width, height) = _resolutionFromPreset(config.resolution);

      await _nativeChannel!.initializeVideo(
        width: width,
        height: height,
        frameRate: 30,
        cameraId: cameraId,
      );

      if (config.enableAudio) {
        await _nativeChannel!.initializeAudio(
          sampleRate: config.audioSampleRate,
          channels: config.audioChannels,
        );
      }

      _logger.i('Native video capture initialized');
    } catch (e) {
      _logger.e('Failed to initialize native video capture: $e');
      _nativeAvailable = false;
    }
  }

  /// Select a specific camera
  Future<void> selectCamera(String cameraId) async {
    if (_nativeChannel != null) {
      await _nativeChannel!.selectCamera(cameraId);
    }
  }

  (int, int) _resolutionFromPreset(ResolutionPreset preset) {
    switch (preset) {
      case ResolutionPreset.low:
        return (320, 240);
      case ResolutionPreset.medium:
        return (720, 480);
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

    if (!_nativeAvailable || _nativeChannel == null) {
      _logger.e('Native video capture not available');
      return;
    }

    _isCapturing = true;

    try {
      // Subscribe to video stream
      _videoSubscription = _nativeChannel!.videoStream.listen(
        _onVideoFrame,
        onError: (error) {
          _logger.e('Native video stream error: $error');
        },
      );

      await _nativeChannel!.startVideoCapture();
      _logger.i('Native video capture started');

      // Start audio if enabled
      if (config.enableAudio) {
        _audioSubscription = _nativeChannel!.audioStream.listen(
          _onAudioSamples,
          onError: (error) {
            _logger.e('Native audio stream error: $error');
          },
        );

        await _nativeChannel!.startAudioCapture();
        _logger.i('Native audio capture started');
      }
    } catch (e) {
      _logger.e('Failed to start native capture: $e');
      _isCapturing = false;
      rethrow;
    }
  }

  void _onVideoFrame(NativeVideoFrame nativeFrame) {
    if (!_isCapturing) return;

    final frame = VideoFrame(
      data: nativeFrame.data,
      width: nativeFrame.width,
      height: nativeFrame.height,
      timestampMs: nativeFrame.timestampMs,
      format: nativeFrame.format,
    );

    _videoFrameController.add(frame);
  }

  void _onAudioSamples(NativeAudioSamples nativeSamples) {
    if (!_isCapturing) return;

    final samples = AudioSamples(
      data: nativeSamples.data,
      sampleRate: nativeSamples.sampleRate,
      channels: nativeSamples.channels,
      timestampMs: nativeSamples.timestampMs,
      bitsPerSample: nativeSamples.bitsPerSample,
    );

    _audioController.add(samples);
  }

  @override
  Future<void> stopCapture() async {
    if (!_isCapturing) return;

    _isCapturing = false;

    await _videoSubscription?.cancel();
    _videoSubscription = null;

    await _audioSubscription?.cancel();
    _audioSubscription = null;

    if (_nativeChannel != null) {
      try {
        await _nativeChannel!.stopVideoCapture();
        if (config.enableAudio) {
          await _nativeChannel!.stopAudioCapture();
        }
      } catch (e) {
        _logger.w('Error stopping native capture: $e');
      }
    }

    _logger.i('Native video capture stopped');
  }

  @override
  void dispose() {
    stopCapture();
    _nativeChannel?.dispose();
    _videoFrameController.close();
    _audioController.close();
  }
}
