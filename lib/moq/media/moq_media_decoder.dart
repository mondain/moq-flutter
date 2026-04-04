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
  Int64 _locVideoSeqId = Int64(0);
  Int64 _locAudioSeqId = Int64(0);

  /// Decode a MoQ object into a media frame
  ///
  /// Supports both moq-mi format (with extension headers carrying metadata)
  /// and raw LOC format (no extension headers, raw codec data).
  ///
  /// Returns null if:
  /// - Object has no payload
  /// - Waiting for keyframe (video)
  MediaFrame? decode(MoQObject object) {
    if (object.payload == null || object.payload!.isEmpty) {
      debugPrint('MoqMediaDecoder: Object has no payload');
      return null;
    }

    // Convert extension headers from the object
    final extensionHeaders = object.extensionHeaders
        .map((h) => KeyValuePair(type: h.type, value: h.value, intValue: h.intValue))
        .toList();

    if (extensionHeaders.isEmpty) {
      // No extension headers -> LOC format: raw codec data
      return _decodeLoc(object);
    }

    // Check for moq-mi media type header (0x0A) before attempting parse.
    // MSF/LOC objects may carry transport-level extension headers (e.g. 0x2,
    // 0x6) that are not moq-mi; skip the moq-mi path entirely for those.
    final hasMoqMiMediaType = extensionHeaders.any(
      (h) => h.type == MoqMiExtensionHeaders.mediaType,
    );

    if (hasMoqMiMediaType) {
      final moqMiData = MoqMiPackager.parseExtensionHeaders(
        extensionHeaders,
        object.payload!,
      );

      if (moqMiData != null) {
        if (moqMiData.isVideo) {
          return _decodeVideoFrame(moqMiData);
        } else if (moqMiData.isAudio) {
          return _decodeAudioFrame(moqMiData);
        }
        return null;
      }
    }

    // No moq-mi media type or parse failed -> LOC decode
    return _decodeLoc(object);
  }

  /// Decode a raw LOC object (no moq-mi extension headers)
  ///
  /// Infers media type from the track name (video/audio) and treats
  /// the payload as raw codec data (H.264 NALUs or Opus/AAC frames).
  MediaFrame? _decodeLoc(MoQObject object) {
    final trackName = String.fromCharCodes(object.trackName);
    final isVideo = trackName.contains('video') ||
        trackName.endsWith('.m4s') && !trackName.contains('audio');
    final isAudio = trackName.contains('audio');

    final now = Int64(DateTime.now().millisecondsSinceEpoch);

    if (isVideo) {
      return _decodeLocVideo(object, now);
    } else if (isAudio) {
      return _decodeLocAudio(object, now);
    }

    debugPrint('MoqMediaDecoder: LOC object on unknown track "$trackName"');
    return null;
  }

  MediaFrame? _decodeLocVideo(MoQObject object, Int64 wallclock) {
    final data = object.payload!;
    final isKeyframe = _isH264Keyframe(data);

    if (isKeyframe) {
      _hasReceivedKeyframe = true;
      // Extract SPS/PPS from keyframe NALs to build AVC decoder config
      final config = _extractAvcDecoderConfig(data);
      if (config != null) {
        _lastVideoCodecConfig = config;
        debugPrint('MoqMediaDecoder: LOC extracted AVC config '
            '(${config.length} bytes) from keyframe');
      }
    }

    if (!_hasReceivedKeyframe) {
      debugPrint('MoqMediaDecoder: LOC video waiting for keyframe '
          '(${data.length} bytes)');
      return null;
    }

    _locVideoSeqId += Int64.ONE;
    return MediaFrame(
      type: MediaFrameType.videoH264,
      seqId: _locVideoSeqId,
      pts: object.objectId,
      dts: object.objectId,
      timebase: Int64(90000),
      duration: Int64(3000), // ~33ms at 90kHz
      wallclock: wallclock,
      data: data,
      codecConfig: isKeyframe ? _lastVideoCodecConfig : null,
      isKeyframe: isKeyframe,
    );
  }

  /// Extract SPS and PPS NAL units from H.264 data and build an
  /// AVCDecoderConfigurationRecord for the fMP4 init segment.
  /// Handles both Annex-B (start codes) and AVCC (length-prefixed) formats.
  Uint8List? _extractAvcDecoderConfig(Uint8List data) {
    final nalUnits = _extractNalUnits(data);
    Uint8List? sps;
    Uint8List? pps;

    for (final nal in nalUnits) {
      if (nal.isEmpty) continue;
      final nalType = nal[0] & 0x1F;
      if (nalType == 7 && sps == null) sps = nal; // SPS
      if (nalType == 8 && pps == null) pps = nal; // PPS
    }

    if (sps == null || pps == null) return null;

    // Build AVCDecoderConfigurationRecord
    // configurationVersion(1) + AVCProfileIndication(1) +
    // profile_compatibility(1) + AVCLevelIndication(1) +
    // lengthSizeMinusOne(1) + numSPS(1) + spsLength(2) + sps +
    // numPPS(1) + ppsLength(2) + pps
    final config = Uint8List(11 + sps.length + pps.length);
    int off = 0;
    config[off++] = 1; // configurationVersion
    config[off++] = sps.length > 1 ? sps[1] : 0x42; // profile
    config[off++] = sps.length > 2 ? sps[2] : 0x00; // compatibility
    config[off++] = sps.length > 3 ? sps[3] : 0x1E; // level
    config[off++] = 0xFF; // 6 bits reserved (111111) + 2 bits NALU length size - 1 (11 = 4 bytes)
    config[off++] = 0xE1; // 3 bits reserved (111) + 5 bits number of SPS (1)
    config[off++] = (sps.length >> 8) & 0xFF;
    config[off++] = sps.length & 0xFF;
    config.setAll(off, sps);
    off += sps.length;
    config[off++] = 1; // number of PPS
    config[off++] = (pps.length >> 8) & 0xFF;
    config[off++] = pps.length & 0xFF;
    config.setAll(off, pps);

    return config;
  }

  /// Extract individual NAL units from H.264 data in either Annex-B or AVCC format.
  List<Uint8List> _extractNalUnits(Uint8List data) {
    final nals = <Uint8List>[];

    // Try Annex-B first (start codes)
    if (_hasAnnexBStartCodes(data)) {
      int i = 0;
      while (i < data.length) {
        // Find start code
        int startCodeLen = 0;
        if (i + 3 < data.length &&
            data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1) {
          startCodeLen = 4;
        } else if (i + 2 < data.length &&
            data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
          startCodeLen = 3;
        }

        if (startCodeLen > 0) {
          final nalStart = i + startCodeLen;
          // Find next start code or end
          int nalEnd = data.length;
          for (int j = nalStart; j < data.length - 2; j++) {
            if (data[j] == 0 && data[j + 1] == 0 &&
                (data[j + 2] == 1 || (j + 3 < data.length && data[j + 2] == 0 && data[j + 3] == 1))) {
              nalEnd = j;
              break;
            }
          }
          if (nalStart < nalEnd) {
            nals.add(data.sublist(nalStart, nalEnd));
          }
          i = nalEnd;
        } else {
          i++;
        }
      }
    } else {
      // AVCC format (4-byte length prefix)
      int offset = 0;
      while (offset + 4 < data.length) {
        final nalLength = (data[offset] << 24) | (data[offset + 1] << 16) |
            (data[offset + 2] << 8) | data[offset + 3];
        if (nalLength <= 0 || nalLength > data.length - offset - 4) break;
        nals.add(data.sublist(offset + 4, offset + 4 + nalLength));
        offset += 4 + nalLength;
      }
    }

    return nals;
  }

  bool _hasAnnexBStartCodes(Uint8List data) {
    for (int i = 0; i < data.length - 3; i++) {
      if (data[i] == 0 && data[i + 1] == 0) {
        if (data[i + 2] == 1 || (i + 3 < data.length && data[i + 2] == 0 && data[i + 3] == 1)) {
          return true;
        }
      }
    }
    return false;
  }

  MediaFrame? _decodeLocAudio(MoQObject object, Int64 wallclock) {
    _locAudioSeqId += Int64.ONE;
    return MediaFrame(
      type: MediaFrameType.audioOpus,
      seqId: _locAudioSeqId,
      pts: object.objectId,
      dts: object.objectId,
      timebase: Int64(48000),
      duration: Int64(960), // 20ms at 48kHz
      wallclock: wallclock,
      data: object.payload!,
      sampleRate: Int64(48000),
      channels: 2,
    );
  }

  MediaFrame? _decodeVideoFrame(MoqMiData data) {
    // Check for codec config (indicates keyframe)
    Uint8List? codecConfig = data.avcDecoderConfig;
    bool isKeyframe = false;

    if (codecConfig != null && codecConfig.isNotEmpty) {
      _lastVideoCodecConfig = codecConfig;
      _hasReceivedKeyframe = true;
      isKeyframe = true;
      debugPrint('MoqMediaDecoder: Got extradata (${codecConfig.length} bytes) - KEYFRAME');
    } else {
      // Check if this is a keyframe by looking at NAL unit type
      isKeyframe = _isH264Keyframe(data.data);
      if (isKeyframe) {
        _hasReceivedKeyframe = true;
        debugPrint('MoqMediaDecoder: Detected IDR NAL - KEYFRAME');
      }
    }

    // Don't output frames until we have a keyframe
    if (!_hasReceivedKeyframe) {
      // Log first 16 bytes of video data to understand format
      final preview = data.data.take(16).map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ');
      debugPrint('MoqMediaDecoder: Waiting for keyframe. Data preview: $preview (${data.data.length} bytes)');
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

  /// Check if H.264 data contains a keyframe (IDR NAL)
  /// Handles both AVCC format (length-prefixed) and Annex-B format (start codes)
  bool _isH264Keyframe(Uint8List data) {
    if (data.length < 5) return false;

    // First try AVCC format (4-byte length prefix)
    if (_isAvccKeyframe(data)) {
      return true;
    }

    // Try Annex-B format (start codes 0x00 0x00 0x00 0x01 or 0x00 0x00 0x01)
    return _isAnnexBKeyframe(data);
  }

  /// Check AVCC format (4-byte big-endian length prefix)
  bool _isAvccKeyframe(Uint8List data) {
    int offset = 0;
    while (offset + 4 < data.length) {
      // Read 4-byte big-endian length
      final nalLength = (data[offset] << 24) |
          (data[offset + 1] << 16) |
          (data[offset + 2] << 8) |
          data[offset + 3];

      // Sanity check - if length looks unreasonable, this isn't AVCC format
      if (nalLength <= 0 || nalLength > data.length - offset - 4) {
        return false;
      }

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

  /// Check Annex-B format (start codes)
  bool _isAnnexBKeyframe(Uint8List data) {
    int offset = 0;
    while (offset < data.length - 4) {
      // Look for 4-byte start code (0x00 0x00 0x00 0x01)
      if (data[offset] == 0x00 && data[offset + 1] == 0x00 &&
          data[offset + 2] == 0x00 && data[offset + 3] == 0x01) {
        if (offset + 4 < data.length) {
          final nalType = data[offset + 4] & 0x1F;
          if (nalType == 5 || nalType == 7 || nalType == 8) {
            return true;
          }
        }
        offset += 4;
      }
      // Look for 3-byte start code (0x00 0x00 0x01)
      else if (data[offset] == 0x00 && data[offset + 1] == 0x00 &&
               data[offset + 2] == 0x01) {
        if (offset + 3 < data.length) {
          final nalType = data[offset + 3] & 0x1F;
          if (nalType == 5 || nalType == 7 || nalType == 8) {
            return true;
          }
        }
        offset += 3;
      }
      else {
        offset++;
      }
    }
    return false;
  }

  /// Reset decoder state (e.g., after seek or disconnect)
  void reset() {
    _lastVideoCodecConfig = null;
    _hasReceivedKeyframe = false;
    _locVideoSeqId = Int64(0);
    _locAudioSeqId = Int64(0);
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
/// Decodes MoQ objects into media frames. When [useJitterBuffer] is true
/// (default for moq-mi where frames may arrive out of order), frames pass
/// through jitter buffers for reordering. When false (LOC streams that
/// arrive in transport order), frames are emitted directly to avoid the
/// 10ms polling latency that causes audio glitches on 20ms Opus frames.
class MoqMediaPipeline {
  final MoqMediaDecoder _decoder = MoqMediaDecoder();
  final bool useJitterBuffer;
  late final MediaJitterBuffer? _videoBuffer;
  late final MediaJitterBuffer? _audioBuffer;

  final _videoFrameController = StreamController<MediaFrame>.broadcast();
  final _audioFrameController = StreamController<MediaFrame>.broadcast();

  int _videoFramesReceived = 0;
  int _audioFramesReceived = 0;
  int _videoFramesDropped = 0;
  int _audioFramesDropped = 0;

  MoqMediaPipeline({
    this.useJitterBuffer = false,
    int videoBufferSize = 30,
    Duration videoMaxDelay = const Duration(milliseconds: 200),
    int audioBufferSize = 50,
    Duration audioMaxDelay = const Duration(milliseconds: 100),
  }) {
    if (useJitterBuffer) {
      _videoBuffer = MediaJitterBuffer(
        maxSize: videoBufferSize,
        maxDelay: videoMaxDelay,
      );
      _audioBuffer = MediaJitterBuffer(
        maxSize: audioBufferSize,
        maxDelay: audioMaxDelay,
      );
      _videoBuffer!.frameStream.listen((frame) {
        _videoFrameController.add(frame);
      });
      _audioBuffer!.frameStream.listen((frame) {
        _audioFrameController.add(frame);
      });
    } else {
      _videoBuffer = null;
      _audioBuffer = null;
    }
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
      if (useJitterBuffer) {
        _videoBuffer!.addFrame(frame);
      } else {
        _videoFrameController.add(frame);
      }
      if (_videoFramesReceived % 30 == 1) {
        debugPrint('MoqMediaPipeline: Video frame ${frame.seqId}, keyframe=${frame.isKeyframe}, '
            'size=${frame.data.length}, total=$_videoFramesReceived');
      }
    } else {
      _audioFramesReceived++;
      if (useJitterBuffer) {
        _audioBuffer!.addFrame(frame);
      } else {
        _audioFrameController.add(frame);
      }
      if (_audioFramesReceived % 50 == 1) {
        debugPrint('MoqMediaPipeline: Audio frame ${frame.seqId}, '
            'type=${frame.type}, total=$_audioFramesReceived');
      }
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
  int get videoBufferSize => _videoBuffer?.length ?? 0;
  int get audioBufferSize => _audioBuffer?.length ?? 0;
  int get videoBufferedMs => _videoBuffer?.bufferedMs ?? 0;
  int get audioBufferedMs => _audioBuffer?.bufferedMs ?? 0;

  /// Reset the pipeline
  void reset() {
    _decoder.reset();
    _videoBuffer?.clear();
    _audioBuffer?.clear();
    _videoFramesReceived = 0;
    _audioFramesReceived = 0;
    _videoFramesDropped = 0;
    _audioFramesDropped = 0;
  }

  /// Dispose resources
  void dispose() {
    _videoBuffer?.dispose();
    _audioBuffer?.dispose();
    _videoFrameController.close();
    _audioFrameController.close();
  }
}
