import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:logger/logger.dart';
import 'audio_capture.dart';

/// Opus encoder configuration
class OpusEncoderConfig {
  /// Sample rate (Opus supports 8000, 12000, 16000, 24000, 48000)
  final int sampleRate;

  /// Number of channels (1 = mono, 2 = stereo)
  final int channels;

  /// Bitrate in bits per second (6000 - 510000)
  final int bitrate;

  /// Frame duration in milliseconds (2.5, 5, 10, 20, 40, 60)
  final int frameDurationMs;

  /// Application type: 'voip', 'audio', or 'lowdelay'
  final String application;

  const OpusEncoderConfig({
    this.sampleRate = 48000,
    this.channels = 2,
    this.bitrate = 128000,
    this.frameDurationMs = 20,
    this.application = 'audio',
  });

  /// Samples per frame based on duration and sample rate
  int get samplesPerFrame => (sampleRate * frameDurationMs) ~/ 1000;

  /// Bytes per frame (16-bit PCM)
  int get bytesPerFrame => samplesPerFrame * channels * 2;
}

/// Encoded Opus frame/packet
class OpusFrame {
  /// Opus encoded data
  final Uint8List data;

  /// Timestamp in milliseconds
  final int timestampMs;

  /// Duration of this frame in milliseconds
  final int durationMs;

  /// Sequence number
  final int sequenceNumber;

  OpusFrame({
    required this.data,
    required this.timestampMs,
    required this.durationMs,
    required this.sequenceNumber,
  });
}

/// Opus audio encoder using FFmpeg
///
/// Encodes raw PCM audio to Opus codec using FFmpeg as an external process.
/// Outputs raw Opus packets suitable for RTP/MoQ transmission.
class OpusEncoder {
  final OpusEncoderConfig config;
  final Logger _logger;

  Process? _ffmpegProcess;
  final _frameController = StreamController<OpusFrame>.broadcast();
  bool _isRunning = false;

  // Frame tracking
  int _sequenceNumber = 0;
  int _currentTimestampMs = 0;

  // Buffer for accumulating PCM data
  final _pcmBuffer = BytesBuilder();

  // Output buffer for reading Opus packets
  final _outputBuffer = BytesBuilder();

  OpusEncoder({
    OpusEncoderConfig? config,
    Logger? logger,
  })  : config = config ?? const OpusEncoderConfig(),
        _logger = logger ?? Logger();

  /// Stream of encoded Opus frames
  Stream<OpusFrame> get frames => _frameController.stream;

  /// Whether the encoder is running
  bool get isRunning => _isRunning;

  /// Start the encoder
  Future<void> start() async {
    if (_isRunning) {
      _logger.w('Opus encoder already running');
      return;
    }

    _isRunning = true;
    _sequenceNumber = 0;
    _currentTimestampMs = 0;
    _pcmBuffer.clear();
    _outputBuffer.clear();

    await _startFFmpegProcess();
    _logger.i('Opus encoder started (${config.sampleRate}Hz, ${config.channels}ch, ${config.bitrate}bps)');
  }

  Future<void> _startFFmpegProcess() async {
    // FFmpeg command to encode raw PCM to Opus
    // Input: raw PCM s16le from stdin
    // Output: Opus in OGG container to stdout (we'll extract the Opus packets)
    //
    // For raw Opus output, we use -f opus which outputs raw Opus packets
    // with a simple header that we can parse
    final args = [
      '-hide_banner',
      '-loglevel', 'error',
      // Input format
      '-f', 's16le',
      '-ar', config.sampleRate.toString(),
      '-ac', config.channels.toString(),
      '-i', 'pipe:0', // Read from stdin
      // Opus encoding options
      '-c:a', 'libopus',
      '-b:a', config.bitrate.toString(),
      '-application', config.application,
      '-frame_duration', config.frameDurationMs.toString(),
      '-vbr', 'on',
      '-compression_level', '10',
      // Output format - OGG container for easier parsing
      '-f', 'ogg',
      'pipe:1', // Write to stdout
    ];

    try {
      _ffmpegProcess = await Process.start('ffmpeg', args);

      // Handle stderr (errors)
      _ffmpegProcess!.stderr.listen((data) {
        final msg = String.fromCharCodes(data).trim();
        if (msg.isNotEmpty) {
          _logger.w('FFmpeg: $msg');
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

      _logger.d('FFmpeg Opus encoder process started');
    } catch (e) {
      _isRunning = false;
      _logger.e('Failed to start FFmpeg: $e');
      rethrow;
    }
  }

  /// Add raw PCM audio samples to encode
  Future<void> addSamples(AudioSamples samples) async {
    if (!_isRunning || _ffmpegProcess == null) return;

    // Add to PCM buffer
    _pcmBuffer.add(samples.data);

    // Write to FFmpeg when we have enough data for a frame
    if (_pcmBuffer.length >= config.bytesPerFrame) {
      final data = _pcmBuffer.takeBytes();
      try {
        _ffmpegProcess!.stdin.add(data);
      } catch (e) {
        _logger.e('Error writing to FFmpeg: $e');
      }
    }
  }

  /// Add raw PCM bytes directly
  Future<void> addPcmBytes(Uint8List pcmData, int timestampMs) async {
    if (!_isRunning || _ffmpegProcess == null) return;

    _currentTimestampMs = timestampMs;

    try {
      _ffmpegProcess!.stdin.add(pcmData);
    } catch (e) {
      _logger.e('Error writing to FFmpeg: $e');
    }
  }

  void _onEncodedData(Uint8List data) {
    // Accumulate output data
    _outputBuffer.add(data);

    // Try to extract Opus packets from OGG stream
    _extractOpusPackets();
  }

  void _extractOpusPackets() {
    // OGG pages have a specific structure:
    // - 4 bytes: "OggS" magic
    // - 1 byte: version (0)
    // - 1 byte: header type flags
    // - 8 bytes: granule position
    // - 4 bytes: stream serial number
    // - 4 bytes: page sequence number
    // - 4 bytes: CRC checksum
    // - 1 byte: number of segments
    // - N bytes: segment table
    // - Variable: page data

    final buffer = _outputBuffer.takeBytes();
    if (buffer.length < 27) {
      // Not enough data for OGG header
      _outputBuffer.add(buffer);
      return;
    }

    int offset = 0;
    while (offset + 27 <= buffer.length) {
      // Check for OGG magic
      if (buffer[offset] != 0x4F || // 'O'
          buffer[offset + 1] != 0x67 || // 'g'
          buffer[offset + 2] != 0x67 || // 'g'
          buffer[offset + 3] != 0x53) {
        // 'S'
        offset++;
        continue;
      }

      // Read header type
      final headerType = buffer[offset + 5];

      // Read number of segments
      final numSegments = buffer[offset + 26];
      final headerSize = 27 + numSegments;

      if (offset + headerSize > buffer.length) {
        // Incomplete header
        break;
      }

      // Calculate page size from segment table
      int pageDataSize = 0;
      for (var i = 0; i < numSegments; i++) {
        pageDataSize += buffer[offset + 27 + i];
      }

      final totalPageSize = headerSize + pageDataSize;
      if (offset + totalPageSize > buffer.length) {
        // Incomplete page
        break;
      }

      // Skip header pages (BOS = beginning of stream)
      if ((headerType & 0x02) != 0) {
        // This is a BOS page (Opus header), skip it
        offset += totalPageSize;
        continue;
      }

      // Extract Opus packet data
      if (pageDataSize > 0) {
        final opusData = Uint8List.sublistView(
          buffer,
          offset + headerSize,
          offset + headerSize + pageDataSize,
        );

        // Skip Opus comment header (usually second page)
        if (_sequenceNumber == 0 && opusData.length > 8) {
          final magic = String.fromCharCodes(opusData.sublist(0, 8));
          if (magic == 'OpusTags') {
            offset += totalPageSize;
            continue;
          }
        }

        // Emit Opus frame
        final frame = OpusFrame(
          data: Uint8List.fromList(opusData),
          timestampMs: _currentTimestampMs,
          durationMs: config.frameDurationMs,
          sequenceNumber: _sequenceNumber++,
        );

        _frameController.add(frame);
        _currentTimestampMs += config.frameDurationMs;
      }

      offset += totalPageSize;
    }

    // Keep remaining data in buffer
    if (offset < buffer.length) {
      _outputBuffer.add(Uint8List.sublistView(buffer, offset));
    }
  }

  /// Flush any remaining buffered data
  Future<void> flush() async {
    if (!_isRunning || _ffmpegProcess == null) return;

    // Write any remaining buffered PCM data
    if (_pcmBuffer.length > 0) {
      final data = _pcmBuffer.takeBytes();
      try {
        _ffmpegProcess!.stdin.add(data);
        await _ffmpegProcess!.stdin.flush();
      } catch (e) {
        _logger.w('Error flushing to FFmpeg: $e');
      }
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

    _logger.i('Opus encoder stopped');
  }

  /// Dispose resources
  void dispose() {
    stop();
    _frameController.close();
  }
}

/// Simple Opus encoder that doesn't use FFmpeg (for platforms without it)
///
/// This is a stub that passes through raw PCM data with Opus-like framing.
/// Replace with actual Opus encoding when needed.
class StubOpusEncoder {
  final OpusEncoderConfig config;
  final Logger _logger;

  final _frameController = StreamController<OpusFrame>.broadcast();
  bool _isRunning = false;
  int _sequenceNumber = 0;

  StubOpusEncoder({
    OpusEncoderConfig? config,
    Logger? logger,
  })  : config = config ?? const OpusEncoderConfig(),
        _logger = logger ?? Logger();

  Stream<OpusFrame> get frames => _frameController.stream;
  bool get isRunning => _isRunning;

  Future<void> start() async {
    _isRunning = true;
    _sequenceNumber = 0;
    _logger.i('Stub Opus encoder started (passing through PCM)');
  }

  Future<void> addSamples(AudioSamples samples) async {
    if (!_isRunning) return;

    // Just pass through the PCM data with framing
    final frame = OpusFrame(
      data: samples.data,
      timestampMs: samples.timestampMs,
      durationMs: samples.durationMs,
      sequenceNumber: _sequenceNumber++,
    );

    _frameController.add(frame);
  }

  Future<void> stop() async {
    _isRunning = false;
    _logger.i('Stub Opus encoder stopped');
  }

  void dispose() {
    stop();
    _frameController.close();
  }
}
