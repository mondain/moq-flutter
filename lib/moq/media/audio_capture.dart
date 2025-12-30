import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:audio_streamer/audio_streamer.dart' as audio_pkg;
import 'package:logger/logger.dart';
import 'native_capture_channel.dart';

/// Raw audio samples from microphone
class AudioSamples {
  final Uint8List data;
  final int sampleRate;
  final int channels;
  final int timestampMs;
  final int bitsPerSample;

  AudioSamples({
    required this.data,
    required this.sampleRate,
    required this.channels,
    required this.timestampMs,
    this.bitsPerSample = 16,
  });

  /// Duration of this audio buffer in milliseconds
  int get durationMs {
    final bytesPerSample = bitsPerSample ~/ 8;
    final samplesCount = data.length ~/ (channels * bytesPerSample);
    return (samplesCount * 1000) ~/ sampleRate;
  }
}

/// Audio capture configuration
class AudioCaptureConfig {
  final int sampleRate;
  final int channels;
  final int bitsPerSample;

  const AudioCaptureConfig({
    this.sampleRate = 48000,
    this.channels = 2,
    this.bitsPerSample = 16,
  });

  /// Opus-friendly configuration (48kHz stereo)
  static const opus = AudioCaptureConfig(
    sampleRate: 48000,
    channels: 2,
    bitsPerSample: 16,
  );

  /// AAC-friendly configuration
  static const aac = AudioCaptureConfig(
    sampleRate: 44100,
    channels: 2,
    bitsPerSample: 16,
  );
}

/// Abstract audio capture interface
abstract class AudioCapture {
  /// Stream of audio samples
  Stream<AudioSamples> get audioStream;

  /// Whether audio capture is currently active
  bool get isCapturing;

  /// The configuration being used
  AudioCaptureConfig get config;

  /// Initialize audio capture
  Future<void> initialize();

  /// Start capturing audio
  Future<void> startCapture();

  /// Stop capturing audio
  Future<void> stopCapture();

  /// Dispose resources
  void dispose();

  /// Factory to create platform-appropriate audio capture
  factory AudioCapture({
    AudioCaptureConfig? config,
    Logger? logger,
  }) {
    final cfg = config ?? AudioCaptureConfig.opus;
    final log = logger ?? Logger();

    if (Platform.isAndroid) {
      return MobileAudioCapture(config: cfg, logger: log);
    } else if (Platform.isIOS) {
      return NativeIOSAudioCapture(config: cfg, logger: log);
    } else if (Platform.isLinux) {
      return LinuxAudioCapture(config: cfg, logger: log);
    } else if (Platform.isMacOS) {
      return NativeMacOSAudioCapture(config: cfg, logger: log);
    } else if (Platform.isWindows) {
      return WindowsAudioCapture(config: cfg, logger: log);
    } else {
      // Fallback to stub
      return StubAudioCapture(config: cfg, logger: log);
    }
  }
}

/// Mobile audio capture using audio_streamer package (Android/iOS)
class MobileAudioCapture implements AudioCapture {
  @override
  final AudioCaptureConfig config;
  final Logger _logger;

  final _audioController = StreamController<AudioSamples>.broadcast();
  bool _isCapturing = false;
  int _startTimeMs = 0;

  StreamSubscription<List<double>>? _audioSubscription;
  Timer? _silenceTimer;

  MobileAudioCapture({
    required this.config,
    required Logger logger,
  }) : _logger = logger;

  @override
  Stream<AudioSamples> get audioStream => _audioController.stream;

  @override
  bool get isCapturing => _isCapturing;

  @override
  Future<void> initialize() async {
    // Set sample rate before starting (Android only, iOS uses preferred rate)
    audio_pkg.AudioStreamer().sampleRate = config.sampleRate;
    _logger.i('Mobile audio capture initialized (sample rate: ${config.sampleRate}Hz)');
  }

  @override
  Future<void> startCapture() async {
    if (_isCapturing) return;

    _isCapturing = true;
    _startTimeMs = DateTime.now().millisecondsSinceEpoch;

    try {
      // Set sample rate before listening
      audio_pkg.AudioStreamer().sampleRate = config.sampleRate;

      // Start the audio stream
      _audioSubscription = audio_pkg.AudioStreamer().audioStream.listen(
        _onAudioData,
        onError: (error) {
          _logger.e('Audio stream error: $error');
          _startSilenceGenerator();
        },
        cancelOnError: false,
      );

      _logger.i('Mobile audio capture started');
    } catch (e) {
      _logger.e('Failed to start mobile audio capture: $e');
      // Fall back to generating silence
      _startSilenceGenerator();
    }
  }

  void _onAudioData(List<double> audioData) {
    if (!_isCapturing) return;

    final timestampMs = DateTime.now().millisecondsSinceEpoch - _startTimeMs;

    // Convert double samples to Int16 PCM
    final pcmData = Uint8List(audioData.length * 2);
    final byteData = ByteData.view(pcmData.buffer);

    for (var i = 0; i < audioData.length; i++) {
      // Clamp and convert to 16-bit signed integer
      final sample = (audioData[i] * 32767).clamp(-32768, 32767).toInt();
      byteData.setInt16(i * 2, sample, Endian.little);
    }

    _audioController.add(AudioSamples(
      data: pcmData,
      sampleRate: config.sampleRate,
      channels: config.channels,
      timestampMs: timestampMs,
      bitsPerSample: 16,
    ));
  }

  void _startSilenceGenerator() {
    _silenceTimer?.cancel();
    _silenceTimer = Timer.periodic(const Duration(milliseconds: 20), (timer) {
      if (!_isCapturing) {
        timer.cancel();
        return;
      }

      final timestampMs = DateTime.now().millisecondsSinceEpoch - _startTimeMs;
      final samplesPerFrame = (config.sampleRate * 20) ~/ 1000;
      final frameSize = samplesPerFrame * config.channels * 2; // 16-bit

      _audioController.add(AudioSamples(
        data: Uint8List(frameSize),
        sampleRate: config.sampleRate,
        channels: config.channels,
        timestampMs: timestampMs,
        bitsPerSample: 16,
      ));
    });
    _logger.w('Falling back to silence generator');
  }

  @override
  Future<void> stopCapture() async {
    if (!_isCapturing) return;

    _isCapturing = false;
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    _silenceTimer?.cancel();
    _silenceTimer = null;

    _logger.i('Mobile audio capture stopped');
  }

  @override
  void dispose() {
    stopCapture();
    _audioController.close();
  }
}

/// Linux audio capture using PulseAudio via parec command
class LinuxAudioCapture implements AudioCapture {
  @override
  final AudioCaptureConfig config;
  final Logger _logger;

  final _audioController = StreamController<AudioSamples>.broadcast();
  bool _isCapturing = false;
  int _startTimeMs = 0;

  // Process for parec
  dynamic _parecProcess;

  LinuxAudioCapture({
    required this.config,
    required Logger logger,
  }) : _logger = logger;

  @override
  Stream<AudioSamples> get audioStream => _audioController.stream;

  @override
  bool get isCapturing => _isCapturing;

  @override
  Future<void> initialize() async {
    // Check if parec is available
    try {
      final result = await Process.run('which', ['parec']);
      if (result.exitCode != 0) {
        _logger.w('parec not found, audio capture may not work');
      } else {
        _logger.i('Linux audio capture initialized (using PulseAudio)');
      }
    } catch (e) {
      _logger.w('Could not check for parec: $e');
    }
  }

  @override
  Future<void> startCapture() async {
    if (_isCapturing) return;

    _isCapturing = true;
    _startTimeMs = DateTime.now().millisecondsSinceEpoch;

    try {
      // Start parec to capture audio
      // parec --format=s16le --rate=48000 --channels=2 --raw
      _parecProcess = await Process.start('parec', [
        '--format=s16le',
        '--rate=${config.sampleRate}',
        '--channels=${config.channels}',
        '--raw',
      ]);

      // Read audio data from stdout
      _parecProcess.stdout.listen(
        (Uint8List data) {
          if (!_isCapturing) return;

          final timestampMs = DateTime.now().millisecondsSinceEpoch - _startTimeMs;

          _audioController.add(AudioSamples(
            data: data,
            sampleRate: config.sampleRate,
            channels: config.channels,
            timestampMs: timestampMs,
            bitsPerSample: 16,
          ));
        },
        onError: (error) {
          _logger.e('parec error: $error');
        },
      );

      _parecProcess.stderr.listen((data) {
        _logger.w('parec stderr: ${String.fromCharCodes(data)}');
      });

      _logger.i('Linux audio capture started (PulseAudio)');
    } catch (e) {
      _isCapturing = false;
      _logger.e('Failed to start Linux audio capture: $e');
      // Fall back to silence
      _startSilenceGenerator();
    }
  }

  void _startSilenceGenerator() {
    Timer.periodic(const Duration(milliseconds: 20), (timer) {
      if (!_isCapturing) {
        timer.cancel();
        return;
      }

      final timestampMs = DateTime.now().millisecondsSinceEpoch - _startTimeMs;
      final samplesPerFrame = (config.sampleRate * 20) ~/ 1000;
      final frameSize = samplesPerFrame * config.channels * 2;

      _audioController.add(AudioSamples(
        data: Uint8List(frameSize),
        sampleRate: config.sampleRate,
        channels: config.channels,
        timestampMs: timestampMs,
        bitsPerSample: 16,
      ));
    });
  }

  @override
  Future<void> stopCapture() async {
    if (!_isCapturing) return;

    _isCapturing = false;

    if (_parecProcess != null) {
      _parecProcess.kill();
      _parecProcess = null;
    }

    _logger.i('Linux audio capture stopped');
  }

  @override
  void dispose() {
    stopCapture();
    _audioController.close();
  }
}

/// Native macOS audio capture using AVFoundation via Platform Channels
class NativeMacOSAudioCapture implements AudioCapture {
  @override
  final AudioCaptureConfig config;
  final Logger _logger;

  final _audioController = StreamController<AudioSamples>.broadcast();
  bool _isCapturing = false;
  NativeCaptureChannel? _nativeChannel;
  StreamSubscription<NativeAudioSamples>? _nativeSubscription;

  // Fallback timer for generating silence if native capture fails
  Timer? _silenceTimer;
  int _startTimeMs = 0;
  bool _nativeAvailable = true;

  NativeMacOSAudioCapture({
    required this.config,
    required Logger logger,
  }) : _logger = logger;

  @override
  Stream<AudioSamples> get audioStream => _audioController.stream;

  @override
  bool get isCapturing => _isCapturing;

  @override
  Future<void> initialize() async {
    try {
      _nativeChannel = NativeCaptureChannel(logger: _logger);

      // Request microphone permission if needed
      final hasPermission = await _nativeChannel!.hasMicrophonePermission();
      if (!hasPermission) {
        final granted = await _nativeChannel!.requestMicrophonePermission();
        if (!granted) {
          _logger.w('Microphone permission denied, falling back to silence');
          _nativeAvailable = false;
          return;
        }
      }

      await _nativeChannel!.initializeAudio(
        sampleRate: config.sampleRate,
        channels: config.channels,
        bitsPerSample: config.bitsPerSample,
      );

      _logger.i('macOS native audio capture initialized');
    } catch (e) {
      _logger.w('Failed to initialize native audio capture: $e');
      _logger.w('Falling back to silence generator');
      _nativeAvailable = false;
    }
  }

  @override
  Future<void> startCapture() async {
    if (_isCapturing) return;

    _isCapturing = true;
    _startTimeMs = DateTime.now().millisecondsSinceEpoch;

    if (_nativeAvailable && _nativeChannel != null) {
      try {
        // Subscribe to native audio stream
        _nativeSubscription = _nativeChannel!.audioStream.listen(
          _onNativeAudioData,
          onError: (error) {
            _logger.e('Native audio stream error: $error');
            _startSilenceGenerator();
          },
        );

        await _nativeChannel!.startAudioCapture();
        _logger.i('macOS native audio capture started');
      } catch (e) {
        _logger.e('Failed to start native audio capture: $e');
        _startSilenceGenerator();
      }
    } else {
      _startSilenceGenerator();
    }
  }

  void _onNativeAudioData(NativeAudioSamples nativeSamples) {
    if (!_isCapturing) return;

    _audioController.add(AudioSamples(
      data: nativeSamples.data,
      sampleRate: nativeSamples.sampleRate,
      channels: nativeSamples.channels,
      timestampMs: nativeSamples.timestampMs,
      bitsPerSample: nativeSamples.bitsPerSample,
    ));
  }

  void _startSilenceGenerator() {
    _silenceTimer?.cancel();
    _silenceTimer = Timer.periodic(const Duration(milliseconds: 20), (timer) {
      if (!_isCapturing) {
        timer.cancel();
        return;
      }

      final timestampMs = DateTime.now().millisecondsSinceEpoch - _startTimeMs;
      final samplesPerFrame = (config.sampleRate * 20) ~/ 1000;
      final frameSize = samplesPerFrame * config.channels * 2;

      _audioController.add(AudioSamples(
        data: Uint8List(frameSize),
        sampleRate: config.sampleRate,
        channels: config.channels,
        timestampMs: timestampMs,
        bitsPerSample: 16,
      ));
    });
    _logger.w('macOS audio capture falling back to silence generator');
  }

  @override
  Future<void> stopCapture() async {
    if (!_isCapturing) return;

    _isCapturing = false;
    _silenceTimer?.cancel();
    _silenceTimer = null;

    await _nativeSubscription?.cancel();
    _nativeSubscription = null;

    if (_nativeAvailable && _nativeChannel != null) {
      try {
        await _nativeChannel!.stopAudioCapture();
      } catch (e) {
        _logger.w('Error stopping native audio capture: $e');
      }
    }

    _logger.i('macOS audio capture stopped');
  }

  @override
  void dispose() {
    stopCapture();
    _nativeChannel?.dispose();
    _audioController.close();
  }
}

/// Native iOS audio capture using AVFoundation via Platform Channels
class NativeIOSAudioCapture implements AudioCapture {
  @override
  final AudioCaptureConfig config;
  final Logger _logger;

  final _audioController = StreamController<AudioSamples>.broadcast();
  bool _isCapturing = false;
  NativeCaptureChannel? _nativeChannel;
  StreamSubscription<NativeAudioSamples>? _nativeSubscription;

  // Fallback timer for generating silence if native capture fails
  Timer? _silenceTimer;
  int _startTimeMs = 0;
  bool _nativeAvailable = true;

  NativeIOSAudioCapture({
    required this.config,
    required Logger logger,
  }) : _logger = logger;

  @override
  Stream<AudioSamples> get audioStream => _audioController.stream;

  @override
  bool get isCapturing => _isCapturing;

  @override
  Future<void> initialize() async {
    try {
      _nativeChannel = NativeCaptureChannel(logger: _logger);

      // Request microphone permission if needed
      final hasPermission = await _nativeChannel!.hasMicrophonePermission();
      if (!hasPermission) {
        final granted = await _nativeChannel!.requestMicrophonePermission();
        if (!granted) {
          _logger.w('Microphone permission denied, falling back to silence');
          _nativeAvailable = false;
          return;
        }
      }

      await _nativeChannel!.initializeAudio(
        sampleRate: config.sampleRate,
        channels: config.channels,
        bitsPerSample: config.bitsPerSample,
      );

      _logger.i('iOS native audio capture initialized');
    } catch (e) {
      _logger.w('Failed to initialize native audio capture: $e');
      _logger.w('Falling back to silence generator');
      _nativeAvailable = false;
    }
  }

  @override
  Future<void> startCapture() async {
    if (_isCapturing) return;

    _isCapturing = true;
    _startTimeMs = DateTime.now().millisecondsSinceEpoch;

    if (_nativeAvailable && _nativeChannel != null) {
      try {
        // Subscribe to native audio stream
        _nativeSubscription = _nativeChannel!.audioStream.listen(
          _onNativeAudioData,
          onError: (error) {
            _logger.e('Native audio stream error: $error');
            _startSilenceGenerator();
          },
        );

        await _nativeChannel!.startAudioCapture();
        _logger.i('iOS native audio capture started');
      } catch (e) {
        _logger.e('Failed to start native audio capture: $e');
        _startSilenceGenerator();
      }
    } else {
      _startSilenceGenerator();
    }
  }

  void _onNativeAudioData(NativeAudioSamples nativeSamples) {
    if (!_isCapturing) return;

    _audioController.add(AudioSamples(
      data: nativeSamples.data,
      sampleRate: nativeSamples.sampleRate,
      channels: nativeSamples.channels,
      timestampMs: nativeSamples.timestampMs,
      bitsPerSample: nativeSamples.bitsPerSample,
    ));
  }

  void _startSilenceGenerator() {
    _silenceTimer?.cancel();
    _silenceTimer = Timer.periodic(const Duration(milliseconds: 20), (timer) {
      if (!_isCapturing) {
        timer.cancel();
        return;
      }

      final timestampMs = DateTime.now().millisecondsSinceEpoch - _startTimeMs;
      final samplesPerFrame = (config.sampleRate * 20) ~/ 1000;
      final frameSize = samplesPerFrame * config.channels * 2;

      _audioController.add(AudioSamples(
        data: Uint8List(frameSize),
        sampleRate: config.sampleRate,
        channels: config.channels,
        timestampMs: timestampMs,
        bitsPerSample: 16,
      ));
    });
    _logger.w('iOS audio capture falling back to silence generator');
  }

  @override
  Future<void> stopCapture() async {
    if (!_isCapturing) return;

    _isCapturing = false;
    _silenceTimer?.cancel();
    _silenceTimer = null;

    await _nativeSubscription?.cancel();
    _nativeSubscription = null;

    if (_nativeAvailable && _nativeChannel != null) {
      try {
        await _nativeChannel!.stopAudioCapture();
      } catch (e) {
        _logger.w('Error stopping native audio capture: $e');
      }
    }

    _logger.i('iOS audio capture stopped');
  }

  @override
  void dispose() {
    stopCapture();
    _nativeChannel?.dispose();
    _audioController.close();
  }
}

/// Legacy macOS audio capture stub (kept for reference)
class MacOSAudioCapture implements AudioCapture {
  @override
  final AudioCaptureConfig config;
  final Logger _logger;

  final _audioController = StreamController<AudioSamples>.broadcast();
  bool _isCapturing = false;
  int _startTimeMs = 0;
  Timer? _silenceTimer;

  MacOSAudioCapture({
    required this.config,
    required Logger logger,
  }) : _logger = logger;

  @override
  Stream<AudioSamples> get audioStream => _audioController.stream;

  @override
  bool get isCapturing => _isCapturing;

  @override
  Future<void> initialize() async {
    _logger.i('macOS audio capture initialized (stub - generating silence)');
  }

  @override
  Future<void> startCapture() async {
    if (_isCapturing) return;

    _isCapturing = true;
    _startTimeMs = DateTime.now().millisecondsSinceEpoch;

    _silenceTimer = Timer.periodic(const Duration(milliseconds: 20), (timer) {
      if (!_isCapturing) {
        timer.cancel();
        return;
      }

      final timestampMs = DateTime.now().millisecondsSinceEpoch - _startTimeMs;
      final samplesPerFrame = (config.sampleRate * 20) ~/ 1000;
      final frameSize = samplesPerFrame * config.channels * 2;

      _audioController.add(AudioSamples(
        data: Uint8List(frameSize),
        sampleRate: config.sampleRate,
        channels: config.channels,
        timestampMs: timestampMs,
        bitsPerSample: 16,
      ));
    });

    _logger.i('macOS audio capture started (stub)');
  }

  @override
  Future<void> stopCapture() async {
    if (!_isCapturing) return;

    _isCapturing = false;
    _silenceTimer?.cancel();
    _silenceTimer = null;

    _logger.i('macOS audio capture stopped');
  }

  @override
  void dispose() {
    stopCapture();
    _audioController.close();
  }
}

/// Windows audio capture (placeholder - uses WASAPI)
class WindowsAudioCapture implements AudioCapture {
  @override
  final AudioCaptureConfig config;
  final Logger _logger;

  final _audioController = StreamController<AudioSamples>.broadcast();
  bool _isCapturing = false;
  int _startTimeMs = 0;
  Timer? _silenceTimer;

  WindowsAudioCapture({
    required this.config,
    required Logger logger,
  }) : _logger = logger;

  @override
  Stream<AudioSamples> get audioStream => _audioController.stream;

  @override
  bool get isCapturing => _isCapturing;

  @override
  Future<void> initialize() async {
    _logger.i('Windows audio capture initialized (stub - generating silence)');
  }

  @override
  Future<void> startCapture() async {
    if (_isCapturing) return;

    _isCapturing = true;
    _startTimeMs = DateTime.now().millisecondsSinceEpoch;

    // TODO: Implement native Windows audio capture via FFI/platform channel
    // For now, generate silence
    _silenceTimer = Timer.periodic(const Duration(milliseconds: 20), (timer) {
      if (!_isCapturing) {
        timer.cancel();
        return;
      }

      final timestampMs = DateTime.now().millisecondsSinceEpoch - _startTimeMs;
      final samplesPerFrame = (config.sampleRate * 20) ~/ 1000;
      final frameSize = samplesPerFrame * config.channels * 2;

      _audioController.add(AudioSamples(
        data: Uint8List(frameSize),
        sampleRate: config.sampleRate,
        channels: config.channels,
        timestampMs: timestampMs,
        bitsPerSample: 16,
      ));
    });

    _logger.i('Windows audio capture started (stub)');
  }

  @override
  Future<void> stopCapture() async {
    if (!_isCapturing) return;

    _isCapturing = false;
    _silenceTimer?.cancel();
    _silenceTimer = null;

    _logger.i('Windows audio capture stopped');
  }

  @override
  void dispose() {
    stopCapture();
    _audioController.close();
  }
}

/// Stub audio capture that generates silence (fallback)
class StubAudioCapture implements AudioCapture {
  @override
  final AudioCaptureConfig config;
  final Logger _logger;

  final _audioController = StreamController<AudioSamples>.broadcast();
  bool _isCapturing = false;
  int _startTimeMs = 0;
  Timer? _silenceTimer;

  StubAudioCapture({
    required this.config,
    required Logger logger,
  }) : _logger = logger;

  @override
  Stream<AudioSamples> get audioStream => _audioController.stream;

  @override
  bool get isCapturing => _isCapturing;

  @override
  Future<void> initialize() async {
    _logger.i('Stub audio capture initialized (generating silence)');
  }

  @override
  Future<void> startCapture() async {
    if (_isCapturing) return;

    _isCapturing = true;
    _startTimeMs = DateTime.now().millisecondsSinceEpoch;

    _silenceTimer = Timer.periodic(const Duration(milliseconds: 20), (timer) {
      if (!_isCapturing) {
        timer.cancel();
        return;
      }

      final timestampMs = DateTime.now().millisecondsSinceEpoch - _startTimeMs;
      final samplesPerFrame = (config.sampleRate * 20) ~/ 1000;
      final frameSize = samplesPerFrame * config.channels * 2;

      _audioController.add(AudioSamples(
        data: Uint8List(frameSize),
        sampleRate: config.sampleRate,
        channels: config.channels,
        timestampMs: timestampMs,
        bitsPerSample: 16,
      ));
    });

    _logger.i('Stub audio capture started (generating silence)');
  }

  @override
  Future<void> stopCapture() async {
    if (!_isCapturing) return;

    _isCapturing = false;
    _silenceTimer?.cancel();
    _silenceTimer = null;

    _logger.i('Stub audio capture stopped');
  }

  @override
  void dispose() {
    stopCapture();
    _audioController.close();
  }
}
