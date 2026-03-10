import 'dart:async';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import 'video_encoder.dart';

/// Native H.264 encoder using platform VideoToolbox (macOS/iOS) via platform channels.
/// Avoids FFmpeg subprocess and works within the macOS sandbox.
class NativeH264Encoder {
  static const MethodChannel _methodChannel =
      MethodChannel('com.moq_flutter/native_capture');
  static const EventChannel _h264EventChannel =
      EventChannel('com.moq_flutter/h264_frames');

  final H264EncoderConfig config;
  final Logger _logger;

  final _frameController = StreamController<H264Frame>.broadcast();
  StreamSubscription<dynamic>? _h264Subscription;
  bool _isRunning = false;
  int _sequenceNumber = 0;

  // SPS/PPS extracted from keyframes
  Uint8List? _spsData;
  Uint8List? _ppsData;

  NativeH264Encoder({
    H264EncoderConfig? config,
    Logger? logger,
  })  : config = config ?? H264EncoderConfig.lowLatency,
        _logger = logger ?? Logger();

  /// Stream of encoded H.264 frames
  Stream<H264Frame> get frames => _frameController.stream;

  /// Whether the encoder is running
  bool get isRunning => _isRunning;

  /// Get SPS data (available after first keyframe)
  Uint8List? get spsData => _spsData;

  /// Get PPS data (available after first keyframe)
  Uint8List? get ppsData => _ppsData;

  /// Initialize and start the native H.264 encoder
  Future<void> start() async {
    if (_isRunning) {
      _logger.w('Native H.264 encoder already running');
      return;
    }

    _sequenceNumber = 0;

    // Subscribe to encoded frames from native side
    _h264Subscription = _h264EventChannel
        .receiveBroadcastStream()
        .listen(_onH264Data, onError: _onH264Error);

    // Initialize the VideoToolbox encoder
    await _methodChannel.invokeMethod('initializeH264Encoder', {
      'width': config.width,
      'height': config.height,
      'bitrate': config.bitrate,
      'gopSize': config.gopSize,
      'frameRate': config.frameRate,
    });

    await _methodChannel.invokeMethod('startH264Encoding');

    _isRunning = true;
    _logger.i('Native H.264 encoder started '
        '(${config.width}x${config.height}@${config.frameRate}fps, '
        '${config.bitrate ~/ 1000}kbps, VideoToolbox)');
  }

  void _onH264Data(dynamic data) {
    if (data is! Map) {
      _logger.w('Invalid H.264 data format');
      return;
    }

    try {
      final map = Map<String, dynamic>.from(data);
      final frameData = map['data'] is Uint8List
          ? map['data'] as Uint8List
          : Uint8List.fromList(List<int>.from(map['data']));
      final isKeyframe = map['isKeyframe'] as bool? ?? false;
      final timestampMs = map['timestampMs'] as int? ?? 0;

      // Extract SPS/PPS from keyframes
      if (isKeyframe) {
        _extractParameterSets(frameData);
      }

      final frame = H264Frame(
        data: frameData,
        isKeyframe: isKeyframe,
        timestampMs: timestampMs,
        sequenceNumber: _sequenceNumber++,
        frameType: isKeyframe ? 'I' : 'P',
      );

      _frameController.add(frame);
    } catch (e) {
      _logger.e('Error parsing H.264 data: $e');
    }
  }

  /// Extract SPS and PPS NAL units from an Annex B stream
  void _extractParameterSets(Uint8List data) {
    int i = 0;
    while (i < data.length - 4) {
      // Find start code
      if (data[i] == 0x00 && data[i + 1] == 0x00 &&
          data[i + 2] == 0x00 && data[i + 3] == 0x01) {
        final nalTypeOffset = i + 4;
        if (nalTypeOffset >= data.length) break;
        final nalType = data[nalTypeOffset] & 0x1F;

        // Find next start code to determine NAL unit boundary
        int end = data.length;
        for (int j = nalTypeOffset + 1; j < data.length - 3; j++) {
          if (data[j] == 0x00 && data[j + 1] == 0x00 &&
              data[j + 2] == 0x00 && data[j + 3] == 0x01) {
            end = j;
            break;
          }
        }

        if (nalType == 7) {
          // SPS - include start code
          _spsData = Uint8List.sublistView(data, i, end);
        } else if (nalType == 8) {
          // PPS - include start code
          _ppsData = Uint8List.sublistView(data, i, end);
        }

        i = end;
      } else {
        i++;
      }
    }
  }

  void _onH264Error(dynamic error) {
    _logger.e('H.264 stream error: $error');
  }

  /// Stop the encoder
  Future<void> stop() async {
    if (!_isRunning) return;

    _isRunning = false;

    try {
      await _methodChannel.invokeMethod('stopH264Encoding');
    } catch (e) {
      _logger.w('Error stopping H.264 encoder: $e');
    }

    await _h264Subscription?.cancel();
    _h264Subscription = null;

    _logger.i('Native H.264 encoder stopped (encoded $_sequenceNumber frames)');
  }

  /// Dispose resources
  void dispose() {
    stop();
    _frameController.close();
  }
}
