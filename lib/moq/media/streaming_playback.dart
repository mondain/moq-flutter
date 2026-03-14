import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'moq_media_decoder.dart';
import 'fmp4/fmp4_boxes.dart';
import 'fmp4/aac_fmp4_muxer.dart';

/// Streaming fMP4 muxer for AVCC H.264 video
///
/// Unlike H264Fmp4Muxer which expects Annex B format, this muxer
/// accepts H.264 data already in AVCC format (4-byte length prefix NALUs)
/// as delivered by moq-mi.
class AvccFmp4Muxer {
  final int width;
  final int height;
  final int timescale;
  final int trackId;

  // AVC decoder config from moq-mi (already in the correct format)
  Uint8List? _avcDecoderConfig;
  Uint8List? _initSegment;

  // Fragment state
  int _sequenceNumber = 0;
  int _baseDecodeTime = 0;

  AvccFmp4Muxer({
    this.width = 1920,
    this.height = 1080,
    this.timescale = 90000,
    this.trackId = 1,
  });

  /// Set AVC decoder configuration record from moq-mi
  ///
  /// This is passed directly from the moq-mi avcDecoderConfig extension header
  void setAvcDecoderConfig(Uint8List config) {
    _avcDecoderConfig = config;
    _initSegment = null;
  }

  /// Check if init segment is ready
  bool get isInitReady => _avcDecoderConfig != null;

  /// Get codec string from AVC decoder config
  String? get codecString {
    if (_avcDecoderConfig == null || _avcDecoderConfig!.length < 4) return null;
    final profile = _avcDecoderConfig![1];
    final constraints = _avcDecoderConfig![2];
    final level = _avcDecoderConfig![3];
    return 'avc1.${profile.toRadixString(16).padLeft(2, '0')}${constraints.toRadixString(16).padLeft(2, '0')}${level.toRadixString(16).padLeft(2, '0')}';
  }

  /// Get init segment (ftyp + moov)
  Uint8List? get initSegment {
    if (!isInitReady) return null;
    _initSegment ??= _createInitSegment();
    return _initSegment;
  }

  /// Create a media segment from a MediaFrame
  ///
  /// [frame] must be a video frame with AVCC data
  Uint8List createMediaSegment(MediaFrame frame) {
    final durationInTimescale =
        (frame.duration * Int64(timescale) ~/ frame.timebase).toInt();

    // Create moof
    final moof = writeMoof(
      sequenceNumber: ++_sequenceNumber,
      trackId: trackId,
      baseMediaDecodeTime: _baseDecodeTime,
      sampleSizes: [frame.data.length],
      sampleDurations: [durationInTimescale],
      sampleFlags: [
        frame.isKeyframe ? SampleFlags.keyframe : SampleFlags.nonKeyframe,
      ],
    );

    // Update data offset in trun
    final moofWithOffset = _updateTrunDataOffset(moof, moof.length + 8);

    // Create mdat
    final mdat = writeMdat(frame.data);

    // Update base decode time
    _baseDecodeTime += durationInTimescale;

    // Combine moof + mdat
    final result = Uint8List(moofWithOffset.length + mdat.length);
    result.setAll(0, moofWithOffset);
    result.setAll(moofWithOffset.length, mdat);

    return result;
  }

  /// Reset muxer state
  void reset() {
    _sequenceNumber = 0;
    _baseDecodeTime = 0;
    _initSegment = null;
  }

  /// Build the video trak box for use in a combined init segment.
  /// Requires setAvcDecoderConfig to have been called first.
  Uint8List buildTrak() => _createTrak();

  Uint8List _createInitSegment() {
    final ftyp = writeFtyp(
      majorBrand: 'isom',
      minorVersion: 512,
      compatibleBrands: ['isom', 'iso6', 'avc1', 'mp41'],
    );

    final moov = _createMoov();

    final result = Uint8List(ftyp.length + moov.length);
    result.setAll(0, ftyp);
    result.setAll(ftyp.length, moov);

    return result;
  }

  Uint8List _createMoov() {
    final mvhd = writeMvhd(
      timescale: timescale,
      duration: 0,
      nextTrackId: trackId + 1,
    );

    final trak = _createTrak();
    final mvex = writeMvex(trackId: trackId);

    final moovSize = 8 + mvhd.length + trak.length + mvex.length;
    final result = Uint8List(moovSize);
    final header = writeBoxHeader(moovSize, 'moov');

    var offset = 0;
    result.setAll(offset, Uint8List.view(header.buffer));
    offset += 8;
    result.setAll(offset, mvhd);
    offset += mvhd.length;
    result.setAll(offset, trak);
    offset += trak.length;
    result.setAll(offset, mvex);

    return result;
  }

  Uint8List _createTrak() {
    final tkhd = writeTkhd(
      trackId: trackId,
      duration: 0,
      width: width,
      height: height,
      isVideo: true,
    );

    final mdia = _createMdia();

    final trakSize = 8 + tkhd.length + mdia.length;
    final result = Uint8List(trakSize);
    final header = writeBoxHeader(trakSize, 'trak');

    var offset = 0;
    result.setAll(offset, Uint8List.view(header.buffer));
    offset += 8;
    result.setAll(offset, tkhd);
    offset += tkhd.length;
    result.setAll(offset, mdia);

    return result;
  }

  Uint8List _createMdia() {
    final mdhd = writeMdhd(timescale: timescale, duration: 0);

    final hdlr = writeHdlr(handlerType: 'vide', name: 'VideoHandler');

    final minf = _createMinf();

    final mdiaSize = 8 + mdhd.length + hdlr.length + minf.length;
    final result = Uint8List(mdiaSize);
    final header = writeBoxHeader(mdiaSize, 'mdia');

    var offset = 0;
    result.setAll(offset, Uint8List.view(header.buffer));
    offset += 8;
    result.setAll(offset, mdhd);
    offset += mdhd.length;
    result.setAll(offset, hdlr);
    offset += hdlr.length;
    result.setAll(offset, minf);

    return result;
  }

  Uint8List _createMinf() {
    final vmhd = writeVmhd();
    final dinf = writeDinf();
    final stbl = _createStbl();

    final minfSize = 8 + vmhd.length + dinf.length + stbl.length;
    final result = Uint8List(minfSize);
    final header = writeBoxHeader(minfSize, 'minf');

    var offset = 0;
    result.setAll(offset, Uint8List.view(header.buffer));
    offset += 8;
    result.setAll(offset, vmhd);
    offset += vmhd.length;
    result.setAll(offset, dinf);
    offset += dinf.length;
    result.setAll(offset, stbl);

    return result;
  }

  Uint8List _createStbl() {
    final stsd = _createStsd();
    final stts = writeStts();
    final stsc = writeStsc();
    final stsz = writeStsz();
    final stco = writeStco();

    final stblSize =
        8 + stsd.length + stts.length + stsc.length + stsz.length + stco.length;
    final result = Uint8List(stblSize);
    final header = writeBoxHeader(stblSize, 'stbl');

    var offset = 0;
    result.setAll(offset, Uint8List.view(header.buffer));
    offset += 8;
    result.setAll(offset, stsd);
    offset += stsd.length;
    result.setAll(offset, stts);
    offset += stts.length;
    result.setAll(offset, stsc);
    offset += stsc.length;
    result.setAll(offset, stsz);
    offset += stsz.length;
    result.setAll(offset, stco);

    return result;
  }

  Uint8List _createStsd() {
    final avc1 = _createAvc1();

    final stsdSize = 12 + 4 + avc1.length;
    final data = ByteData(stsdSize);
    var offset = 0;

    data.setUint32(offset, stsdSize, Endian.big);
    offset += 4;
    data.setUint8(offset++, 's'.codeUnitAt(0));
    data.setUint8(offset++, 't'.codeUnitAt(0));
    data.setUint8(offset++, 's'.codeUnitAt(0));
    data.setUint8(offset++, 'd'.codeUnitAt(0));

    data.setUint32(offset, 0, Endian.big);
    offset += 4;

    data.setUint32(offset, 1, Endian.big);
    offset += 4;

    final result = Uint8List(stsdSize);
    result.setAll(0, Uint8List.view(data.buffer, 0, offset));
    result.setAll(offset, avc1);

    return result;
  }

  Uint8List _createAvc1() {
    final avcc = _createAvcc();

    final avc1Size = 8 + 78 + avcc.length;
    final data = ByteData(avc1Size);
    var offset = 0;

    data.setUint32(offset, avc1Size, Endian.big);
    offset += 4;
    data.setUint8(offset++, 'a'.codeUnitAt(0));
    data.setUint8(offset++, 'v'.codeUnitAt(0));
    data.setUint8(offset++, 'c'.codeUnitAt(0));
    data.setUint8(offset++, '1'.codeUnitAt(0));

    // Reserved (6 bytes)
    for (var i = 0; i < 6; i++) {
      data.setUint8(offset++, 0);
    }

    // Data reference index
    data.setUint16(offset, 1, Endian.big);
    offset += 2;

    // Pre-defined (2) + reserved (2) + pre-defined (3x4=12) = 16 bytes
    for (var i = 0; i < 16; i++) {
      data.setUint8(offset++, 0);
    }

    data.setUint16(offset, width, Endian.big);
    offset += 2;

    data.setUint16(offset, height, Endian.big);
    offset += 2;

    // Horizontal resolution (72 dpi)
    data.setUint32(offset, 0x00480000, Endian.big);
    offset += 4;

    // Vertical resolution (72 dpi)
    data.setUint32(offset, 0x00480000, Endian.big);
    offset += 4;

    data.setUint32(offset, 0, Endian.big);
    offset += 4;

    data.setUint16(offset, 1, Endian.big);
    offset += 2;

    // Compressor name (32 bytes)
    for (var i = 0; i < 32; i++) {
      data.setUint8(offset++, 0);
    }

    data.setUint16(offset, 0x0018, Endian.big);
    offset += 2;

    data.setInt16(offset, -1, Endian.big);
    offset += 2;

    final result = Uint8List(avc1Size);
    result.setAll(0, Uint8List.view(data.buffer, 0, offset));
    result.setAll(offset, avcc);

    return result;
  }

  /// Create avcC box using the raw AVC decoder config from moq-mi
  Uint8List _createAvcc() {
    if (_avcDecoderConfig == null) {
      throw StateError('AVC decoder config must be set');
    }

    // Wrap the raw config in an avcC box
    final avccSize = 8 + _avcDecoderConfig!.length;
    final result = Uint8List(avccSize);
    final header = writeBoxHeader(avccSize, 'avcC');

    result.setAll(0, Uint8List.view(header.buffer));
    result.setAll(8, _avcDecoderConfig!);

    return result;
  }

  Uint8List _updateTrunDataOffset(Uint8List moof, int dataOffset) {
    final result = Uint8List.fromList(moof);

    var offset = 8; // Skip moof header

    // Skip mfhd
    final mfhdSize =
        (result[offset] << 24) |
        (result[offset + 1] << 16) |
        (result[offset + 2] << 8) |
        result[offset + 3];
    offset += mfhdSize;

    // Skip traf header
    offset += 8;

    // Skip tfhd
    final tfhdSize =
        (result[offset] << 24) |
        (result[offset + 1] << 16) |
        (result[offset + 2] << 8) |
        result[offset + 3];
    offset += tfhdSize;

    // Skip tfdt
    final tfdtSize =
        (result[offset] << 24) |
        (result[offset + 1] << 16) |
        (result[offset + 2] << 8) |
        result[offset + 3];
    offset += tfdtSize;

    // Now at trun - skip header + version/flags + sample_count
    offset += 16;

    // Write data offset
    result[offset] = (dataOffset >> 24) & 0xFF;
    result[offset + 1] = (dataOffset >> 16) & 0xFF;
    result[offset + 2] = (dataOffset >> 8) & 0xFF;
    result[offset + 3] = dataOffset & 0xFF;

    return result;
  }
}

/// Streaming Opus fMP4 muxer for playback
///
/// Creates fMP4 segments from raw Opus packets for media_kit playback
class OpusStreamingMuxer {
  final int sampleRate;
  final int channels;
  final int trackId;

  Uint8List? _initSegment;
  int _sequenceNumber = 0;
  int _baseDecodeTime = 0;

  static const int opusTimescale = 48000;

  OpusStreamingMuxer({
    this.sampleRate = 48000,
    this.channels = 2,
    this.trackId = 2,
  });

  bool get isInitReady => true;

  Uint8List get initSegment {
    _initSegment ??= _createInitSegment();
    return _initSegment!;
  }

  /// Create a media segment from a MediaFrame
  Uint8List createMediaSegment(MediaFrame frame) {
    // Calculate duration in Opus timescale
    final durationInTimescale =
        (frame.duration * Int64(opusTimescale) ~/ frame.timebase).toInt();

    final moof = writeMoof(
      sequenceNumber: ++_sequenceNumber,
      trackId: trackId,
      baseMediaDecodeTime: _baseDecodeTime,
      sampleSizes: [frame.data.length],
      sampleDurations: [durationInTimescale],
      sampleFlags: [0x02000000], // Sync sample
    );

    final moofWithOffset = _updateTrunDataOffset(moof, moof.length + 8);
    final mdat = writeMdat(frame.data);

    _baseDecodeTime += durationInTimescale;

    final result = Uint8List(moofWithOffset.length + mdat.length);
    result.setAll(0, moofWithOffset);
    result.setAll(moofWithOffset.length, mdat);

    return result;
  }

  void reset() {
    _sequenceNumber = 0;
    _baseDecodeTime = 0;
    _initSegment = null;
  }

  /// Build the audio trak box for use in a combined init segment.
  Uint8List buildTrak() => _createTrak();

  Uint8List _createInitSegment() {
    final ftyp = writeFtyp(
      majorBrand: 'isom',
      minorVersion: 512,
      compatibleBrands: ['isom', 'iso6', 'mp41'],
    );

    final moov = _createMoov();

    final result = Uint8List(ftyp.length + moov.length);
    result.setAll(0, ftyp);
    result.setAll(ftyp.length, moov);

    return result;
  }

  Uint8List _createMoov() {
    final mvhd = writeMvhd(
      timescale: opusTimescale,
      duration: 0,
      nextTrackId: trackId + 1,
    );

    final trak = _createTrak();
    final mvex = writeMvex(trackId: trackId);

    final moovSize = 8 + mvhd.length + trak.length + mvex.length;
    final result = Uint8List(moovSize);
    final header = writeBoxHeader(moovSize, 'moov');

    var offset = 0;
    result.setAll(offset, Uint8List.view(header.buffer));
    offset += 8;
    result.setAll(offset, mvhd);
    offset += mvhd.length;
    result.setAll(offset, trak);
    offset += trak.length;
    result.setAll(offset, mvex);

    return result;
  }

  Uint8List _createTrak() {
    final tkhd = writeTkhd(
      trackId: trackId,
      duration: 0,
      width: 0,
      height: 0,
      isVideo: false,
    );

    final mdia = _createMdia();

    final trakSize = 8 + tkhd.length + mdia.length;
    final result = Uint8List(trakSize);
    final header = writeBoxHeader(trakSize, 'trak');

    var offset = 0;
    result.setAll(offset, Uint8List.view(header.buffer));
    offset += 8;
    result.setAll(offset, tkhd);
    offset += tkhd.length;
    result.setAll(offset, mdia);

    return result;
  }

  Uint8List _createMdia() {
    final mdhd = writeMdhd(timescale: opusTimescale, duration: 0);

    final hdlr = writeHdlr(handlerType: 'soun', name: 'SoundHandler');

    final minf = _createMinf();

    final mdiaSize = 8 + mdhd.length + hdlr.length + minf.length;
    final result = Uint8List(mdiaSize);
    final header = writeBoxHeader(mdiaSize, 'mdia');

    var offset = 0;
    result.setAll(offset, Uint8List.view(header.buffer));
    offset += 8;
    result.setAll(offset, mdhd);
    offset += mdhd.length;
    result.setAll(offset, hdlr);
    offset += hdlr.length;
    result.setAll(offset, minf);

    return result;
  }

  Uint8List _createMinf() {
    final smhd = writeSmhd();
    final dinf = writeDinf();
    final stbl = _createStbl();

    final minfSize = 8 + smhd.length + dinf.length + stbl.length;
    final result = Uint8List(minfSize);
    final header = writeBoxHeader(minfSize, 'minf');

    var offset = 0;
    result.setAll(offset, Uint8List.view(header.buffer));
    offset += 8;
    result.setAll(offset, smhd);
    offset += smhd.length;
    result.setAll(offset, dinf);
    offset += dinf.length;
    result.setAll(offset, stbl);

    return result;
  }

  Uint8List _createStbl() {
    final stsd = _createStsd();
    final stts = writeStts();
    final stsc = writeStsc();
    final stsz = writeStsz();
    final stco = writeStco();

    final stblSize =
        8 + stsd.length + stts.length + stsc.length + stsz.length + stco.length;
    final result = Uint8List(stblSize);
    final header = writeBoxHeader(stblSize, 'stbl');

    var offset = 0;
    result.setAll(offset, Uint8List.view(header.buffer));
    offset += 8;
    result.setAll(offset, stsd);
    offset += stsd.length;
    result.setAll(offset, stts);
    offset += stts.length;
    result.setAll(offset, stsc);
    offset += stsc.length;
    result.setAll(offset, stsz);
    offset += stsz.length;
    result.setAll(offset, stco);

    return result;
  }

  Uint8List _createStsd() {
    final opus = _createOpusSampleEntry();

    final stsdSize = 12 + 4 + opus.length;
    final data = ByteData(stsdSize);
    var offset = 0;

    data.setUint32(offset, stsdSize, Endian.big);
    offset += 4;
    data.setUint8(offset++, 's'.codeUnitAt(0));
    data.setUint8(offset++, 't'.codeUnitAt(0));
    data.setUint8(offset++, 's'.codeUnitAt(0));
    data.setUint8(offset++, 'd'.codeUnitAt(0));

    data.setUint32(offset, 0, Endian.big);
    offset += 4;

    data.setUint32(offset, 1, Endian.big);
    offset += 4;

    final result = Uint8List(stsdSize);
    result.setAll(0, Uint8List.view(data.buffer, 0, offset));
    result.setAll(offset, opus);

    return result;
  }

  Uint8List _createOpusSampleEntry() {
    final dops = _createDops();

    final opusSize = 8 + 28 + dops.length;
    final data = ByteData(opusSize);
    var offset = 0;

    data.setUint32(offset, opusSize, Endian.big);
    offset += 4;
    data.setUint8(offset++, 'O'.codeUnitAt(0));
    data.setUint8(offset++, 'p'.codeUnitAt(0));
    data.setUint8(offset++, 'u'.codeUnitAt(0));
    data.setUint8(offset++, 's'.codeUnitAt(0));

    // Reserved (6 bytes)
    for (var i = 0; i < 6; i++) {
      data.setUint8(offset++, 0);
    }

    data.setUint16(offset, 1, Endian.big);
    offset += 2;

    // Reserved (8 bytes)
    for (var i = 0; i < 8; i++) {
      data.setUint8(offset++, 0);
    }

    data.setUint16(offset, channels, Endian.big);
    offset += 2;

    data.setUint16(offset, 16, Endian.big);
    offset += 2;

    data.setUint16(offset, 0, Endian.big);
    offset += 2;

    data.setUint16(offset, 0, Endian.big);
    offset += 2;

    data.setUint32(offset, (48000 << 16), Endian.big);
    offset += 4;

    final result = Uint8List(opusSize);
    result.setAll(0, Uint8List.view(data.buffer, 0, offset));
    result.setAll(offset, dops);

    return result;
  }

  Uint8List _createDops() {
    final dopsSize = 8 + 11;
    final data = ByteData(dopsSize);
    var offset = 0;

    data.setUint32(offset, dopsSize, Endian.big);
    offset += 4;
    data.setUint8(offset++, 'd'.codeUnitAt(0));
    data.setUint8(offset++, 'O'.codeUnitAt(0));
    data.setUint8(offset++, 'p'.codeUnitAt(0));
    data.setUint8(offset++, 's'.codeUnitAt(0));

    data.setUint8(offset++, 0); // Version
    data.setUint8(offset++, channels);
    data.setUint16(offset, 312, Endian.big); // PreSkip
    offset += 2;
    data.setUint32(offset, sampleRate, Endian.big);
    offset += 4;
    data.setInt16(offset, 0, Endian.big); // OutputGain
    offset += 2;
    data.setUint8(offset++, channels <= 2 ? 0 : 1);

    return Uint8List.view(data.buffer);
  }

  Uint8List _updateTrunDataOffset(Uint8List moof, int dataOffset) {
    final result = Uint8List.fromList(moof);

    var offset = 8;

    final mfhdSize =
        (result[offset] << 24) |
        (result[offset + 1] << 16) |
        (result[offset + 2] << 8) |
        result[offset + 3];
    offset += mfhdSize;

    offset += 8;

    final tfhdSize =
        (result[offset] << 24) |
        (result[offset + 1] << 16) |
        (result[offset + 2] << 8) |
        result[offset + 3];
    offset += tfhdSize;

    final tfdtSize =
        (result[offset] << 24) |
        (result[offset + 1] << 16) |
        (result[offset + 2] << 8) |
        result[offset + 3];
    offset += tfdtSize;

    offset += 16;

    result[offset] = (dataOffset >> 24) & 0xFF;
    result[offset + 1] = (dataOffset >> 16) & 0xFF;
    result[offset + 2] = (dataOffset >> 8) & 0xFF;
    result[offset + 3] = dataOffset & 0xFF;

    return result;
  }
}

/// Complete streaming playback pipeline
///
/// Connects MoqMediaPipeline to a single combined fMP4 stream for media_kit.
/// Combines video (H.264) and audio (Opus or AAC) into a single multi-track
/// fragmented MP4 served from one HTTP server. This avoids the unreliable
/// mpv `audio-add` approach and works on all platforms including Android.
/// Falls back to regular files on Windows or if HTTP server setup fails.
class StreamingPlaybackPipeline {
  final MoqMediaPipeline _mediaPipeline;
  final AvccFmp4Muxer _videoMuxer;
  final OpusStreamingMuxer _opusMuxer;
  final AacFmp4Muxer _aacMuxer;

  // Single HTTP server for combined A/V stream
  HttpServer? _server;
  HttpResponse? _response;
  bool _clientReady = false;
  final List<Uint8List> _outputBuffer = [];
  bool _useHttp = false;

  // Fallback file output
  File? _outputFile;
  IOSink? _outputSink;

  // Diagnostic: write a copy to file for ffprobe inspection
  IOSink? _diagSink;

  // Combined init segment state
  bool _initWritten = false;
  bool _videoConfigReady = false;
  MediaFrameType? _detectedAudioType;

  // Buffer frames until combined init is ready (need both video config + audio type)
  final List<MediaFrame> _pendingVideoFrames = [];
  final List<MediaFrame> _pendingAudioFrames = [];

  // Global moof sequence counter (shared across video and audio fragments)
  int _globalSequenceNumber = 0;

  // Video-only fallback: if no audio arrives within timeout, proceed without it
  Timer? _audioWaitTimer;
  bool _audioEnabled = true;

  StreamSubscription<MediaFrame>? _videoSubscription;
  StreamSubscription<MediaFrame>? _audioSubscription;

  final _readyController = StreamController<String>.broadcast();

  int _videoSegmentsWritten = 0;
  int _audioSegmentsWritten = 0;
  bool _directCmafMode = false;
  bool _directCmafHasAudio = false;

  StreamingPlaybackPipeline({
    int videoWidth = 1920,
    int videoHeight = 1080,
    int videoTimescale = 90000,
    int audioSampleRate = 48000,
    int audioChannels = 2,
  }) : _mediaPipeline = MoqMediaPipeline(),
       _videoMuxer = AvccFmp4Muxer(
         width: videoWidth,
         height: videoHeight,
         timescale: videoTimescale,
         trackId: 1,
       ),
       _opusMuxer = OpusStreamingMuxer(
         sampleRate: audioSampleRate,
         channels: audioChannels,
         trackId: 2,
       ),
       _aacMuxer = AacFmp4Muxer(
         sampleRate: audioSampleRate,
         channels: audioChannels,
         trackId: 2,
       );

  /// Stream that emits the combined media URL/path when ready for playback
  Stream<String> get onVideoReady => _readyController.stream;

  /// Get the underlying media pipeline for statistics
  MoqMediaPipeline get mediaPipeline => _mediaPipeline;

  /// Get combined media path (HTTP URL or file path)
  String? get videoFilePath => _useHttp
      ? (_server != null
            ? 'http://127.0.0.1:${_server!.port}/stream.mp4'
            : null)
      : _outputFile?.path;

  /// Statistics
  int get videoSegmentsWritten => _videoSegmentsWritten;
  int get audioSegmentsWritten => _audioSegmentsWritten;

  /// Initialize the pipeline with a single HTTP server for combined A/V stream.
  /// Falls back to regular files if server setup fails.
  Future<void> initialize() async {
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _useHttp = true;

      _server!.listen((request) {
        debugPrint(
          'StreamingPlayback: mpv connected to combined HTTP '
          '(${request.method} ${request.uri})',
        );
        final response = request.response;
        response.headers.contentType = ContentType('video', 'mp4');
        response.headers.set('Transfer-Encoding', 'chunked');
        response.bufferOutput = false;
        _response = response;
        _clientReady = true;
        for (final chunk in _outputBuffer) {
          response.add(chunk);
        }
        _outputBuffer.clear();
      });

      debugPrint(
        'StreamingPlayback: HTTP server started on port ${_server!.port}',
      );

      // Diagnostic: write a copy to file for ffprobe inspection
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final diagFile = File('${tempDir.path}/moq_diag_combined_$timestamp.mp4');
      _diagSink = diagFile.openWrite();
      debugPrint('StreamingPlayback: Diagnostic file: ${diagFile.path}');

      _videoSubscription = _mediaPipeline.videoFrames.listen(_handleVideoFrame);
      _audioSubscription = _mediaPipeline.audioFrames.listen(_handleAudioFrame);

      // If no audio arrives within 3 seconds, proceed with video-only
      _audioWaitTimer = Timer(const Duration(seconds: 3), () {
        if (!_initWritten && _videoConfigReady && _detectedAudioType == null) {
          debugPrint(
            'StreamingPlayback: No audio detected after 3s, proceeding video-only',
          );
          _audioEnabled = false;
          _writeCombinedInit();
          _flushPendingFrames();
        }
      });
    } catch (e) {
      debugPrint(
        'StreamingPlayback: HTTP setup failed ($e), falling back to file',
      );
      _useHttp = false;
      await _server?.close();
      _server = null;
      await _initializeWithFile();
    }
  }

  /// Fallback file-based initialization
  Future<void> _initializeWithFile() async {
    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _outputFile = File('${tempDir.path}/moq_combined_$timestamp.mp4');
    _outputSink = _outputFile!.openWrite();

    _videoSubscription = _mediaPipeline.videoFrames.listen(_handleVideoFrame);
    _audioSubscription = _mediaPipeline.audioFrames.listen(_handleAudioFrame);

    debugPrint(
      'StreamingPlayback: Initialized (file), path=${_outputFile!.path}',
    );
  }

  /// Process a MoQ object through the pipeline
  void processObject(dynamic object) {
    _mediaPipeline.processObject(object);
  }

  /// Configure the pipeline to accept raw CMAF objects directly.
  void configureDirectCmafPlayback(List<CmafTrackInit> tracks) {
    if (tracks.isEmpty) {
      throw ArgumentError('At least one CMAF track is required');
    }

    final initSegment = buildCombinedCmafInitSegment(tracks);
    _directCmafMode = true;
    _directCmafHasAudio = tracks.any((track) => track.isAudio);
    _audioEnabled = _directCmafHasAudio;
    _initWritten = true;
    _videoConfigReady = true;
    _detectedAudioType = _directCmafHasAudio ? MediaFrameType.audioAac : null;
    _write(initSegment);

    debugPrint(
      'StreamingPlayback: Direct CMAF init segment written '
      '(${initSegment.length} bytes, audio=$_directCmafHasAudio)',
    );
  }

  /// Process a raw CMAF segment payload from a subscription object.
  void processCmafObject(
    Uint8List payload, {
    required bool isVideo,
    required bool isAudio,
  }) {
    if (!_directCmafMode) {
      throw StateError('Direct CMAF playback is not configured');
    }
    if (!_initWritten) {
      throw StateError('Direct CMAF init segment must be written first');
    }
    if (payload.isEmpty) {
      return;
    }

    final segment = Uint8List.fromList(payload);
    _patchMoofSequence(segment, ++_globalSequenceNumber);
    _write(segment);

    if (isVideo) {
      _videoSegmentsWritten++;
      final readyThreshold = _useHttp ? 2 : 5;
      if (_videoSegmentsWritten == readyThreshold) {
        final path = videoFilePath!;
        _readyController.add(path);
        debugPrint(
          'StreamingPlayback: Combined stream ready at $path '
          '($readyThreshold video segments buffered)',
        );
      }
    }

    if (isAudio) {
      _audioSegmentsWritten++;
    }

    if ((_videoSegmentsWritten + _audioSegmentsWritten) % 30 == 0) {
      debugPrint(
        'StreamingPlayback: Video=$_videoSegmentsWritten, '
        'Audio=$_audioSegmentsWritten segments written',
      );
    }
  }

  static Uint8List buildCombinedCmafInitSegment(List<CmafTrackInit> tracks) {
    if (tracks.isEmpty) {
      throw ArgumentError('At least one CMAF track is required');
    }

    Uint8List? ftyp;
    Uint8List? mvhd;
    int mvhdTimescale = 1000;
    final trakBoxes = <Uint8List>[];
    final trackIds = <int>[];

    for (final track in tracks) {
      final init = track.initSegment;
      final rootBoxes = _readMp4Boxes(init);

      ftyp ??= _firstBoxData(rootBoxes, 'ftyp', init);
      final moov = _firstBox(rootBoxes, 'moov');
      if (moov == null) {
        throw StateError('CMAF init segment is missing moov');
      }

      final moovBoxes = _readMp4Boxes(
        init,
        start: moov.contentStart,
        end: moov.end,
      );
      mvhd ??= _firstBoxData(moovBoxes, 'mvhd', init);
      if (mvhd != null) {
        mvhdTimescale = _parseMvhdTimescale(mvhd) ?? mvhdTimescale;
      }

      for (final box in moovBoxes.where(
        (candidate) => candidate.type == 'trak',
      )) {
        final trakData = init.sublist(box.start, box.end);
        trakBoxes.add(trakData);
        final trackId = _parseTrakTrackId(trakData);
        if (trackId != null) {
          trackIds.add(trackId);
        }
      }
    }

    if (ftyp == null || mvhd == null || trakBoxes.isEmpty) {
      throw StateError('Unable to build combined CMAF init segment');
    }

    final uniqueTrackIds = <int>[];
    for (final trackId in trackIds) {
      if (!uniqueTrackIds.contains(trackId)) {
        uniqueTrackIds.add(trackId);
      }
    }

    final nextTrackId = uniqueTrackIds.isEmpty
        ? 2
        : uniqueTrackIds.reduce(math.max) + 1;
    final combinedMvhd = writeMvhd(
      timescale: mvhdTimescale,
      duration: 0,
      nextTrackId: nextTrackId,
    );
    final mvex = uniqueTrackIds.length <= 1
        ? writeMvex(trackId: uniqueTrackIds.isEmpty ? 1 : uniqueTrackIds.first)
        : writeMvexMultiTrack(uniqueTrackIds);

    final moovSize =
        8 +
        combinedMvhd.length +
        trakBoxes.fold<int>(0, (sum, box) => sum + box.length) +
        mvex.length;
    final moov = Uint8List(moovSize);
    final header = writeBoxHeader(moovSize, 'moov');

    var offset = 0;
    moov.setAll(offset, Uint8List.view(header.buffer));
    offset += 8;
    moov.setAll(offset, combinedMvhd);
    offset += combinedMvhd.length;
    for (final trak in trakBoxes) {
      moov.setAll(offset, trak);
      offset += trak.length;
    }
    moov.setAll(offset, mvex);

    final result = Uint8List(ftyp.length + moov.length);
    result.setAll(0, ftyp);
    result.setAll(ftyp.length, moov);
    return result;
  }

  /// Write data to the single combined output stream
  void _write(Uint8List data) {
    _diagSink?.add(data);

    if (_useHttp) {
      if (_clientReady) {
        _response!.add(data);
      } else {
        _outputBuffer.add(data);
      }
    } else {
      _outputSink?.add(data);
    }
  }

  void _handleVideoFrame(MediaFrame frame) {
    // Extract AVC decoder config when available
    if (!_videoConfigReady && frame.codecConfig != null) {
      final config = frame.codecConfig!;
      debugPrint(
        'StreamingPlayback: AVC config ${config.length} bytes: '
        '${config.take(20).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}',
      );
      _videoMuxer.setAvcDecoderConfig(config);
      _videoConfigReady = true;
    }

    if (!_initWritten) {
      _pendingVideoFrames.add(frame);
      _tryWriteCombinedInit();
      return;
    }

    _writeVideoSegment(frame);
  }

  void _handleAudioFrame(MediaFrame frame) {
    if (_detectedAudioType == null) {
      _detectedAudioType = frame.type;
      _audioWaitTimer?.cancel();
      debugPrint('StreamingPlayback: Detected audio type: $_detectedAudioType');
    }

    if (!_initWritten) {
      _pendingAudioFrames.add(frame);
      _tryWriteCombinedInit();
      return;
    }

    if (!_audioEnabled) return;
    _writeAudioSegment(frame);
  }

  /// Try to write the combined init segment once both video and audio info are available
  void _tryWriteCombinedInit() {
    if (_initWritten) return;
    if (!_videoConfigReady) return;

    // Wait for audio type detection (unless audio-wait timer expired)
    if (_detectedAudioType == null && _audioEnabled) return;

    _writeCombinedInit();
    _flushPendingFrames();
  }

  /// Write the combined fMP4 init segment with both video and audio tracks
  void _writeCombinedInit() {
    final ftyp = writeFtyp(
      majorBrand: 'isom',
      minorVersion: 512,
      compatibleBrands: ['isom', 'iso6', 'avc1', 'mp41'],
    );

    // Build video trak (track 1)
    final videoTrak = _videoMuxer.buildTrak();

    // Build audio trak (track 2) if audio is available
    Uint8List? audioTrak;
    Uint8List mvex;

    final hasAudio = _audioEnabled && _detectedAudioType != null;
    if (hasAudio) {
      if (_detectedAudioType == MediaFrameType.audioAac) {
        audioTrak = _aacMuxer.buildTrak();
      } else {
        audioTrak = _opusMuxer.buildTrak();
      }
      mvex = writeMvexMultiTrack([1, 2]);
    } else {
      mvex = writeMvex(trackId: 1);
    }

    // Movie header with generic timescale
    final mvhd = writeMvhd(
      timescale: 1000,
      duration: 0,
      nextTrackId: hasAudio ? 3 : 2,
    );

    // Assemble moov box
    final moovContentSize =
        mvhd.length + videoTrak.length + (audioTrak?.length ?? 0) + mvex.length;
    final moovSize = 8 + moovContentSize;
    final moov = Uint8List(moovSize);
    final moovHeader = writeBoxHeader(moovSize, 'moov');

    var offset = 0;
    moov.setAll(offset, Uint8List.view(moovHeader.buffer));
    offset += 8;
    moov.setAll(offset, mvhd);
    offset += mvhd.length;
    moov.setAll(offset, videoTrak);
    offset += videoTrak.length;
    if (audioTrak != null) {
      moov.setAll(offset, audioTrak);
      offset += audioTrak.length;
    }
    moov.setAll(offset, mvex);

    // Write combined init segment
    final initSegment = Uint8List(ftyp.length + moov.length);
    initSegment.setAll(0, ftyp);
    initSegment.setAll(ftyp.length, moov);

    _write(initSegment);
    _initWritten = true;

    debugPrint(
      'StreamingPlayback: Combined init segment written '
      '(${initSegment.length} bytes, audio=$hasAudio, '
      'audioType=$_detectedAudioType)',
    );
  }

  /// Flush buffered frames after init segment is written
  void _flushPendingFrames() {
    for (final frame in _pendingVideoFrames) {
      _writeVideoSegment(frame);
    }
    _pendingVideoFrames.clear();

    if (_audioEnabled) {
      for (final frame in _pendingAudioFrames) {
        _writeAudioSegment(frame);
      }
    }
    _pendingAudioFrames.clear();
  }

  void _writeVideoSegment(MediaFrame frame) {
    if (!_initWritten || !_videoConfigReady) return;

    if (_videoSegmentsWritten == 0) {
      final dataPreview = frame.data
          .take(16)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      debugPrint(
        'StreamingPlayback: First video frame: ${frame.data.length} bytes, '
        'keyframe=${frame.isKeyframe}, duration=${frame.duration}, '
        'timebase=${frame.timebase}, data: $dataPreview',
      );
    }

    final segment = _videoMuxer.createMediaSegment(frame);
    _patchMoofSequence(segment, ++_globalSequenceNumber);
    _write(segment);
    _videoSegmentsWritten++;

    final readyThreshold = _useHttp ? 2 : 5;
    if (_videoSegmentsWritten == readyThreshold) {
      final path = videoFilePath!;
      _readyController.add(path);
      debugPrint(
        'StreamingPlayback: Combined stream ready at $path '
        '($readyThreshold video segments buffered)',
      );
    }

    if (_videoSegmentsWritten % 30 == 0) {
      debugPrint(
        'StreamingPlayback: Video=$_videoSegmentsWritten, '
        'Audio=$_audioSegmentsWritten segments written',
      );
    }
  }

  void _writeAudioSegment(MediaFrame frame) {
    if (!_initWritten) return;

    Uint8List segment;
    if (_detectedAudioType == MediaFrameType.audioAac) {
      if (AacFmp4Muxer.hasAdtsHeader(frame.data)) {
        segment = _aacMuxer.createMediaSegmentFromAdts(frame.data);
      } else {
        segment = _aacMuxer.createSingleFrameSegment(frame.data);
      }
    } else {
      segment = _opusMuxer.createMediaSegment(frame);
    }

    _patchMoofSequence(segment, ++_globalSequenceNumber);
    _write(segment);
    _audioSegmentsWritten++;
  }

  /// Patch the mfhd sequence number in a moof+mdat segment.
  /// moof layout: header(8) > mfhd(size(4)+'mfhd'(4)+ver/flags(4)+seq(4)) > traf
  /// So the sequence number is at bytes [20..23] of the segment.
  void _patchMoofSequence(Uint8List segment, int sequenceNumber) {
    if (segment.length >= 24) {
      segment[20] = (sequenceNumber >> 24) & 0xFF;
      segment[21] = (sequenceNumber >> 16) & 0xFF;
      segment[22] = (sequenceNumber >> 8) & 0xFF;
      segment[23] = sequenceNumber & 0xFF;
    }
  }

  /// Clean up streaming resources
  Future<void> _cleanupStreaming() async {
    _audioWaitTimer?.cancel();
    _audioWaitTimer = null;

    try {
      await _response?.close();
    } catch (_) {}
    try {
      await _server?.close();
    } catch (_) {}
    _response = null;
    _server = null;
    _clientReady = false;
    _outputBuffer.clear();

    await _diagSink?.flush();
    await _diagSink?.close();
    _diagSink = null;

    await _outputSink?.flush();
    await _outputSink?.close();
    _outputSink = null;

    try {
      await _outputFile?.delete();
    } catch (e) {
      debugPrint('StreamingPlayback: Error cleaning up temp file: $e');
    }
    _outputFile = null;
    _useHttp = false;
  }

  /// Reset the pipeline (e.g., for seeking or reconnection)
  Future<void> reset() async {
    await _videoSubscription?.cancel();
    await _audioSubscription?.cancel();

    await _cleanupStreaming();

    _mediaPipeline.reset();
    _videoMuxer.reset();
    _opusMuxer.reset();
    _aacMuxer.reset();

    _initWritten = false;
    _directCmafMode = false;
    _directCmafHasAudio = false;
    _videoConfigReady = false;
    _detectedAudioType = null;
    _audioEnabled = true;
    _videoSegmentsWritten = 0;
    _audioSegmentsWritten = 0;
    _globalSequenceNumber = 0;
    _pendingVideoFrames.clear();
    _pendingAudioFrames.clear();

    await initialize();
  }

  /// Dispose all resources
  Future<void> dispose() async {
    await _videoSubscription?.cancel();
    await _audioSubscription?.cancel();

    await _cleanupStreaming();

    _readyController.close();
    _mediaPipeline.dispose();
  }
}

class CmafTrackInit {
  final String trackName;
  final Uint8List initSegment;
  final bool isVideo;
  final bool isAudio;

  const CmafTrackInit({
    required this.trackName,
    required this.initSegment,
    this.isVideo = false,
    this.isAudio = false,
  });
}

class _Mp4Box {
  final String type;
  final int start;
  final int size;

  const _Mp4Box({required this.type, required this.start, required this.size});

  int get contentStart => start + 8;
  int get end => start + size;
}

List<_Mp4Box> _readMp4Boxes(Uint8List data, {int start = 0, int? end}) {
  final limit = end ?? data.length;
  final boxes = <_Mp4Box>[];
  var offset = start;

  while (offset + 8 <= limit) {
    final size =
        (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
    if (size < 8 || offset + size > limit) {
      break;
    }
    final type = String.fromCharCodes(data.sublist(offset + 4, offset + 8));
    boxes.add(_Mp4Box(type: type, start: offset, size: size));
    offset += size;
  }

  return boxes;
}

_Mp4Box? _firstBox(List<_Mp4Box> boxes, String type) {
  for (final box in boxes) {
    if (box.type == type) {
      return box;
    }
  }
  return null;
}

Uint8List? _firstBoxData(List<_Mp4Box> boxes, String type, Uint8List source) {
  final box = _firstBox(boxes, type);
  if (box == null) {
    return null;
  }
  return source.sublist(box.start, box.end);
}

int? _parseMvhdTimescale(Uint8List mvhd) {
  if (mvhd.length < 24) {
    return null;
  }
  final version = mvhd[8];
  if (version == 0 && mvhd.length >= 24) {
    return (mvhd[20] << 24) | (mvhd[21] << 16) | (mvhd[22] << 8) | mvhd[23];
  }
  if (version == 1 && mvhd.length >= 32) {
    return (mvhd[28] << 24) | (mvhd[29] << 16) | (mvhd[30] << 8) | mvhd[31];
  }
  return null;
}

int? _parseTrakTrackId(Uint8List trak) {
  final children = _readMp4Boxes(trak, start: 8);
  final tkhd = _firstBox(children, 'tkhd');
  if (tkhd == null) {
    return null;
  }
  final version = trak[tkhd.start + 8];
  if (version == 0 && tkhd.size >= 24) {
    final offset = tkhd.start + 20;
    return (trak[offset] << 24) |
        (trak[offset + 1] << 16) |
        (trak[offset + 2] << 8) |
        trak[offset + 3];
  }
  if (version == 1 && tkhd.size >= 36) {
    final offset = tkhd.start + 28;
    return (trak[offset] << 24) |
        (trak[offset + 1] << 16) |
        (trak[offset + 2] << 8) |
        trak[offset + 3];
  }
  return null;
}
