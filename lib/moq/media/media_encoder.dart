import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:logger/logger.dart';

/// Frame type for media data
enum FrameType {
  /// Keyframe (IDR frame for video, or start of audio segment)
  keyframe,

  /// Inter-frame (non-keyframe video, or continuation audio)
  delta,
}

/// Encoded media frame
class EncodedFrame {
  final Uint8List data;
  final FrameType type;
  final int timestampMs;
  final String trackType; // 'video' or 'audio'
  final int? width;
  final int? height;

  EncodedFrame({
    required this.data,
    required this.type,
    required this.timestampMs,
    required this.trackType,
    this.width,
    this.height,
  });

  bool get isKeyframe => type == FrameType.keyframe;
}

/// Media encoder configuration
class EncoderConfig {
  // Video settings
  final int videoWidth;
  final int videoHeight;
  final int videoFrameRate;
  final int videoBitrate;
  final String videoCodec;

  // Audio settings
  final int audioSampleRate;
  final int audioChannels;
  final int audioBitrate;
  final String audioCodec;

  // Segment settings
  final int gopSize; // Keyframe interval in frames
  final Duration segmentDuration;

  const EncoderConfig({
    this.videoWidth = 1280,
    this.videoHeight = 720,
    this.videoFrameRate = 30,
    this.videoBitrate = 2000000,
    this.videoCodec = 'h264',
    this.audioSampleRate = 48000,
    this.audioChannels = 2,
    this.audioBitrate = 128000,
    this.audioCodec = 'aac',
    this.gopSize = 30, // 1 second at 30fps
    this.segmentDuration = const Duration(seconds: 1),
  });
}

/// Abstract media encoder interface
///
/// Implementations should encode raw video/audio to fMP4/CMAF format.
abstract class MediaEncoder {
  /// Start the encoder
  Future<void> start();

  /// Stop the encoder
  Future<void> stop();

  /// Add raw video frame data
  Future<void> addVideoFrame(Uint8List frameData, int timestampMs);

  /// Add raw audio samples
  Future<void> addAudioSamples(Uint8List samples, int timestampMs);

  /// Stream of encoded frames
  Stream<EncodedFrame> get encodedFrames;

  /// Get initialization segment (moov box for fMP4)
  Future<Uint8List> getInitSegment(String trackType);

  /// Dispose resources
  void dispose();
}

/// Software-based media encoder using FFmpeg CLI
///
/// This implementation uses FFmpeg as an external process for encoding.
/// For production, consider using FFI bindings for lower latency.
class FFmpegMediaEncoder implements MediaEncoder {
  final EncoderConfig config;
  final Logger _logger;
  final String _tempDir;

  Process? _ffmpegProcess;
  final _frameController = StreamController<EncodedFrame>.broadcast();
  bool _isRunning = false;

  // Frame counters
  int _videoFrameCount = 0;
  int _audioFrameCount = 0;

  // Buffer for incomplete frames
  final _videoBuffer = <Uint8List>[];
  final _audioBuffer = <Uint8List>[];

  // Initialization segments (cached)
  Uint8List? _videoInitSegment;
  Uint8List? _audioInitSegment;

  FFmpegMediaEncoder({
    required this.config,
    required String tempDir,
    Logger? logger,
  })  : _logger = logger ?? Logger(),
        _tempDir = tempDir;

  @override
  Future<void> start() async {
    if (_isRunning) {
      _logger.w('Encoder already running');
      return;
    }

    _logger.i('Starting FFmpeg encoder');
    _isRunning = true;
    _videoFrameCount = 0;
    _audioFrameCount = 0;

    // Create temp directory if needed
    final dir = Directory(_tempDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  @override
  Future<void> stop() async {
    if (!_isRunning) return;

    _logger.i('Stopping FFmpeg encoder');
    _isRunning = false;

    _ffmpegProcess?.kill();
    _ffmpegProcess = null;
  }

  @override
  Future<void> addVideoFrame(Uint8List frameData, int timestampMs) async {
    if (!_isRunning) return;

    _videoBuffer.add(frameData);
    _videoFrameCount++;

    // Check if we should output a segment
    if (_videoFrameCount % config.gopSize == 0) {
      await _encodeVideoSegment(timestampMs);
    }
  }

  @override
  Future<void> addAudioSamples(Uint8List samples, int timestampMs) async {
    if (!_isRunning) return;

    _audioBuffer.add(samples);
    _audioFrameCount++;

    // Encode audio segments periodically
    final samplesPerSegment =
        (config.audioSampleRate * config.segmentDuration.inMilliseconds) ~/ 1000;
    final currentSamples = _audioBuffer.fold<int>(0, (sum, b) => sum + b.length ~/ 4);

    if (currentSamples >= samplesPerSegment) {
      await _encodeAudioSegment(timestampMs);
    }
  }

  Future<void> _encodeVideoSegment(int timestampMs) async {
    if (_videoBuffer.isEmpty) return;

    // Combine buffered frames
    final totalLength = _videoBuffer.fold<int>(0, (sum, b) => sum + b.length);
    final combined = Uint8List(totalLength);
    int offset = 0;
    for (final buffer in _videoBuffer) {
      combined.setAll(offset, buffer);
      offset += buffer.length;
    }
    _videoBuffer.clear();

    // For now, emit the raw data as a frame
    // In production, this would invoke FFmpeg to encode to H.264/CMAF
    final isKeyframe = _videoFrameCount % config.gopSize == 0;
    final frame = EncodedFrame(
      data: combined,
      type: isKeyframe ? FrameType.keyframe : FrameType.delta,
      timestampMs: timestampMs,
      trackType: 'video',
      width: config.videoWidth,
      height: config.videoHeight,
    );

    _frameController.add(frame);
    _logger.d('Encoded video segment: ${combined.length} bytes, keyframe: $isKeyframe');
  }

  Future<void> _encodeAudioSegment(int timestampMs) async {
    if (_audioBuffer.isEmpty) return;

    // Combine buffered samples
    final totalLength = _audioBuffer.fold<int>(0, (sum, b) => sum + b.length);
    final combined = Uint8List(totalLength);
    int offset = 0;
    for (final buffer in _audioBuffer) {
      combined.setAll(offset, buffer);
      offset += buffer.length;
    }
    _audioBuffer.clear();

    // Emit as audio frame
    final frame = EncodedFrame(
      data: combined,
      type: FrameType.keyframe, // Audio segments are always independently decodable
      timestampMs: timestampMs,
      trackType: 'audio',
    );

    _frameController.add(frame);
    _logger.d('Encoded audio segment: ${combined.length} bytes');
  }

  @override
  Stream<EncodedFrame> get encodedFrames => _frameController.stream;

  @override
  Future<Uint8List> getInitSegment(String trackType) async {
    if (trackType == 'video') {
      _videoInitSegment ??= _createVideoInitSegment();
      return _videoInitSegment!;
    } else {
      _audioInitSegment ??= _createAudioInitSegment();
      return _audioInitSegment!;
    }
  }

  /// Create a minimal fMP4 initialization segment for video
  Uint8List _createVideoInitSegment() {
    // This is a placeholder - in production, generate proper ftyp+moov boxes
    // For CMAF video with H.264:
    // - ftyp: iso6, mp41, cmfc
    // - moov: mvhd + trak (tkhd, mdia/mdhd, hdlr, minf, stbl)
    _logger.d('Creating video init segment (placeholder)');
    return Uint8List.fromList([
      // Minimal ftyp box
      0x00, 0x00, 0x00, 0x14, // size: 20
      0x66, 0x74, 0x79, 0x70, // 'ftyp'
      0x63, 0x6D, 0x66, 0x63, // 'cmfc'
      0x00, 0x00, 0x00, 0x00, // minor version
      0x63, 0x6D, 0x66, 0x63, // compatible brand: cmfc
    ]);
  }

  /// Create a minimal fMP4 initialization segment for audio
  Uint8List _createAudioInitSegment() {
    _logger.d('Creating audio init segment (placeholder)');
    return Uint8List.fromList([
      // Minimal ftyp box
      0x00, 0x00, 0x00, 0x14, // size: 20
      0x66, 0x74, 0x79, 0x70, // 'ftyp'
      0x63, 0x6D, 0x66, 0x63, // 'cmfc'
      0x00, 0x00, 0x00, 0x00, // minor version
      0x63, 0x6D, 0x66, 0x63, // compatible brand: cmfc
    ]);
  }

  @override
  void dispose() {
    stop();
    _frameController.close();
  }
}
