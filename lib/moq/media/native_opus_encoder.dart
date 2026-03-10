import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:logger/logger.dart';
import 'package:opus_dart/opus_dart.dart' as opus_dart;
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'audio_capture.dart';
import 'audio_encoder.dart';

/// Native Opus encoder using opus_dart FFI bindings to libopus.
/// Works on Android, iOS, macOS, Linux, and Windows.
/// On macOS/Linux, loads the system-installed libopus directly.
class NativeOpusEncoder {
  final OpusEncoderConfig config;
  final Logger _logger;

  opus_dart.SimpleOpusEncoder? _encoder;
  final _frameController = StreamController<OpusFrame>.broadcast();
  bool _isRunning = false;

  int _sequenceNumber = 0;
  int _currentTimestampMs = 0;

  // Buffer for accumulating PCM data to complete frames
  final _pcmBuffer = BytesBuilder();

  static bool _opusInitialized = false;

  NativeOpusEncoder({
    OpusEncoderConfig? config,
    Logger? logger,
  })  : config = config ?? const OpusEncoderConfig(),
        _logger = logger ?? Logger();

  /// Stream of encoded Opus frames
  Stream<OpusFrame> get frames => _frameController.stream;

  /// Whether the encoder is running
  bool get isRunning => _isRunning;

  /// Initialize the native opus library. Safe to call multiple times.
  /// On Android/iOS/Windows, uses opus_flutter plugin.
  /// On macOS/Linux, loads the system-installed libopus directly.
  static Future<void> _ensureInitialized() async {
    if (!_opusInitialized) {
      if (Platform.isMacOS || Platform.isLinux) {
        final lib = _loadSystemLibopus();
        // Cast to dynamic to satisfy opus_dart's proxy_ffi conditional import
        opus_dart.initOpus(lib as dynamic);
      } else {
        final lib = await opus_flutter.load();
        opus_dart.initOpus(lib);
      }
      _opusInitialized = true;
    }
  }

  /// Load libopus from the app bundle or system paths on macOS/Linux.
  static DynamicLibrary _loadSystemLibopus() {
    final paths = <String>[];
    if (Platform.isMacOS) {
      // Try app bundle first (works inside sandbox)
      final execDir = File(Platform.resolvedExecutable).parent.path;
      paths.addAll([
        '$execDir/../Frameworks/libopus.dylib', // Embedded in .app bundle
        '/opt/homebrew/lib/libopus.dylib', // Apple Silicon Homebrew
        '/usr/local/lib/libopus.dylib', // Intel Homebrew
        'libopus.dylib', // System path
      ]);
    } else {
      paths.addAll([
        'libopus.so.0', // Linux system
        'libopus.so', // Linux fallback
      ]);
    }

    for (final path in paths) {
      try {
        return DynamicLibrary.open(path);
      } catch (_) {
        continue;
      }
    }
    throw UnsupportedError(
      'libopus not found. Install it with: '
      '${Platform.isMacOS ? "brew install opus" : "sudo apt install libopus-dev"}',
    );
  }

  /// Start the encoder
  Future<void> start() async {
    if (_isRunning) {
      _logger.w('Native Opus encoder already running');
      return;
    }

    await _ensureInitialized();

    _encoder = opus_dart.SimpleOpusEncoder(
      sampleRate: config.sampleRate,
      channels: config.channels,
      application: opus_dart.Application.audio,
    );

    _isRunning = true;
    _sequenceNumber = 0;
    _currentTimestampMs = 0;
    _pcmBuffer.clear();

    _logger.i('Native Opus encoder started '
        '(${config.sampleRate}Hz, ${config.channels}ch, libopus ${opus_dart.getOpusVersion()})');
  }

  /// Add raw PCM audio samples to encode
  Future<void> addSamples(AudioSamples samples) async {
    if (!_isRunning || _encoder == null) return;

    _pcmBuffer.add(samples.data);
    _encodeBufferedFrames();
  }

  /// Add raw PCM bytes directly
  Future<void> addPcmBytes(Uint8List pcmData, int timestampMs) async {
    if (!_isRunning || _encoder == null) return;
    _currentTimestampMs = timestampMs;
    _pcmBuffer.add(pcmData);
    _encodeBufferedFrames();
  }

  void _encodeBufferedFrames() {
    while (_pcmBuffer.length >= config.bytesPerFrame) {
      final allData = _pcmBuffer.takeBytes();
      final frameData = Uint8List.sublistView(allData, 0, config.bytesPerFrame);

      // Convert bytes to Int16List for opus_dart
      final int16Data = Int16List.view(
        frameData.buffer,
        frameData.offsetInBytes,
        frameData.lengthInBytes ~/ 2,
      );

      try {
        final encoded = _encoder!.encode(input: int16Data);

        _frameController.add(OpusFrame(
          data: encoded,
          timestampMs: _currentTimestampMs,
          durationMs: config.frameDurationMs,
          sequenceNumber: _sequenceNumber++,
        ));

        _currentTimestampMs += config.frameDurationMs;
      } catch (e) {
        _logger.e('Native Opus encode error: $e');
      }

      // Put remaining data back in buffer
      if (allData.length > config.bytesPerFrame) {
        _pcmBuffer.add(Uint8List.sublistView(allData, config.bytesPerFrame));
      }
    }
  }

  /// Flush any remaining buffered data
  Future<void> flush() async {
    // Native encoder processes frames synchronously, no internal buffering
  }

  /// Stop the encoder
  Future<void> stop() async {
    if (!_isRunning) return;

    _isRunning = false;
    _pcmBuffer.clear();

    _encoder?.destroy();
    _encoder = null;

    _logger.i('Native Opus encoder stopped');
  }

  /// Dispose resources
  void dispose() {
    stop();
    _frameController.close();
  }
}
