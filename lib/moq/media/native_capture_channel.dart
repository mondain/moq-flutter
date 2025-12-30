import 'dart:async';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';

/// Platform channel interface for native audio/video capture on macOS and iOS
class NativeCaptureChannel {
  static const MethodChannel _methodChannel =
      MethodChannel('com.moq_flutter/native_capture');
  static const EventChannel _audioEventChannel =
      EventChannel('com.moq_flutter/audio_samples');
  static const EventChannel _videoEventChannel =
      EventChannel('com.moq_flutter/video_frames');

  final Logger _logger;

  // Audio stream subscription
  StreamSubscription<dynamic>? _audioSubscription;
  final _audioController = StreamController<NativeAudioSamples>.broadcast();

  // Video stream subscription
  StreamSubscription<dynamic>? _videoSubscription;
  final _videoController = StreamController<NativeVideoFrame>.broadcast();

  // State
  bool _audioInitialized = false;
  bool _videoInitialized = false;
  bool _audioCapturing = false;
  bool _videoCapturing = false;

  NativeCaptureChannel({Logger? logger}) : _logger = logger ?? Logger();

  /// Stream of audio samples from native capture
  Stream<NativeAudioSamples> get audioStream => _audioController.stream;

  /// Stream of video frames from native capture
  Stream<NativeVideoFrame> get videoStream => _videoController.stream;

  /// Whether audio is currently capturing
  bool get isAudioCapturing => _audioCapturing;

  /// Whether video is currently capturing
  bool get isVideoCapturing => _videoCapturing;

  // ============ Audio Methods ============

  /// Initialize audio capture with specified configuration
  Future<void> initializeAudio({
    int sampleRate = 48000,
    int channels = 2,
    int bitsPerSample = 16,
  }) async {
    try {
      await _methodChannel.invokeMethod('initializeAudio', {
        'sampleRate': sampleRate,
        'channels': channels,
        'bitsPerSample': bitsPerSample,
      });
      _audioInitialized = true;
      _logger.i('Native audio capture initialized: ${sampleRate}Hz, ${channels}ch');
    } on PlatformException catch (e) {
      _logger.e('Failed to initialize audio: ${e.message}');
      rethrow;
    }
  }

  /// Start audio capture
  Future<void> startAudioCapture() async {
    if (!_audioInitialized) {
      throw StateError('Audio not initialized. Call initializeAudio first.');
    }

    if (_audioCapturing) {
      _logger.w('Audio capture already running');
      return;
    }

    try {
      // Start listening to audio event channel
      _audioSubscription = _audioEventChannel
          .receiveBroadcastStream()
          .listen(_onAudioData, onError: _onAudioError);

      await _methodChannel.invokeMethod('startAudioCapture');
      _audioCapturing = true;
      _logger.i('Native audio capture started');
    } on PlatformException catch (e) {
      _logger.e('Failed to start audio capture: ${e.message}');
      rethrow;
    }
  }

  /// Stop audio capture
  Future<void> stopAudioCapture() async {
    if (!_audioCapturing) return;

    try {
      await _methodChannel.invokeMethod('stopAudioCapture');
      await _audioSubscription?.cancel();
      _audioSubscription = null;
      _audioCapturing = false;
      _logger.i('Native audio capture stopped');
    } on PlatformException catch (e) {
      _logger.e('Failed to stop audio capture: ${e.message}');
      rethrow;
    }
  }

  void _onAudioData(dynamic data) {
    if (data is! Map) {
      _logger.w('Invalid audio data format');
      return;
    }

    try {
      final samples = NativeAudioSamples.fromMap(Map<String, dynamic>.from(data));
      _audioController.add(samples);
    } catch (e) {
      _logger.e('Error parsing audio data: $e');
    }
  }

  void _onAudioError(dynamic error) {
    _logger.e('Audio stream error: $error');
  }

  // ============ Video Methods ============

  /// Get list of available cameras
  Future<List<NativeCameraInfo>> getAvailableCameras() async {
    try {
      final result = await _methodChannel.invokeMethod('getAvailableCameras');
      if (result is! List) return [];

      return result.map((item) {
        return NativeCameraInfo.fromMap(Map<String, dynamic>.from(item));
      }).toList();
    } on PlatformException catch (e) {
      _logger.e('Failed to get cameras: ${e.message}');
      return [];
    }
  }

  /// Initialize video capture with specified configuration
  Future<void> initializeVideo({
    int width = 1280,
    int height = 720,
    int frameRate = 30,
    String? cameraId,
  }) async {
    try {
      await _methodChannel.invokeMethod('initializeVideo', {
        'width': width,
        'height': height,
        'frameRate': frameRate,
        'cameraId': cameraId,
      });
      _videoInitialized = true;
      _logger.i('Native video capture initialized: ${width}x$height@${frameRate}fps');
    } on PlatformException catch (e) {
      _logger.e('Failed to initialize video: ${e.message}');
      rethrow;
    }
  }

  /// Select a specific camera
  Future<void> selectCamera(String cameraId) async {
    try {
      await _methodChannel.invokeMethod('selectCamera', {
        'cameraId': cameraId,
      });
      _logger.i('Selected camera: $cameraId');
    } on PlatformException catch (e) {
      _logger.e('Failed to select camera: ${e.message}');
      rethrow;
    }
  }

  /// Start video capture
  Future<void> startVideoCapture() async {
    if (!_videoInitialized) {
      throw StateError('Video not initialized. Call initializeVideo first.');
    }

    if (_videoCapturing) {
      _logger.w('Video capture already running');
      return;
    }

    try {
      // Start listening to video event channel
      _videoSubscription = _videoEventChannel
          .receiveBroadcastStream()
          .listen(_onVideoData, onError: _onVideoError);

      await _methodChannel.invokeMethod('startVideoCapture');
      _videoCapturing = true;
      _logger.i('Native video capture started');
    } on PlatformException catch (e) {
      _logger.e('Failed to start video capture: ${e.message}');
      rethrow;
    }
  }

  /// Stop video capture
  Future<void> stopVideoCapture() async {
    if (!_videoCapturing) return;

    try {
      await _methodChannel.invokeMethod('stopVideoCapture');
      await _videoSubscription?.cancel();
      _videoSubscription = null;
      _videoCapturing = false;
      _logger.i('Native video capture stopped');
    } on PlatformException catch (e) {
      _logger.e('Failed to stop video capture: ${e.message}');
      rethrow;
    }
  }

  void _onVideoData(dynamic data) {
    if (data is! Map) {
      _logger.w('Invalid video data format');
      return;
    }

    try {
      final frame = NativeVideoFrame.fromMap(Map<String, dynamic>.from(data));
      _videoController.add(frame);
    } catch (e) {
      _logger.e('Error parsing video data: $e');
    }
  }

  void _onVideoError(dynamic error) {
    _logger.e('Video stream error: $error');
  }

  // ============ Permissions ============

  /// Check if camera permission is granted
  Future<bool> hasCameraPermission() async {
    try {
      final result = await _methodChannel.invokeMethod('hasCameraPermission');
      return result == true;
    } on PlatformException {
      return false;
    }
  }

  /// Check if microphone permission is granted
  Future<bool> hasMicrophonePermission() async {
    try {
      final result = await _methodChannel.invokeMethod('hasMicrophonePermission');
      return result == true;
    } on PlatformException {
      return false;
    }
  }

  /// Request camera permission
  Future<bool> requestCameraPermission() async {
    try {
      final result = await _methodChannel.invokeMethod('requestCameraPermission');
      return result == true;
    } on PlatformException catch (e) {
      _logger.e('Failed to request camera permission: ${e.message}');
      return false;
    }
  }

  /// Request microphone permission
  Future<bool> requestMicrophonePermission() async {
    try {
      final result = await _methodChannel.invokeMethod('requestMicrophonePermission');
      return result == true;
    } on PlatformException catch (e) {
      _logger.e('Failed to request microphone permission: ${e.message}');
      return false;
    }
  }

  /// Dispose resources
  void dispose() {
    stopAudioCapture();
    stopVideoCapture();
    _audioController.close();
    _videoController.close();
  }
}

/// Native audio samples from platform channel
class NativeAudioSamples {
  /// Raw PCM data
  final Uint8List data;

  /// Sample rate in Hz
  final int sampleRate;

  /// Number of channels
  final int channels;

  /// Bits per sample (usually 16)
  final int bitsPerSample;

  /// Timestamp in milliseconds
  final int timestampMs;

  NativeAudioSamples({
    required this.data,
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.timestampMs,
  });

  factory NativeAudioSamples.fromMap(Map<String, dynamic> map) {
    return NativeAudioSamples(
      data: map['data'] is Uint8List
          ? map['data'] as Uint8List
          : Uint8List.fromList(List<int>.from(map['data'])),
      sampleRate: map['sampleRate'] as int,
      channels: map['channels'] as int,
      bitsPerSample: map['bitsPerSample'] as int? ?? 16,
      timestampMs: map['timestampMs'] as int,
    );
  }

  /// Duration of this audio buffer in milliseconds
  int get durationMs {
    final bytesPerSample = bitsPerSample ~/ 8;
    final samplesCount = data.length ~/ (channels * bytesPerSample);
    return (samplesCount * 1000) ~/ sampleRate;
  }
}

/// Native video frame from platform channel
class NativeVideoFrame {
  /// Raw pixel data
  final Uint8List data;

  /// Frame width
  final int width;

  /// Frame height
  final int height;

  /// Pixel format (e.g., 'yuv420', 'nv12', 'bgra')
  final String format;

  /// Timestamp in milliseconds
  final int timestampMs;

  /// Bytes per row (stride) - may be larger than width * bytesPerPixel due to padding
  final int bytesPerRow;

  NativeVideoFrame({
    required this.data,
    required this.width,
    required this.height,
    required this.format,
    required this.timestampMs,
    this.bytesPerRow = 0,
  });

  factory NativeVideoFrame.fromMap(Map<String, dynamic> map) {
    return NativeVideoFrame(
      data: map['data'] is Uint8List
          ? map['data'] as Uint8List
          : Uint8List.fromList(List<int>.from(map['data'])),
      width: map['width'] as int,
      height: map['height'] as int,
      format: map['format'] as String? ?? 'unknown',
      timestampMs: map['timestampMs'] as int,
      bytesPerRow: map['bytesPerRow'] as int? ?? 0,
    );
  }
}

/// Camera information
class NativeCameraInfo {
  /// Unique camera identifier
  final String id;

  /// Human-readable camera name
  final String name;

  /// Camera position: 'front', 'back', 'external', or 'unknown'
  final String position;

  NativeCameraInfo({
    required this.id,
    required this.name,
    required this.position,
  });

  factory NativeCameraInfo.fromMap(Map<String, dynamic> map) {
    return NativeCameraInfo(
      id: map['id'] as String,
      name: map['name'] as String? ?? 'Camera',
      position: map['position'] as String? ?? 'unknown',
    );
  }

  @override
  String toString() => 'NativeCameraInfo(id: $id, name: $name, position: $position)';
}
