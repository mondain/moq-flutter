# Fix Audio Pipeline Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix three audio bugs: Linux silence fallback, Android channel/sample-rate detection, and add native Opus encoder for Android.

**Architecture:** Fix bugs in `LinuxAudioCapture` and `MobileAudioCapture` in `audio_capture.dart`, then create a `NativeOpusEncoder` class using `opus_dart`+`opus_flutter` that replaces the FFmpeg-based `OpusEncoder` on platforms where FFmpeg is unavailable (primarily Android). The publisher screen selects the encoder based on platform.

**Tech Stack:** Dart/Flutter, opus_dart 3.0.1, opus_flutter 3.0.3, audio_streamer 4.3.0

---

### Task 1: Fix Linux _isCapturing bug in silence fallback

**Files:**
- Modify: `lib/moq/media/audio_capture.dart:274-321` (LinuxAudioCapture.startCapture)

**Context:** When `Process.start('parec', ...)` throws at line 283, line 316 sets `_isCapturing = false` before calling `_startSilenceGenerator()` at line 319. The silence generator's timer checks `if (!_isCapturing)` and immediately cancels. Also, if `parec` starts but exits unexpectedly, there's no `onDone` handler to detect it.

**Step 1: Fix the catch block ordering**

In `LinuxAudioCapture.startCapture()`, the catch block at line 315-320 should call `_startSilenceGenerator()` before setting `_isCapturing = false`. Actually, silence generator needs `_isCapturing = true` to keep running, so just remove the `_isCapturing = false` from the catch - the silence generator keeps the capture "alive" in degraded mode:

```dart
    } catch (e) {
      _logger.e('Failed to start Linux audio capture: $e');
      // Keep _isCapturing = true so silence generator continues
      _startSilenceGenerator();
    }
```

**Step 2: Add onDone handler for parec stdout**

Add an `onDone` callback to the `_parecProcess.stdout.listen()` call at line 291 to detect when parec exits and fall back to silence:

```dart
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
          _startSilenceGenerator();
        },
        onDone: () {
          if (_isCapturing) {
            _logger.w('parec process exited unexpectedly, falling back to silence');
            _startSilenceGenerator();
          }
        },
      );
```

**Step 3: Store silence timer reference in _startSilenceGenerator**

The Linux `_startSilenceGenerator()` creates a `Timer.periodic` but doesn't store the reference, so it can't be cancelled on `stopCapture()`. Add a `_silenceTimer` field:

Add field: `Timer? _silenceTimer;` alongside existing fields.

Update `_startSilenceGenerator`:
```dart
  void _startSilenceGenerator() {
    _silenceTimer?.cancel();
    _silenceTimer = Timer.periodic(const Duration(milliseconds: 20), (timer) {
      ...
    });
  }
```

Update `stopCapture` to cancel `_silenceTimer`:
```dart
  Future<void> stopCapture() async {
    if (!_isCapturing) return;
    _isCapturing = false;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    if (_parecProcess != null) {
      _parecProcess.kill();
      _parecProcess = null;
    }
    _logger.i('Linux audio capture stopped');
  }
```

**Step 4: Verify with flutter analyze**

Run: `flutter analyze lib/moq/media/audio_capture.dart`

**Step 5: Commit**

```
fix: Linux audio silence fallback and parec exit handling
```

---

### Task 2: Fix Android audio_streamer channel and sample-rate detection

**Files:**
- Modify: `lib/moq/media/audio_capture.dart:107-232` (MobileAudioCapture)

**Context:** The `audio_streamer` package:
- Defaults to 44100 Hz (not 48000)
- Has `actualSampleRate` async getter that returns the real device rate
- Returns `List<double>` which is a flat mono sample list from the microphone
- Our code assumes stereo (2 channels) and 48000 Hz, producing wrong AudioSamples metadata

The `audio_streamer` package always captures mono from the device microphone. Our Opus encoder expects stereo. We need to: (a) query the actual sample rate, (b) detect that input is mono, and (c) duplicate mono to stereo for the encoder.

**Step 1: Query actual sample rate after starting the stream**

After the audio stream starts listening, query `actualSampleRate` and store it:

Add fields:
```dart
  int _actualSampleRate = 0;
  bool _isMono = true; // audio_streamer always returns mono
```

In `startCapture()`, after setting up the listener, query the actual rate:

```dart
      // Query actual sample rate from the device
      Future.delayed(const Duration(milliseconds: 100), () async {
        try {
          _actualSampleRate = await audio_pkg.AudioStreamer().actualSampleRate;
          _logger.i('Actual device sample rate: $_actualSampleRate Hz');
        } catch (e) {
          _logger.w('Could not query actual sample rate: $e');
          _actualSampleRate = config.sampleRate;
        }
      });
```

**Step 2: Fix _onAudioData to handle mono-to-stereo conversion**

The `audio_streamer` returns mono `List<double>`. We need to duplicate each sample for stereo output so the Opus encoder gets correctly interleaved stereo data:

```dart
  void _onAudioData(List<double> audioData) {
    if (!_isCapturing) return;

    final timestampMs = DateTime.now().millisecondsSinceEpoch - _startTimeMs;
    final sampleRate = _actualSampleRate > 0 ? _actualSampleRate : config.sampleRate;

    // audio_streamer returns mono samples as List<double>
    // Convert to Int16 PCM and duplicate to stereo if configured for 2 channels
    final outputChannels = config.channels;
    final pcmData = Uint8List(audioData.length * outputChannels * 2);
    final byteData = ByteData.view(pcmData.buffer);

    for (var i = 0; i < audioData.length; i++) {
      final sample = (audioData[i] * 32767).clamp(-32768, 32767).toInt();
      if (outputChannels == 2) {
        // Duplicate mono sample to both left and right channels
        byteData.setInt16(i * 4, sample, Endian.little);
        byteData.setInt16(i * 4 + 2, sample, Endian.little);
      } else {
        byteData.setInt16(i * 2, sample, Endian.little);
      }
    }

    _audioController.add(AudioSamples(
      data: pcmData,
      sampleRate: sampleRate,
      channels: outputChannels,
      timestampMs: timestampMs,
      bitsPerSample: 16,
    ));
  }
```

**Step 3: Verify with flutter analyze**

Run: `flutter analyze lib/moq/media/audio_capture.dart`

**Step 4: Commit**

```
fix: Android audio capture mono-to-stereo and sample rate detection
```

---

### Task 3: Create NativeOpusEncoder using opus_dart

**Files:**
- Create: `lib/moq/media/native_opus_encoder.dart`

**Context:** The `opus_dart` + `opus_flutter` packages provide native libopus via FFI. We need a `NativeOpusEncoder` that matches the interface pattern of the existing `OpusEncoder` (emits `OpusFrame` on a stream, accepts `AudioSamples` input). Key API:
- `opus_flutter.load()` returns a DynamicLibrary
- `initOpus(lib)` initializes opus_dart
- `SimpleOpusEncoder(sampleRate:, channels:, application:)` creates encoder
- `encoder.encode(input: Int16List)` returns `Uint8List` of Opus packet
- Frame size for 20ms at 48kHz stereo: `2 * 48000 * 0.02 = 1920` Int16 samples

**Step 1: Create the NativeOpusEncoder class**

```dart
import 'dart:async';
import 'dart:typed_data';
import 'package:logger/logger.dart';
import 'package:opus_dart/opus_dart.dart' as opus_dart;
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'audio_capture.dart';
import 'audio_encoder.dart';

/// Native Opus encoder using opus_dart FFI bindings to libopus.
/// Works on Android, iOS, Windows without requiring FFmpeg.
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

  Stream<OpusFrame> get frames => _frameController.stream;
  bool get isRunning => _isRunning;

  /// Initialize the native opus library. Safe to call multiple times.
  static Future<void> _ensureInitialized() async {
    if (!_opusInitialized) {
      final lib = await opus_flutter.load();
      opus_dart.initOpus(lib);
      _opusInitialized = true;
    }
  }

  Future<void> start() async {
    if (_isRunning) return;

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

  Future<void> addSamples(AudioSamples samples) async {
    if (!_isRunning || _encoder == null) return;

    _pcmBuffer.add(samples.data);

    // Encode complete frames
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

  Future<void> addPcmBytes(Uint8List pcmData, int timestampMs) async {
    if (!_isRunning || _encoder == null) return;
    _currentTimestampMs = timestampMs;
    _pcmBuffer.add(pcmData);

    // Encode complete frames (same logic)
    while (_pcmBuffer.length >= config.bytesPerFrame) {
      final allData = _pcmBuffer.takeBytes();
      final frameData = Uint8List.sublistView(allData, 0, config.bytesPerFrame);
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

      if (allData.length > config.bytesPerFrame) {
        _pcmBuffer.add(Uint8List.sublistView(allData, config.bytesPerFrame));
      }
    }
  }

  Future<void> flush() async {
    // Native encoder doesn't buffer internally like FFmpeg
  }

  Future<void> stop() async {
    if (!_isRunning) return;
    _isRunning = false;
    _pcmBuffer.clear();
    _encoder?.destroy();
    _encoder = null;
    _logger.i('Native Opus encoder stopped');
  }

  void dispose() {
    stop();
    _frameController.close();
  }
}
```

**Step 2: Verify with flutter analyze**

Run: `flutter analyze lib/moq/media/native_opus_encoder.dart`

**Step 3: Commit**

```
feat: add native Opus encoder using opus_dart for Android support
```

---

### Task 4: Wire NativeOpusEncoder into publisher_screen.dart

**Files:**
- Modify: `lib/screens/publisher_screen.dart:340-407` (_initializeAudioPublishing)

**Context:** Currently `_initializeAudioPublishing` always creates an FFmpeg-based `OpusEncoder`. On Android (and optionally other platforms), use `NativeOpusEncoder` instead. Both have compatible interfaces: `start()`, `addSamples()`, `frames` stream, `stop()`, `dispose()`.

**Step 1: Add conditional encoder selection**

Import `NativeOpusEncoder` and `dart:io` (Platform already imported). Replace the encoder creation:

```dart
import '../moq/media/native_opus_encoder.dart';
```

In `_initializeAudioPublishing`, change the encoder creation block:

```dart
    // Use native Opus encoder on Android/iOS (no FFmpeg available)
    // Use FFmpeg-based encoder on desktop where FFmpeg is typically installed
    final useNativeEncoder = Platform.isAndroid || Platform.isIOS;

    if (useNativeEncoder) {
      final nativeEncoder = NativeOpusEncoder(
        config: const OpusEncoderConfig(
          sampleRate: 48000,
          channels: 2,
          bitrate: 128000,
          frameDurationMs: 20,
          application: 'audio',
        ),
      );
      await nativeEncoder.start();
      _nativeOpusEncoder = nativeEncoder;

      _audioSamplesSubscription = _audioCapture!.audioStream.listen((samples) {
        nativeEncoder.addSamples(samples);
      });

      _opusFrameSubscription = nativeEncoder.frames.listen((opusFrame) async {
        // ... same publish logic as before
      });
    } else {
      _opusEncoder = OpusEncoder(
        config: const OpusEncoderConfig(...),
      );
      await _opusEncoder!.start();
      // ... existing FFmpeg path
    }
```

Add `NativeOpusEncoder? _nativeOpusEncoder;` field and update `_stopPublishing` to dispose it.

**Step 2: Refactor to reduce duplication**

Extract the publish callback into a shared method since both encoder paths use the same logic:

```dart
  void _onOpusFrame(OpusFrame opusFrame, String audioTrackName) async {
    if (!_isPublishing || _isAudioMuted) return;
    try {
      switch (_packagingFormat) {
        case PackagingFormat.cmaf:
          if (_cmafPublisher == null) return;
          await _cmafPublisher!.publishAudioFrame(audioTrackName, opusFrame.data);
        case PackagingFormat.loc:
          if (_locPublisher == null) return;
          await _locPublisher!.publishFrame(audioTrackName, opusFrame.data, newGroup: true);
        case PackagingFormat.moqMi:
          if (_moqMiPublisher == null) return;
          final ptsUs = Int64(opusFrame.timestampMs) * Int64(1000);
          await _moqMiPublisher!.publishOpusFrame(
            payload: opusFrame.data, pts: ptsUs, sampleRate: 48000, numChannels: 2,
          );
      }
      _publishedAudioFrames++;
      if (_publishedAudioFrames % 50 == 0 && mounted) {
        setState(() {
          _statusMessage = 'Publishing... $_publishedFrames video, $_publishedAudioFrames audio';
        });
      }
    } catch (e) {
      debugPrint('Error publishing audio frame: $e');
    }
  }
```

**Step 3: Verify with flutter analyze**

Run: `flutter analyze lib/screens/publisher_screen.dart`

**Step 4: Commit**

```
feat: use native Opus encoder on Android/iOS, FFmpeg on desktop
```
