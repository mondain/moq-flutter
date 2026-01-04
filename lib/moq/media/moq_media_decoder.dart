import 'dart:async';
import 'dart:collection';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart';
import '../packager/moq_mi_packager.dart';
import '../protocol/moq_messages.dart';

/// Decoded media frame with all metadata
class MediaFrame {
  final MediaFrameType type;
  final Int64 seqId;
  final Int64 pts; // Presentation timestamp in timebase units
  final Int64 dts; // Decode timestamp (video only)
  final Int64 timebase;
  final Int64 duration;
  final Int64 wallclock;
  final Uint8List data;

  // Video-specific
  final Uint8List? codecConfig; // AVC decoder config for H.264
  final bool isKeyframe;

  // Audio-specific
  final Int64? sampleRate;
  final int? channels;

  MediaFrame({
    required this.type,
    required this.seqId,
    required this.pts,
    required this.dts,
    required this.timebase,
    required this.duration,
    required this.wallclock,
    required this.data,
    this.codecConfig,
    this.isKeyframe = false,
    this.sampleRate,
    this.channels,
  });

  /// Get PTS in microseconds
  int get ptsUs => (pts * Int64(1000000) ~/ timebase).toInt();

  /// Get DTS in microseconds
  int get dtsUs => (dts * Int64(1000000) ~/ timebase).toInt();

  /// Get duration in microseconds
  int get durationUs => (duration * Int64(1000000) ~/ timebase).toInt();

  @override
  String toString() {
    return 'MediaFrame(type=$type, seqId=$seqId, pts=$pts, isKey=$isKeyframe, size=${data.length})';
  }
}

enum MediaFrameType {
  videoH264,
  audioOpus,
  audioAac,
}

/// Decodes MoQ objects into media frames using moq-mi format
class MoqMediaDecoder {
  Uint8List? _lastVideoCodecConfig;
  bool _hasReceivedKeyframe = false;

  /// Decode a MoQ object into a media frame
  ///
  /// Returns null if:
  /// - Object has no payload
  /// - Extension headers are missing or invalid
  /// - Waiting for keyframe (video)
  MediaFrame? decode(MoQObject object) {
    if (object.payload == null || object.payload!.isEmpty) {
      debugPrint('MoqMediaDecoder: Object has no payload');
      return null;
    }

    // Convert extension headers from the object
    final extensionHeaders = object.extensionHeaders
        .map((h) => KeyValuePair(type: h.type, value: h.value))
        .toList();

    if (extensionHeaders.isEmpty) {
      debugPrint('MoqMediaDecoder: No extension headers');
      return null;
    }

    // Parse moq-mi extension headers
    final moqMiData = MoqMiPackager.parseExtensionHeaders(
      extensionHeaders,
      object.payload!,
    );

    if (moqMiData == null) {
      // Log more details about what we received
      final headerTypes = extensionHeaders.map((h) => '0x${h.type.toRadixString(16)}').join(', ');
      debugPrint('MoqMediaDecoder: Failed to parse moq-mi headers. '
          'Headers: [$headerTypes], payload size: ${object.payload!.length}');
      return null;
    }

    if (moqMiData.isVideo) {
      return _decodeVideoFrame(moqMiData);
    } else if (moqMiData.isAudio) {
      return _decodeAudioFrame(moqMiData);
    }

    return null;
  }

  MediaFrame? _decodeVideoFrame(MoqMiData data) {
    // Check for codec config (indicates keyframe)
    Uint8List? codecConfig = data.avcDecoderConfig;
    bool isKeyframe = false;

    if (codecConfig != null && codecConfig.isNotEmpty) {
      _lastVideoCodecConfig = codecConfig;
      _hasReceivedKeyframe = true;
      isKeyframe = true;
    } else {
      // Check if this is a keyframe by looking at NAL unit type
      isKeyframe = _isH264Keyframe(data.data);
      if (isKeyframe) {
        _hasReceivedKeyframe = true;
      }
    }

    // Don't output frames until we have a keyframe
    if (!_hasReceivedKeyframe) {
      debugPrint('MoqMediaDecoder: Waiting for keyframe');
      return null;
    }

    return MediaFrame(
      type: MediaFrameType.videoH264,
      seqId: data.seqId,
      pts: data.pts,
      dts: data.dts ?? data.pts,
      timebase: data.timebase,
      duration: data.duration,
      wallclock: data.wallclock,
      data: data.data,
      codecConfig: isKeyframe ? _lastVideoCodecConfig : null,
      isKeyframe: isKeyframe,
    );
  }

  MediaFrame? _decodeAudioFrame(MoqMiData data) {
    return MediaFrame(
      type: data.isOpus ? MediaFrameType.audioOpus : MediaFrameType.audioAac,
      seqId: data.seqId,
      pts: data.pts,
      dts: data.pts, // Audio doesn't have separate DTS
      timebase: data.timebase,
      duration: data.duration,
      wallclock: data.wallclock,
      data: data.data,
      sampleRate: data.sampleFreq,
      channels: data.numChannels?.toInt(),
    );
  }

  /// Check if H.264 AVCC data contains a keyframe (IDR NAL)
  bool _isH264Keyframe(Uint8List data) {
    if (data.length < 5) return false;

    // AVCC format: 4-byte length prefix + NAL unit
    int offset = 0;
    while (offset + 4 < data.length) {
      // Read 4-byte big-endian length
      final nalLength = (data[offset] << 24) |
          (data[offset + 1] << 16) |
          (data[offset + 2] << 8) |
          data[offset + 3];

      if (nalLength <= 0 || offset + 4 + nalLength > data.length) break;

      // NAL unit type is in bits 0-4 of the first byte after length
      final nalType = data[offset + 4] & 0x1F;

      // IDR slice = 5, SPS = 7, PPS = 8
      if (nalType == 5 || nalType == 7 || nalType == 8) {
        return true;
      }

      offset += 4 + nalLength;
    }

    return false;
  }

  /// Reset decoder state (e.g., after seek or disconnect)
  void reset() {
    _lastVideoCodecConfig = null;
    _hasReceivedKeyframe = false;
  }

  /// Get last received video codec config
  Uint8List? get videoCodecConfig => _lastVideoCodecConfig;

  /// Check if decoder has received a keyframe
  bool get hasReceivedKeyframe => _hasReceivedKeyframe;
}

/// Jitter buffer for reordering and smoothing media frame delivery
class MediaJitterBuffer {
  final int maxSize;
  final Duration maxDelay;
  final SplayTreeMap<Int64, MediaFrame> _buffer = SplayTreeMap();
  Int64? _lastOutputSeqId;
  final _frameController = StreamController<MediaFrame>.broadcast();
  Timer? _outputTimer;

  MediaJitterBuffer({
    this.maxSize = 30,
    this.maxDelay = const Duration(milliseconds: 200),
  });

  /// Stream of ordered frames
  Stream<MediaFrame> get frameStream => _frameController.stream;

  /// Add a frame to the jitter buffer
  void addFrame(MediaFrame frame) {
    // Skip if we've already output this or older frames
    if (_lastOutputSeqId != null && frame.seqId <= _lastOutputSeqId!) {
      debugPrint('JitterBuffer: Dropping old frame seqId=${frame.seqId}');
      return;
    }

    _buffer[frame.seqId] = frame;

    // Trim buffer if too large
    while (_buffer.length > maxSize) {
      final oldest = _buffer.keys.first;
      debugPrint('JitterBuffer: Buffer full, dropping seqId=$oldest');
      _buffer.remove(oldest);
    }

    // Start output timer if not running
    _outputTimer ??= Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => _tryOutputFrames(),
    );
  }

  void _tryOutputFrames() {
    if (_buffer.isEmpty) return;

    // Output frames in sequence order
    while (_buffer.isNotEmpty) {
      final nextSeqId = _buffer.keys.first;

      // If this is the first frame or next in sequence, output it
      if (_lastOutputSeqId == null ||
          nextSeqId == _lastOutputSeqId! + Int64.ONE ||
          nextSeqId < _lastOutputSeqId!) {
        final frame = _buffer.remove(nextSeqId)!;
        _lastOutputSeqId = nextSeqId;
        _frameController.add(frame);
      } else {
        // Gap in sequence - check if we should skip
        final oldestFrame = _buffer.values.first;
        final age = DateTime.now().millisecondsSinceEpoch -
            oldestFrame.wallclock.toInt();

        if (age > maxDelay.inMilliseconds) {
          // Frame is too old, output it anyway (skip missing frames)
          final frame = _buffer.remove(nextSeqId)!;
          _lastOutputSeqId = nextSeqId;
          _frameController.add(frame);
          debugPrint('JitterBuffer: Skipping gap, outputting seqId=$nextSeqId');
        } else {
          // Wait for missing frames
          break;
        }
      }
    }
  }

  /// Get number of buffered frames
  int get length => _buffer.length;

  /// Get buffered duration in milliseconds (approximate)
  int get bufferedMs {
    if (_buffer.isEmpty) return 0;
    final first = _buffer.values.first;
    final last = _buffer.values.last;
    return ((last.pts - first.pts) * Int64(1000) ~/ first.timebase).toInt();
  }

  /// Clear the buffer
  void clear() {
    _buffer.clear();
    _lastOutputSeqId = null;
  }

  /// Dispose resources
  void dispose() {
    _outputTimer?.cancel();
    _outputTimer = null;
    _frameController.close();
    _buffer.clear();
  }
}

/// Complete media decoder pipeline
///
/// Combines MoqMediaDecoder with jitter buffers for video and audio
class MoqMediaPipeline {
  final MoqMediaDecoder _decoder = MoqMediaDecoder();
  final MediaJitterBuffer _videoBuffer;
  final MediaJitterBuffer _audioBuffer;

  final _videoFrameController = StreamController<MediaFrame>.broadcast();
  final _audioFrameController = StreamController<MediaFrame>.broadcast();

  int _videoFramesReceived = 0;
  int _audioFramesReceived = 0;
  int _videoFramesDropped = 0;
  int _audioFramesDropped = 0;

  MoqMediaPipeline({
    int videoBufferSize = 30,
    Duration videoMaxDelay = const Duration(milliseconds: 200),
    int audioBufferSize = 50,
    Duration audioMaxDelay = const Duration(milliseconds: 100),
  }) : _videoBuffer = MediaJitterBuffer(
          maxSize: videoBufferSize,
          maxDelay: videoMaxDelay,
        ),
       _audioBuffer = MediaJitterBuffer(
          maxSize: audioBufferSize,
          maxDelay: audioMaxDelay,
        ) {
    // Forward frames from jitter buffers
    _videoBuffer.frameStream.listen((frame) {
      _videoFrameController.add(frame);
    });
    _audioBuffer.frameStream.listen((frame) {
      _audioFrameController.add(frame);
    });
  }

  /// Stream of decoded video frames (in order)
  Stream<MediaFrame> get videoFrames => _videoFrameController.stream;

  /// Stream of decoded audio frames (in order)
  Stream<MediaFrame> get audioFrames => _audioFrameController.stream;

  /// Process a MoQ object
  void processObject(MoQObject object) {
    final frame = _decoder.decode(object);
    if (frame == null) {
      if (object.payload != null) {
        // Frame was dropped (likely waiting for keyframe)
        final trackName = String.fromCharCodes(object.trackName);
        if (trackName.contains('video')) {
          _videoFramesDropped++;
        } else {
          _audioFramesDropped++;
        }
      }
      return;
    }

    if (frame.type == MediaFrameType.videoH264) {
      _videoFramesReceived++;
      _videoBuffer.addFrame(frame);
    } else {
      _audioFramesReceived++;
      _audioBuffer.addFrame(frame);
    }
  }

  /// Get video codec configuration (AVC decoder config)
  Uint8List? get videoCodecConfig => _decoder.videoCodecConfig;

  /// Check if ready to decode video (has received keyframe)
  bool get isVideoReady => _decoder.hasReceivedKeyframe;

  /// Statistics
  int get videoFramesReceived => _videoFramesReceived;
  int get audioFramesReceived => _audioFramesReceived;
  int get videoFramesDropped => _videoFramesDropped;
  int get audioFramesDropped => _audioFramesDropped;
  int get videoBufferSize => _videoBuffer.length;
  int get audioBufferSize => _audioBuffer.length;
  int get videoBufferedMs => _videoBuffer.bufferedMs;
  int get audioBufferedMs => _audioBuffer.bufferedMs;

  /// Reset the pipeline
  void reset() {
    _decoder.reset();
    _videoBuffer.clear();
    _audioBuffer.clear();
    _videoFramesReceived = 0;
    _audioFramesReceived = 0;
    _videoFramesDropped = 0;
    _audioFramesDropped = 0;
  }

  /// Dispose resources
  void dispose() {
    _videoBuffer.dispose();
    _audioBuffer.dispose();
    _videoFrameController.close();
    _audioFrameController.close();
  }
}
