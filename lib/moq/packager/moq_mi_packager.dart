import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart';
import '../protocol/moq_messages.dart';

/// MoQ Media Interop (moq-mi) Packager
///
/// Implements draft-cenzano-moq-media-interop-03 for LOC-based
/// media packaging with extension headers.
///
/// This packager uses LOC (low overhead container) format where
/// codec-specific metadata is carried in extension headers rather
/// than being embedded in the payload.

/// Version of the moq-mi packager implementation
const String moqMiPackagerVersion = '03';

/// Extension Header Types for moq-mi
class MoqMiExtensionHeaders {
  /// Media type header (REQUIRED for all objects)
  static const int mediaType = 0x0A;

  /// Video H264 in AVCC extradata (REQUIRED for first video object / codec changes)
  static const int videoH264AvccExtradata = 0x0D;

  /// Audio Opus metadata header (REQUIRED for Opus audio)
  static const int audioOpusMetadata = 0x0F;

  /// Text UTF-8 metadata header
  static const int textUtf8Metadata = 0x11;

  /// Audio AAC-LC metadata header (REQUIRED for AAC audio)
  static const int audioAacLcMetadata = 0x13;

  /// Video H264 in AVCC metadata header (REQUIRED for video)
  static const int videoH264AvccMetadata = 0x15;
}

/// Media Type Values for MOQ_EXT_HEADER_TYPE_MOQMI_MEDIA_TYPE (0x0A)
enum MoqMiMediaType {
  /// H.264 video in AVCC format (4-byte length prefix NALUs)
  videoH264Avcc(0x00),

  /// Opus audio bitstream (raw Opus packets per RFC 6716)
  audioOpusBitstream(0x01),

  /// UTF-8 text
  textUtf8(0x02),

  /// AAC-LC audio in MPEG-4 format (raw_data_block())
  audioAacLcMpeg4(0x03);

  final int value;
  const MoqMiMediaType(this.value);

  static MoqMiMediaType? fromValue(int value) {
    for (final type in MoqMiMediaType.values) {
      if (type.value == value) return type;
    }
    return null; // Unknown media type
  }
}

/// Generate moq-mi compliant track name
///
/// Track names follow the pattern: {prefix}audio0, {prefix}video0
String moqMiGetTrackName(String trackPrefix, bool isAudio) {
  final suffix = isAudio ? 'audio0' : 'video0';
  return '$trackPrefix$suffix';
}

/// Video H264 AVCC metadata for extension header 0x15
///
/// Contains: seqId, pts, dts, timebase, duration, wallclock
class VideoH264AvccMetadata {
  final Int64 seqId;
  final Int64 pts;
  final Int64 dts;
  final Int64 timebase;
  final Int64 duration;
  final Int64 wallclock;

  const VideoH264AvccMetadata({
    required this.seqId,
    required this.pts,
    required this.dts,
    required this.timebase,
    required this.duration,
    required this.wallclock,
  });

  /// Serialize to bytes for extension header value
  Uint8List toBytes() {
    final parts = <Uint8List>[
      MoQWireFormat.encodeVarint64(seqId),
      MoQWireFormat.encodeVarint64(pts),
      MoQWireFormat.encodeVarint64(dts),
      MoQWireFormat.encodeVarint64(timebase),
      MoQWireFormat.encodeVarint64(duration),
      MoQWireFormat.encodeVarint64(wallclock),
    ];

    final totalLen = parts.fold<int>(0, (sum, p) => sum + p.length);
    final result = Uint8List(totalLen);
    int offset = 0;
    for (final part in parts) {
      result.setAll(offset, part);
      offset += part.length;
    }
    return result;
  }

  /// Deserialize from extension header value bytes
  factory VideoH264AvccMetadata.fromBytes(Uint8List data) {
    int offset = 0;

    final (seqId, seqIdLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += seqIdLen;

    final (pts, ptsLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += ptsLen;

    final (dts, dtsLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += dtsLen;

    final (timebase, timebaseLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += timebaseLen;

    final (duration, durationLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += durationLen;

    final (wallclock, _) = MoQWireFormat.decodeVarint64(data, offset);

    return VideoH264AvccMetadata(
      seqId: seqId,
      pts: pts,
      dts: dts,
      timebase: timebase,
      duration: duration,
      wallclock: wallclock,
    );
  }
}

/// Audio Opus/AAC metadata for extension headers 0x0F and 0x13
///
/// Contains: seqId, pts, timebase, sampleFreq, numChannels, duration, wallclock
class AudioMetadata {
  final Int64 seqId;
  final Int64 pts;
  final Int64 timebase;
  final Int64 sampleFreq;
  final Int64 numChannels;
  final Int64 duration;
  final Int64 wallclock;

  const AudioMetadata({
    required this.seqId,
    required this.pts,
    required this.timebase,
    required this.sampleFreq,
    required this.numChannels,
    required this.duration,
    required this.wallclock,
  });

  /// Serialize to bytes for extension header value
  Uint8List toBytes() {
    final parts = <Uint8List>[
      MoQWireFormat.encodeVarint64(seqId),
      MoQWireFormat.encodeVarint64(pts),
      MoQWireFormat.encodeVarint64(timebase),
      MoQWireFormat.encodeVarint64(sampleFreq),
      MoQWireFormat.encodeVarint64(numChannels),
      MoQWireFormat.encodeVarint64(duration),
      MoQWireFormat.encodeVarint64(wallclock),
    ];

    final totalLen = parts.fold<int>(0, (sum, p) => sum + p.length);
    final result = Uint8List(totalLen);
    int offset = 0;
    for (final part in parts) {
      result.setAll(offset, part);
      offset += part.length;
    }
    return result;
  }

  /// Deserialize from extension header value bytes
  factory AudioMetadata.fromBytes(Uint8List data) {
    int offset = 0;

    final (seqId, seqIdLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += seqIdLen;

    final (pts, ptsLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += ptsLen;

    final (timebase, timebaseLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += timebaseLen;

    final (sampleFreq, sampleFreqLen) =
        MoQWireFormat.decodeVarint64(data, offset);
    offset += sampleFreqLen;

    final (numChannels, numChannelsLen) =
        MoQWireFormat.decodeVarint64(data, offset);
    offset += numChannelsLen;

    final (duration, durationLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += durationLen;

    final (wallclock, _) = MoQWireFormat.decodeVarint64(data, offset);

    return AudioMetadata(
      seqId: seqId,
      pts: pts,
      timebase: timebase,
      sampleFreq: sampleFreq,
      numChannels: numChannels,
      duration: duration,
      wallclock: wallclock,
    );
  }
}

/// Parsed moq-mi data from extension headers
class MoqMiData {
  final MoqMiMediaType mediaType;
  final Int64 seqId;
  final Int64 pts;
  final Int64 timebase;
  final Int64 duration;
  final Int64 wallclock;
  final Uint8List data;

  // Video-specific
  final Int64? dts;
  final Uint8List? avcDecoderConfig;

  // Audio-specific
  final Int64? sampleFreq;
  final Int64? numChannels;

  MoqMiData({
    required this.mediaType,
    required this.seqId,
    required this.pts,
    required this.timebase,
    required this.duration,
    required this.wallclock,
    required this.data,
    this.dts,
    this.avcDecoderConfig,
    this.sampleFreq,
    this.numChannels,
  });

  bool get isVideo => mediaType == MoqMiMediaType.videoH264Avcc;
  bool get isAudio =>
      mediaType == MoqMiMediaType.audioOpusBitstream ||
      mediaType == MoqMiMediaType.audioAacLcMpeg4;
  bool get isOpus => mediaType == MoqMiMediaType.audioOpusBitstream;
  bool get isAac => mediaType == MoqMiMediaType.audioAacLcMpeg4;
}

/// MoQ Media Interop Packager
///
/// Packages video and audio frames with moq-mi compliant extension headers.
class MoqMiPackager {
  Int64 _videoSeqId = Int64.ZERO;
  Int64 _audioSeqId = Int64.ZERO;
  Uint8List? _lastVideoExtradata;

  /// Reset packager state (e.g., when starting a new stream)
  void reset() {
    _videoSeqId = Int64.ZERO;
    _audioSeqId = Int64.ZERO;
    _lastVideoExtradata = null;
  }

  /// Create extension headers for a video H.264 AVCC frame
  ///
  /// Parameters:
  /// - [pts]: Presentation timestamp in timebase units
  /// - [dts]: Decode timestamp in timebase units
  /// - [timebase]: Timebase (e.g., 90000 for 90kHz)
  /// - [duration]: Duration in timebase units
  /// - [avcDecoderConfig]: AVC decoder configuration record (SPS/PPS) - only needed for keyframes or codec changes
  ///
  /// Returns extension headers list to be used with SubgroupHeader or ObjectDatagram
  List<KeyValuePair> createVideoExtensionHeaders({
    required Int64 pts,
    required Int64 dts,
    required Int64 timebase,
    required Int64 duration,
    Uint8List? avcDecoderConfig,
  }) {
    final seqId = _videoSeqId++;
    final wallclock = Int64(DateTime.now().millisecondsSinceEpoch);

    final headers = <KeyValuePair>[];

    // Media type header (REQUIRED)
    headers.add(KeyValuePair(
      type: MoqMiExtensionHeaders.mediaType,
      value: Uint8List.fromList([MoqMiMediaType.videoH264Avcc.value]),
    ));

    // Video metadata header (REQUIRED)
    final metadata = VideoH264AvccMetadata(
      seqId: seqId,
      pts: pts,
      dts: dts,
      timebase: timebase,
      duration: duration,
      wallclock: wallclock,
    );
    headers.add(KeyValuePair(
      type: MoqMiExtensionHeaders.videoH264AvccMetadata,
      value: metadata.toBytes(),
    ));

    // AVC decoder config (extradata) - only if provided and changed
    if (avcDecoderConfig != null) {
      bool needsExtradata = _lastVideoExtradata == null ||
          !_areListsEqual(_lastVideoExtradata!, avcDecoderConfig);

      if (needsExtradata) {
        headers.add(KeyValuePair(
          type: MoqMiExtensionHeaders.videoH264AvccExtradata,
          value: avcDecoderConfig,
        ));
        _lastVideoExtradata = Uint8List.fromList(avcDecoderConfig);
      }
    }

    return headers;
  }

  /// Create extension headers for an Opus audio frame
  ///
  /// Parameters:
  /// - [pts]: Presentation timestamp in timebase units
  /// - [timebase]: Timebase (e.g., 48000 for 48kHz)
  /// - [sampleFreq]: Sample frequency in Hz (e.g., 48000)
  /// - [numChannels]: Number of audio channels
  /// - [duration]: Duration in timebase units
  ///
  /// Returns extension headers list
  List<KeyValuePair> createOpusExtensionHeaders({
    required Int64 pts,
    required Int64 timebase,
    required Int64 sampleFreq,
    required int numChannels,
    required Int64 duration,
  }) {
    final seqId = _audioSeqId++;
    final wallclock = Int64(DateTime.now().millisecondsSinceEpoch);

    final headers = <KeyValuePair>[];

    // Media type header (REQUIRED)
    headers.add(KeyValuePair(
      type: MoqMiExtensionHeaders.mediaType,
      value: Uint8List.fromList([MoqMiMediaType.audioOpusBitstream.value]),
    ));

    // Audio metadata header (REQUIRED)
    final metadata = AudioMetadata(
      seqId: seqId,
      pts: pts,
      timebase: timebase,
      sampleFreq: sampleFreq,
      numChannels: Int64(numChannels),
      duration: duration,
      wallclock: wallclock,
    );
    headers.add(KeyValuePair(
      type: MoqMiExtensionHeaders.audioOpusMetadata,
      value: metadata.toBytes(),
    ));

    return headers;
  }

  /// Create extension headers for an AAC-LC audio frame
  ///
  /// Parameters:
  /// - [pts]: Presentation timestamp in timebase units
  /// - [timebase]: Timebase (e.g., 48000 for 48kHz)
  /// - [sampleFreq]: Sample frequency in Hz
  /// - [numChannels]: Number of audio channels
  /// - [duration]: Duration in timebase units
  ///
  /// Returns extension headers list
  List<KeyValuePair> createAacExtensionHeaders({
    required Int64 pts,
    required Int64 timebase,
    required Int64 sampleFreq,
    required int numChannels,
    required Int64 duration,
  }) {
    final seqId = _audioSeqId++;
    final wallclock = Int64(DateTime.now().millisecondsSinceEpoch);

    final headers = <KeyValuePair>[];

    // Media type header (REQUIRED)
    headers.add(KeyValuePair(
      type: MoqMiExtensionHeaders.mediaType,
      value: Uint8List.fromList([MoqMiMediaType.audioAacLcMpeg4.value]),
    ));

    // Audio metadata header (REQUIRED)
    final metadata = AudioMetadata(
      seqId: seqId,
      pts: pts,
      timebase: timebase,
      sampleFreq: sampleFreq,
      numChannels: Int64(numChannels),
      duration: duration,
      wallclock: wallclock,
    );
    headers.add(KeyValuePair(
      type: MoqMiExtensionHeaders.audioAacLcMetadata,
      value: metadata.toBytes(),
    ));

    return headers;
  }

  /// Parse extension headers to extract moq-mi data
  ///
  /// Returns parsed data or null if not a valid moq-mi object
  static MoqMiData? parseExtensionHeaders(
    List<KeyValuePair> extensionHeaders,
    Uint8List payload,
  ) {
    // Debug: log all received extension headers
    final headerInfo = extensionHeaders.map((h) =>
        '0x${h.type.toRadixString(16)}:${h.value?.length ?? 0}b').join(', ');
    debugPrint('MoqMiPackager: Extension headers: [$headerInfo], payload: ${payload.length}b');

    MoqMiMediaType? mediaType;
    VideoH264AvccMetadata? videoMetadata;
    AudioMetadata? audioMetadata;
    Uint8List? avcDecoderConfig;

    for (final header in extensionHeaders) {
      if (header.value == null) continue;

      switch (header.type) {
        case MoqMiExtensionHeaders.mediaType:
          if (header.value!.isNotEmpty) {
            final typeValue = header.value![0];
            mediaType = MoqMiMediaType.fromValue(typeValue);
            if (mediaType == null) {
              debugPrint('MoqMiPackager: Unknown media type value: 0x${typeValue.toRadixString(16)}');
            }
          }
          break;

        case MoqMiExtensionHeaders.videoH264AvccMetadata:
          try {
            videoMetadata = VideoH264AvccMetadata.fromBytes(header.value!);
          } catch (e) {
            debugPrint('MoqMiPackager: Failed to parse video metadata: $e');
          }
          break;

        case MoqMiExtensionHeaders.videoH264AvccExtradata:
          avcDecoderConfig = header.value;
          break;

        case MoqMiExtensionHeaders.audioOpusMetadata:
        case MoqMiExtensionHeaders.audioAacLcMetadata:
          try {
            audioMetadata = AudioMetadata.fromBytes(header.value!);
          } catch (e) {
            debugPrint('MoqMiPackager: Failed to parse audio metadata: $e');
          }
          break;
      }
    }

    if (mediaType == null) {
      debugPrint('MoqMiPackager: No media type header (0x0A) found');
      return null;
    }

    if (mediaType == MoqMiMediaType.videoH264Avcc) {
      if (videoMetadata == null) {
        debugPrint('MoqMiPackager: Video media type but missing video metadata header (0x15)');
        return null;
      }
      // Log extradata presence for debugging
      if (avcDecoderConfig != null) {
        debugPrint('MoqMiPackager: Video has extradata (${avcDecoderConfig.length} bytes)');
      }
      return MoqMiData(
        mediaType: mediaType,
        seqId: videoMetadata.seqId,
        pts: videoMetadata.pts,
        dts: videoMetadata.dts,
        timebase: videoMetadata.timebase,
        duration: videoMetadata.duration,
        wallclock: videoMetadata.wallclock,
        data: payload,
        avcDecoderConfig: avcDecoderConfig,
      );
    }

    if (mediaType == MoqMiMediaType.audioOpusBitstream ||
        mediaType == MoqMiMediaType.audioAacLcMpeg4) {
      if (audioMetadata == null) {
        final expectedHeader = mediaType == MoqMiMediaType.audioOpusBitstream ? '0x0F' : '0x13';
        debugPrint('MoqMiPackager: Audio media type but missing audio metadata header ($expectedHeader)');
        return null;
      }
      return MoqMiData(
        mediaType: mediaType,
        seqId: audioMetadata.seqId,
        pts: audioMetadata.pts,
        timebase: audioMetadata.timebase,
        duration: audioMetadata.duration,
        wallclock: audioMetadata.wallclock,
        data: payload,
        sampleFreq: audioMetadata.sampleFreq,
        numChannels: audioMetadata.numChannels,
      );
    }

    debugPrint('MoqMiPackager: Unhandled media type: $mediaType');
    return null;
  }

  /// Get current video sequence ID (for debugging)
  Int64 get videoSeqId => _videoSeqId;

  /// Get current audio sequence ID (for debugging)
  Int64 get audioSeqId => _audioSeqId;

  static bool _areListsEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
