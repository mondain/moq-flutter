import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:logger/logger.dart';

/// H.264 encoder configuration
class H264EncoderConfig {
  /// Output width
  final int width;

  /// Output height
  final int height;

  /// Frame rate
  final int frameRate;

  /// Bitrate in bits per second
  final int bitrate;

  /// Keyframe interval (GOP size) in frames
  final int gopSize;

  /// H.264 profile: 'baseline', 'main', 'high'
  final String profile;

  /// H.264 level (e.g., '3.1', '4.0', '4.1')
  final String level;

  /// Encoding preset: 'ultrafast', 'superfast', 'veryfast', 'faster', 'fast', 'medium'
  final String preset;

  /// Tune option: 'zerolatency', 'film', 'animation', etc.
  final String tune;

  /// Input pixel format
  final String inputFormat;

  const H264EncoderConfig({
    this.width = 1280,
    this.height = 720,
    this.frameRate = 30,
    this.bitrate = 2000000,
    this.gopSize = 30,
    this.profile = 'baseline',
    this.level = '3.1',
    this.preset = 'ultrafast',
    this.tune = 'zerolatency',
    this.inputFormat = 'yuv420p',
  });

  /// Low latency configuration for real-time streaming
  static const lowLatency = H264EncoderConfig(
    width: 1280,
    height: 720,
    frameRate: 30,
    bitrate: 2000000,
    gopSize: 30,
    profile: 'baseline',
    level: '3.1',
    preset: 'ultrafast',
    tune: 'zerolatency',
    inputFormat: 'yuv420p',
  );

  /// Higher quality configuration
  static const highQuality = H264EncoderConfig(
    width: 1920,
    height: 1080,
    frameRate: 30,
    bitrate: 5000000,
    gopSize: 60,
    profile: 'high',
    level: '4.1',
    preset: 'fast',
    tune: 'zerolatency',
    inputFormat: 'yuv420p',
  );
}

/// Encoded H.264 frame (NAL unit)
class H264Frame {
  /// Encoded H.264 data (may contain multiple NAL units)
  final Uint8List data;

  /// Whether this is a keyframe (IDR)
  final bool isKeyframe;

  /// Timestamp in milliseconds
  final int timestampMs;

  /// Frame sequence number
  final int sequenceNumber;

  /// Frame type description
  final String frameType;

  H264Frame({
    required this.data,
    required this.isKeyframe,
    required this.timestampMs,
    required this.sequenceNumber,
    this.frameType = 'P',
  });
}

/// H.264 video encoder using FFmpeg
///
/// Encodes raw video frames to H.264/AVC using FFmpeg as an external process.
/// Outputs Annex B NAL units suitable for streaming.
class H264Encoder {
  final H264EncoderConfig config;
  final Logger _logger;

  Process? _ffmpegProcess;
  final _frameController = StreamController<H264Frame>.broadcast();
  bool _isRunning = false;

  // Frame tracking
  int _sequenceNumber = 0;
  int _currentTimestampMs = 0;

  // Output buffer for parsing NAL units
  final _outputBuffer = BytesBuilder();

  // SPS/PPS data for decoder initialization
  Uint8List? _spsData;
  Uint8List? _ppsData;

  H264Encoder({
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

  /// Start the encoder
  Future<void> start() async {
    if (_isRunning) {
      _logger.w('H.264 encoder already running');
      return;
    }

    _isRunning = true;
    _sequenceNumber = 0;
    _currentTimestampMs = 0;
    _outputBuffer.clear();

    await _startFFmpegProcess();
    _logger.i('H.264 encoder started (${config.width}x${config.height}@${config.frameRate}fps, ${config.bitrate ~/ 1000}kbps)');
  }

  Future<void> _startFFmpegProcess() async {
    // FFmpeg command to encode raw video to H.264
    // Input: raw video frames from stdin
    // Output: H.264 Annex B stream to stdout
    final args = [
      '-hide_banner',
      '-loglevel', 'error',
      // Input format
      '-f', 'rawvideo',
      '-pixel_format', config.inputFormat,
      '-video_size', '${config.width}x${config.height}',
      '-framerate', config.frameRate.toString(),
      '-i', 'pipe:0', // Read from stdin
      // H.264 encoding options
      '-c:v', 'libx264',
      '-preset', config.preset,
      '-tune', config.tune,
      '-profile:v', config.profile,
      '-level:v', config.level,
      '-b:v', config.bitrate.toString(),
      '-maxrate', config.bitrate.toString(),
      '-bufsize', (config.bitrate ~/ 2).toString(),
      '-g', config.gopSize.toString(), // GOP size
      '-keyint_min', config.gopSize.toString(),
      '-sc_threshold', '0', // Disable scene change detection
      '-bf', '0', // No B-frames for lower latency
      '-refs', '1', // Single reference frame
      '-rc-lookahead', '0', // No lookahead
      '-forced-idr', '1', // Force IDR keyframes
      // Output format - raw H.264 Annex B
      '-f', 'h264',
      '-bsf:v', 'h264_mp4toannexb', // Ensure Annex B format
      'pipe:1', // Write to stdout
    ];

    try {
      _ffmpegProcess = await Process.start('ffmpeg', args);

      // Handle stderr (errors)
      _ffmpegProcess!.stderr.listen((data) {
        final msg = String.fromCharCodes(data).trim();
        if (msg.isNotEmpty) {
          _logger.w('FFmpeg H.264: $msg');
        }
      });

      // Handle stdout (encoded data)
      _ffmpegProcess!.stdout.listen(
        (List<int> data) => _onEncodedData(Uint8List.fromList(data)),
        onError: (error) {
          _logger.e('FFmpeg output error: $error');
        },
        onDone: () {
          _logger.d('FFmpeg output stream closed');
        },
      );

      _logger.d('FFmpeg H.264 encoder process started');
    } catch (e) {
      _isRunning = false;
      _logger.e('Failed to start FFmpeg: $e');
      rethrow;
    }
  }

  /// Add a raw video frame to encode
  ///
  /// [frameData] should be raw pixel data in the configured input format
  /// [timestampMs] is the presentation timestamp in milliseconds
  Future<void> addFrame(Uint8List frameData, int timestampMs) async {
    if (!_isRunning || _ffmpegProcess == null) return;

    _currentTimestampMs = timestampMs;

    try {
      _ffmpegProcess!.stdin.add(frameData);
    } catch (e) {
      _logger.e('Error writing frame to FFmpeg: $e');
    }
  }

  void _onEncodedData(Uint8List data) {
    // Accumulate output data
    _outputBuffer.add(data);

    // Try to extract NAL units
    _extractNalUnits();
  }

  void _extractNalUnits() {
    final buffer = _outputBuffer.takeBytes();
    if (buffer.length < 4) {
      _outputBuffer.add(buffer);
      return;
    }

    // Find NAL unit start codes (0x00 0x00 0x00 0x01 or 0x00 0x00 0x01)
    final nalUnits = <Uint8List>[];
    int start = -1;

    for (var i = 0; i < buffer.length - 3; i++) {
      bool isStartCode = false;
      int startCodeLen = 0;

      // Check for 4-byte start code
      if (i + 3 < buffer.length &&
          buffer[i] == 0x00 &&
          buffer[i + 1] == 0x00 &&
          buffer[i + 2] == 0x00 &&
          buffer[i + 3] == 0x01) {
        isStartCode = true;
        startCodeLen = 4;
      }
      // Check for 3-byte start code
      else if (buffer[i] == 0x00 &&
          buffer[i + 1] == 0x00 &&
          buffer[i + 2] == 0x01) {
        isStartCode = true;
        startCodeLen = 3;
      }

      if (isStartCode) {
        if (start >= 0) {
          // Extract previous NAL unit
          nalUnits.add(Uint8List.sublistView(buffer, start, i));
        }
        start = i;
        i += startCodeLen - 1;
      }
    }

    // Handle remaining data
    if (start >= 0 && start < buffer.length) {
      // Check if we have a complete NAL unit or need to buffer more
      final remaining = Uint8List.sublistView(buffer, start);

      // If we have at least one complete NAL unit, process it
      if (nalUnits.isNotEmpty) {
        for (final nalUnit in nalUnits) {
          _processNalUnit(nalUnit);
        }
        // Keep remaining data in buffer
        _outputBuffer.add(remaining);
      } else {
        // No complete NAL units yet, keep buffering
        _outputBuffer.add(buffer);
      }
    } else if (nalUnits.isNotEmpty) {
      for (final nalUnit in nalUnits) {
        _processNalUnit(nalUnit);
      }
    }
  }

  void _processNalUnit(Uint8List nalUnit) {
    if (nalUnit.length < 4) return;

    // Find the NAL unit type (after start code)
    int nalTypeOffset = 3;
    if (nalUnit[0] == 0x00 && nalUnit[1] == 0x00 && nalUnit[2] == 0x00 && nalUnit[3] == 0x01) {
      nalTypeOffset = 4;
    } else if (nalUnit[0] == 0x00 && nalUnit[1] == 0x00 && nalUnit[2] == 0x01) {
      nalTypeOffset = 3;
    }

    if (nalTypeOffset >= nalUnit.length) return;

    final nalType = nalUnit[nalTypeOffset] & 0x1F;
    String frameType;
    bool isKeyframe = false;

    switch (nalType) {
      case 1: // Non-IDR slice
        frameType = 'P';
        break;
      case 5: // IDR slice
        frameType = 'I';
        isKeyframe = true;
        break;
      case 6: // SEI
        frameType = 'SEI';
        return; // Skip SEI for now
      case 7: // SPS
        frameType = 'SPS';
        _spsData = Uint8List.fromList(nalUnit);
        _logger.d('Captured SPS (${nalUnit.length} bytes)');
        return; // Don't emit SPS as a frame
      case 8: // PPS
        frameType = 'PPS';
        _ppsData = Uint8List.fromList(nalUnit);
        _logger.d('Captured PPS (${nalUnit.length} bytes)');
        return; // Don't emit PPS as a frame
      case 9: // AUD (Access Unit Delimiter)
        return; // Skip AUD
      default:
        frameType = 'NAL-$nalType';
    }

    // For keyframes, prepend SPS/PPS if available
    Uint8List frameData;
    if (isKeyframe && _spsData != null && _ppsData != null) {
      // Combine SPS + PPS + IDR slice
      frameData = Uint8List(_spsData!.length + _ppsData!.length + nalUnit.length);
      frameData.setAll(0, _spsData!);
      frameData.setAll(_spsData!.length, _ppsData!);
      frameData.setAll(_spsData!.length + _ppsData!.length, nalUnit);
    } else {
      frameData = Uint8List.fromList(nalUnit);
    }

    // Emit frame
    final frame = H264Frame(
      data: frameData,
      isKeyframe: isKeyframe,
      timestampMs: _currentTimestampMs,
      sequenceNumber: _sequenceNumber++,
      frameType: frameType,
    );

    _frameController.add(frame);
  }

  /// Flush any remaining buffered data
  Future<void> flush() async {
    if (!_isRunning || _ffmpegProcess == null) return;

    try {
      await _ffmpegProcess!.stdin.flush();
    } catch (e) {
      _logger.w('Error flushing to FFmpeg: $e');
    }
  }

  /// Stop the encoder
  Future<void> stop() async {
    if (!_isRunning) return;

    _isRunning = false;

    // Flush remaining data
    await flush();

    // Close stdin to signal end of input
    if (_ffmpegProcess != null) {
      try {
        await _ffmpegProcess!.stdin.close();
        // Wait for process to finish
        await _ffmpegProcess!.exitCode.timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            _ffmpegProcess!.kill();
            return -1;
          },
        );
      } catch (e) {
        _logger.w('Error closing FFmpeg: $e');
        _ffmpegProcess?.kill();
      }
      _ffmpegProcess = null;
    }

    _logger.i('H.264 encoder stopped (encoded $_sequenceNumber frames)');
  }

  /// Dispose resources
  void dispose() {
    stop();
    _frameController.close();
  }
}

/// Simple passthrough encoder for testing (no actual encoding)
class StubH264Encoder {
  final H264EncoderConfig config;
  final Logger _logger;

  final _frameController = StreamController<H264Frame>.broadcast();
  bool _isRunning = false;
  int _sequenceNumber = 0;
  int _frameCount = 0;

  StubH264Encoder({
    H264EncoderConfig? config,
    Logger? logger,
  })  : config = config ?? H264EncoderConfig.lowLatency,
        _logger = logger ?? Logger();

  Stream<H264Frame> get frames => _frameController.stream;
  bool get isRunning => _isRunning;

  Future<void> start() async {
    _isRunning = true;
    _sequenceNumber = 0;
    _frameCount = 0;
    _logger.i('Stub H.264 encoder started');
  }

  Future<void> addFrame(Uint8List frameData, int timestampMs) async {
    if (!_isRunning) return;

    _frameCount++;
    final isKeyframe = _frameCount % config.gopSize == 1;

    final frame = H264Frame(
      data: frameData,
      isKeyframe: isKeyframe,
      timestampMs: timestampMs,
      sequenceNumber: _sequenceNumber++,
      frameType: isKeyframe ? 'I' : 'P',
    );

    _frameController.add(frame);
  }

  Future<void> stop() async {
    _isRunning = false;
    _logger.i('Stub H.264 encoder stopped');
  }

  void dispose() {
    stop();
    _frameController.close();
  }
}
