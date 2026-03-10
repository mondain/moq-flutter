import 'dart:async';
import 'dart:io';
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
        frame.isKeyframe ? SampleFlags.keyframe : SampleFlags.nonKeyframe
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
    final mdhd = writeMdhd(
      timescale: timescale,
      duration: 0,
    );

    final hdlr = writeHdlr(
      handlerType: 'vide',
      name: 'VideoHandler',
    );

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
    final mfhdSize = (result[offset] << 24) |
        (result[offset + 1] << 16) |
        (result[offset + 2] << 8) |
        result[offset + 3];
    offset += mfhdSize;

    // Skip traf header
    offset += 8;

    // Skip tfhd
    final tfhdSize = (result[offset] << 24) |
        (result[offset + 1] << 16) |
        (result[offset + 2] << 8) |
        result[offset + 3];
    offset += tfhdSize;

    // Skip tfdt
    final tfdtSize = (result[offset] << 24) |
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
    final mdhd = writeMdhd(
      timescale: opusTimescale,
      duration: 0,
    );

    final hdlr = writeHdlr(
      handlerType: 'soun',
      name: 'SoundHandler',
    );

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

    final mfhdSize = (result[offset] << 24) |
        (result[offset + 1] << 16) |
        (result[offset + 2] << 8) |
        result[offset + 3];
    offset += mfhdSize;

    offset += 8;

    final tfhdSize = (result[offset] << 24) |
        (result[offset + 1] << 16) |
        (result[offset + 2] << 8) |
        result[offset + 3];
    offset += tfhdSize;

    final tfdtSize = (result[offset] << 24) |
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
/// Connects MoqMediaPipeline to FIFO-based fMP4 output for media_kit.
/// Uses named pipes (FIFOs) on Linux/macOS so mpv block-reads instead of
/// hitting EOF on a regular file. Falls back to regular files on Windows.
/// Supports H.264 video, and both Opus and AAC audio.
class StreamingPlaybackPipeline {
  final MoqMediaPipeline _mediaPipeline;
  final AvccFmp4Muxer _videoMuxer;
  final OpusStreamingMuxer _opusMuxer;
  final AacFmp4Muxer _aacMuxer;

  File? _videoFile;
  File? _audioFile;
  IOSink? _videoSink;
  IOSink? _audioSink;

  // HTTP server-based streaming (preferred for live playback)
  HttpServer? _videoServer;
  HttpServer? _audioServer;
  HttpResponse? _videoResponse;
  HttpResponse? _audioResponse;
  bool _useHttp = false;

  // Buffer for data received before client connects
  final List<Uint8List> _videoBuffer = [];
  final List<Uint8List> _audioBuffer = [];
  bool _videoClientReady = false;
  bool _audioClientReady = false;

  // Diagnostic: also write to file for ffprobe inspection
  IOSink? _videoDiagSink;
  IOSink? _audioDiagSink;

  bool _videoInitWritten = false;
  bool _audioInitWritten = false;
  MediaFrameType? _detectedAudioType;

  StreamSubscription<MediaFrame>? _videoSubscription;
  StreamSubscription<MediaFrame>? _audioSubscription;

  final _videoReadyController = StreamController<String>.broadcast();
  final _audioReadyController = StreamController<String>.broadcast();

  int _videoSegmentsWritten = 0;
  int _audioSegmentsWritten = 0;

  StreamingPlaybackPipeline({
    int videoWidth = 1920,
    int videoHeight = 1080,
    int videoTimescale = 90000,
    int audioSampleRate = 48000,
    int audioChannels = 2,
  })  : _mediaPipeline = MoqMediaPipeline(),
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

  /// Stream that emits video file path when ready
  Stream<String> get onVideoReady => _videoReadyController.stream;

  /// Stream that emits audio file path when ready
  Stream<String> get onAudioReady => _audioReadyController.stream;

  /// Get the underlying media pipeline for statistics
  MoqMediaPipeline get mediaPipeline => _mediaPipeline;

  /// Get video path (HTTP URL or file path)
  String? get videoFilePath => _useHttp
      ? (_videoServer != null ? 'http://127.0.0.1:${_videoServer!.port}/video.mp4' : null)
      : _videoFile?.path;

  /// Get audio path (HTTP URL or file path)
  String? get audioFilePath => _useHttp
      ? (_audioServer != null ? 'http://127.0.0.1:${_audioServer!.port}/audio.mp4' : null)
      : _audioFile?.path;

  /// Statistics
  int get videoSegmentsWritten => _videoSegmentsWritten;
  int get audioSegmentsWritten => _audioSegmentsWritten;

  /// Initialize the pipeline and start writing segments.
  /// Uses a local HTTP server so mpv reads from a chunked HTTP stream (no EOF).
  /// Falls back to regular files if server setup fails.
  Future<void> initialize() async {
    try {
      // Start HTTP servers for video and audio on ephemeral ports
      _videoServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _audioServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

      final videoPort = _videoServer!.port;
      final audioPort = _audioServer!.port;
      _useHttp = true;

      // Handle HTTP requests from mpv - respond with chunked fMP4 stream
      _videoServer!.listen((request) {
        debugPrint('StreamingPlayback: mpv connected to video HTTP (${request.method} ${request.uri})');
        final response = request.response;
        response.headers.contentType = ContentType('video', 'mp4');
        response.headers.set('Transfer-Encoding', 'chunked');
        response.bufferOutput = false;
        _videoResponse = response;
        _videoClientReady = true;
        // Flush any buffered data
        for (final chunk in _videoBuffer) {
          response.add(chunk);
        }
        _videoBuffer.clear();
      });

      _audioServer!.listen((request) {
        debugPrint('StreamingPlayback: mpv connected to audio HTTP (${request.method} ${request.uri})');
        final response = request.response;
        response.headers.contentType = ContentType('audio', 'mp4');
        response.headers.set('Transfer-Encoding', 'chunked');
        response.bufferOutput = false;
        _audioResponse = response;
        _audioClientReady = true;
        for (final chunk in _audioBuffer) {
          response.add(chunk);
        }
        _audioBuffer.clear();
      });

      debugPrint('StreamingPlayback: HTTP servers started - video=:$videoPort, audio=:$audioPort');

      // Diagnostic: write a copy to file for ffprobe inspection
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final diagVideoFile = File('${tempDir.path}/moq_diag_video_$timestamp.mp4');
      final diagAudioFile = File('${tempDir.path}/moq_diag_audio_$timestamp.mp4');
      _videoDiagSink = diagVideoFile.openWrite();
      _audioDiagSink = diagAudioFile.openWrite();
      debugPrint('StreamingPlayback: Diagnostic video: ${diagVideoFile.path}');
      debugPrint('StreamingPlayback: Diagnostic audio: ${diagAudioFile.path}');

      // Subscribe to media frames
      _videoSubscription = _mediaPipeline.videoFrames.listen(_handleVideoFrame);
      _audioSubscription = _mediaPipeline.audioFrames.listen(_handleAudioFrame);
    } catch (e) {
      debugPrint('StreamingPlayback: HTTP setup failed ($e), falling back to file');
      _useHttp = false;
      await _videoServer?.close();
      await _audioServer?.close();
      _videoServer = null;
      _audioServer = null;
      await _initializeWithFiles();
    }
  }

  /// Fallback file-based initialization
  Future<void> _initializeWithFiles() async {
    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    _videoFile = File('${tempDir.path}/moq_video_$timestamp.mp4');
    _audioFile = File('${tempDir.path}/moq_audio_$timestamp.mp4');

    _videoSink = _videoFile!.openWrite();
    _audioSink = _audioFile!.openWrite();

    // Subscribe to media frames
    _videoSubscription = _mediaPipeline.videoFrames.listen(_handleVideoFrame);
    _audioSubscription = _mediaPipeline.audioFrames.listen(_handleAudioFrame);

    debugPrint('StreamingPlayback: Initialized (file), video=${_videoFile!.path}');
    debugPrint('StreamingPlayback: Initialized (file), audio=${_audioFile!.path}');
  }

  /// Process a MoQ object through the pipeline
  void processObject(dynamic object) {
    _mediaPipeline.processObject(object);
  }

  /// Write data to the video output (HTTP response or file sink)
  void _writeVideo(Uint8List data) {
    // Diagnostic copy
    _videoDiagSink?.add(data);

    if (_useHttp) {
      if (_videoClientReady) {
        _videoResponse!.add(data);
      } else {
        _videoBuffer.add(data);
      }
    } else {
      _videoSink!.add(data);
    }
  }

  /// Write data to the audio output (HTTP response or file sink)
  void _writeAudio(Uint8List data) {
    // Diagnostic copy
    _audioDiagSink?.add(data);

    if (_useHttp) {
      if (_audioClientReady) {
        _audioResponse!.add(data);
      } else {
        _audioBuffer.add(data);
      }
    } else {
      _audioSink!.add(data);
    }
  }

  void _handleVideoFrame(MediaFrame frame) {
    // Check if we need to write init segment
    if (!_videoInitWritten && frame.codecConfig != null) {
      final config = frame.codecConfig!;
      debugPrint('StreamingPlayback: AVC config ${config.length} bytes: '
          '${config.take(20).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
      _videoMuxer.setAvcDecoderConfig(config);
      final initSegment = _videoMuxer.initSegment;
      if (initSegment != null) {
        _writeVideo(initSegment);
        _videoInitWritten = true;
        debugPrint('StreamingPlayback: Video init segment written (${initSegment.length} bytes)');
        // Log first 32 bytes of init segment for verification
        final preview = initSegment.take(32).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
        debugPrint('StreamingPlayback: Init segment starts: $preview');
      }
    }

    // Write media segment
    if (_videoInitWritten) {
      if (_videoSegmentsWritten == 0) {
        // Log first frame details
        final dataPreview = frame.data.take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
        debugPrint('StreamingPlayback: First video frame: ${frame.data.length} bytes, '
            'keyframe=${frame.isKeyframe}, duration=${frame.duration}, '
            'timebase=${frame.timebase}, data: $dataPreview');
      }
      final segment = _videoMuxer.createMediaSegment(frame);
      _writeVideo(segment);
      _videoSegmentsWritten++;

      // Notify when enough segments buffered for playback to start.
      // With sockets, data buffers until mpv connects. Signal ready after
      // 2 segments so mpv connects and receives the buffered data.
      // With files, wait for 5 segments to ensure enough data on disk.
      final readyThreshold = _useHttp ? 2 : 5;
      if (_videoSegmentsWritten == readyThreshold) {
        final path = _useHttp
            ? 'http://127.0.0.1:${_videoServer!.port}/video.mp4'
            : _videoFile!.path;
        _videoReadyController.add(path);
        debugPrint('StreamingPlayback: Video ready at $path ($readyThreshold segments buffered)');
      }

      // Log progress periodically
      if (_videoSegmentsWritten % 30 == 0) {
        debugPrint('StreamingPlayback: Video segments written: $_videoSegmentsWritten');
      }
    }
  }

  void _handleAudioFrame(MediaFrame frame) {
    // Detect audio type on first frame
    if (_detectedAudioType == null) {
      _detectedAudioType = frame.type;
      debugPrint('StreamingPlayback: Detected audio type: $_detectedAudioType');
    }

    // Write init segment if not done
    if (!_audioInitWritten) {
      Uint8List initSegment;
      if (_detectedAudioType == MediaFrameType.audioAac) {
        initSegment = _aacMuxer.initSegment;
        debugPrint('StreamingPlayback: AAC audio init segment written (${initSegment.length} bytes)');
      } else {
        initSegment = _opusMuxer.initSegment;
        debugPrint('StreamingPlayback: Opus audio init segment written (${initSegment.length} bytes)');
      }
      _writeAudio(initSegment);
      _audioInitWritten = true;
    }

    // Write media segment using appropriate muxer
    Uint8List segment;
    if (_detectedAudioType == MediaFrameType.audioAac) {
      // Check if data has ADTS headers and handle accordingly
      if (AacFmp4Muxer.hasAdtsHeader(frame.data)) {
        segment = _aacMuxer.createMediaSegmentFromAdts(frame.data);
      } else {
        segment = _aacMuxer.createSingleFrameSegment(frame.data);
      }
    } else {
      segment = _opusMuxer.createMediaSegment(frame);
    }
    _writeAudio(segment);
    _audioSegmentsWritten++;

    // Notify when enough segments are written for playback to start
    if (_audioSegmentsWritten == 20) {
      final path = _useHttp
          ? 'http://127.0.0.1:${_audioServer!.port}/audio.mp4'
          : _audioFile!.path;
      _audioReadyController.add(path);
      debugPrint('StreamingPlayback: Audio ready at $path (20 segments buffered)');
    }

    // Log progress periodically
    if (_audioSegmentsWritten % 50 == 0) {
      debugPrint('StreamingPlayback: Audio segments written: $_audioSegmentsWritten');
    }
  }

  /// Clean up current streaming resources
  Future<void> _cleanupStreaming() async {
    // Close HTTP responses and servers
    try { await _videoResponse?.close(); } catch (_) {}
    try { await _audioResponse?.close(); } catch (_) {}
    try { await _videoServer?.close(); } catch (_) {}
    try { await _audioServer?.close(); } catch (_) {}
    _videoResponse = null;
    _audioResponse = null;
    _videoServer = null;
    _audioServer = null;
    _videoClientReady = false;
    _audioClientReady = false;
    _videoBuffer.clear();
    _audioBuffer.clear();

    // Close diagnostic sinks
    await _videoDiagSink?.flush();
    await _videoDiagSink?.close();
    await _audioDiagSink?.flush();
    await _audioDiagSink?.close();
    _videoDiagSink = null;
    _audioDiagSink = null;

    // Close file sinks
    await _videoSink?.flush();
    await _videoSink?.close();
    await _audioSink?.flush();
    await _audioSink?.close();
    _videoSink = null;
    _audioSink = null;

    // Clean up temp files
    try {
      await _videoFile?.delete();
      await _audioFile?.delete();
    } catch (e) {
      debugPrint('StreamingPlayback: Error cleaning up temp files: $e');
    }
    _videoFile = null;
    _audioFile = null;
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

    _videoInitWritten = false;
    _audioInitWritten = false;
    _detectedAudioType = null;
    _videoSegmentsWritten = 0;
    _audioSegmentsWritten = 0;

    // Reinitialize
    await initialize();
  }

  /// Dispose all resources
  Future<void> dispose() async {
    await _videoSubscription?.cancel();
    await _audioSubscription?.cancel();

    await _cleanupStreaming();

    _videoReadyController.close();
    _audioReadyController.close();

    _mediaPipeline.dispose();
  }
}
