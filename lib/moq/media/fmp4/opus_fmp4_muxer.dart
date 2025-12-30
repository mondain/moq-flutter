import 'dart:convert';
import 'dart:typed_data';
import 'fmp4_boxes.dart';

/// Opus audio muxer for fragmented MP4 (fMP4/CMAF)
///
/// Creates init segments (ftyp+moov) and media segments (moof+mdat)
/// from raw Opus packets.
class OpusFmp4Muxer {
  final int sampleRate;
  final int channels;
  final int bitrate;
  final int frameDurationMs;
  final int trackId;

  // Opus pre-skip in samples (typically 312 samples at 48kHz)
  final int preSkip;

  // Cached init segment
  Uint8List? _initSegment;

  // Fragment state
  int _sequenceNumber = 0;
  int _baseDecodeTime = 0;

  // Timescale for Opus is always 48000 (internal Opus clock)
  static const int opusTimescale = 48000;

  OpusFmp4Muxer({
    this.sampleRate = 48000,
    this.channels = 2,
    this.bitrate = 128000,
    this.frameDurationMs = 20,
    this.trackId = 2,
    this.preSkip = 312,
  });

  /// Get the codec string for Opus
  String get codecString => 'opus';

  /// Get the MIME type for Opus in fMP4
  String get mimeType => 'audio/mp4; codecs="opus"';

  /// Check if init segment is ready (always true for Opus)
  bool get isInitReady => true;

  /// Get init segment data (ftyp + moov)
  Uint8List get initSegment {
    _initSegment ??= _createInitSegment();
    return _initSegment!;
  }

  /// Get init segment as base64 for catalog
  String get initDataBase64 => base64.encode(initSegment);

  /// Samples per frame based on frame duration
  int get samplesPerFrame => (opusTimescale * frameDurationMs) ~/ 1000;

  /// Create a media segment (moof + mdat) from Opus frame(s)
  ///
  /// [frames] is a list of Opus packets to include in the segment
  /// [durationMs] is the total duration of all frames in milliseconds
  Uint8List createMediaSegment({
    required List<Uint8List> frames,
    int? durationMs,
  }) {
    if (frames.isEmpty) {
      throw ArgumentError('At least one frame must be provided');
    }

    // Calculate sample sizes and durations
    final sampleSizes = frames.map((f) => f.length).toList();
    final sampleDuration = samplesPerFrame;
    final sampleDurations = List.filled(frames.length, sampleDuration);
    // Audio samples typically don't have flags like video keyframes
    final sampleFlags = List.filled(frames.length, 0x02000000); // All samples are sync

    // Concatenate all frame data for mdat
    final totalSize = frames.fold<int>(0, (sum, f) => sum + f.length);
    final mdatPayload = Uint8List(totalSize);
    var offset = 0;
    for (final frame in frames) {
      mdatPayload.setAll(offset, frame);
      offset += frame.length;
    }

    // Create moof
    final moof = writeMoof(
      sequenceNumber: ++_sequenceNumber,
      trackId: trackId,
      baseMediaDecodeTime: _baseDecodeTime,
      sampleSizes: sampleSizes,
      sampleDurations: sampleDurations,
      sampleFlags: sampleFlags,
    );

    // Update data offset in trun
    final moofWithOffset = _updateTrunDataOffset(moof, moof.length + 8);

    // Create mdat
    final mdat = writeMdat(mdatPayload);

    // Update base decode time
    _baseDecodeTime += sampleDuration * frames.length;

    // Combine moof + mdat
    final result = Uint8List(moofWithOffset.length + mdat.length);
    result.setAll(0, moofWithOffset);
    result.setAll(moofWithOffset.length, mdat);

    return result;
  }

  /// Create a single-frame media segment
  Uint8List createSingleFrameSegment(Uint8List frame) {
    return createMediaSegment(frames: [frame]);
  }

  /// Reset the muxer state
  void reset() {
    _sequenceNumber = 0;
    _baseDecodeTime = 0;
  }

  // Create init segment (ftyp + moov)
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

  // Create moov box
  Uint8List _createMoov() {
    final mvhd = writeMvhd(
      timescale: opusTimescale,
      duration: 0,
      nextTrackId: trackId + 1,
    );

    final trak = _createTrak();
    final mvex = writeMvex(trackId: trackId);

    final moovContentSize = mvhd.length + trak.length + mvex.length;
    final moovSize = 8 + moovContentSize;

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

  // Create trak box for audio
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

  // Create mdia box
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

  // Create minf box
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

  // Create stbl box with Opus sample entry
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

  // Create stsd box with Opus sample entry
  Uint8List _createStsd() {
    final opus = _createOpusSampleEntry();

    final stsdSize = 12 + 4 + opus.length;
    final data = ByteData(stsdSize);
    var offset = 0;

    // Box header
    data.setUint32(offset, stsdSize, Endian.big);
    offset += 4;
    data.setUint8(offset++, 's'.codeUnitAt(0));
    data.setUint8(offset++, 't'.codeUnitAt(0));
    data.setUint8(offset++, 's'.codeUnitAt(0));
    data.setUint8(offset++, 'd'.codeUnitAt(0));

    // Version and flags
    data.setUint32(offset, 0, Endian.big);
    offset += 4;

    // Entry count
    data.setUint32(offset, 1, Endian.big);
    offset += 4;

    final result = Uint8List(stsdSize);
    result.setAll(0, Uint8List.view(data.buffer, 0, offset));
    result.setAll(offset, opus);

    return result;
  }

  // Create Opus sample entry box
  Uint8List _createOpusSampleEntry() {
    final dops = _createDops();

    // Opus box: 8 (header) + 28 (audio sample entry) + dOps
    final opusSize = 8 + 28 + dops.length;
    final data = ByteData(opusSize);
    var offset = 0;

    // Box header
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

    // Data reference index
    data.setUint16(offset, 1, Endian.big);
    offset += 2;

    // Audio sample entry fields
    // Reserved (8 bytes)
    for (var i = 0; i < 8; i++) {
      data.setUint8(offset++, 0);
    }

    // Channel count
    data.setUint16(offset, channels, Endian.big);
    offset += 2;

    // Sample size (16 bits)
    data.setUint16(offset, 16, Endian.big);
    offset += 2;

    // Pre-defined
    data.setUint16(offset, 0, Endian.big);
    offset += 2;

    // Reserved
    data.setUint16(offset, 0, Endian.big);
    offset += 2;

    // Sample rate (16.16 fixed point, but for Opus always 48000)
    data.setUint32(offset, (48000 << 16), Endian.big);
    offset += 4;

    final result = Uint8List(opusSize);
    result.setAll(0, Uint8List.view(data.buffer, 0, offset));
    result.setAll(offset, dops);

    return result;
  }

  // Create dOps box (Opus Specific Box)
  Uint8List _createDops() {
    // dOps structure per RFC 7845 mapping to ISO-BMFF:
    // - 8 bytes: box header
    // - 1 byte: Version (0)
    // - 1 byte: OutputChannelCount
    // - 2 bytes: PreSkip (big-endian)
    // - 4 bytes: InputSampleRate (big-endian)
    // - 2 bytes: OutputGain (big-endian, signed)
    // - 1 byte: ChannelMappingFamily

    final dopsSize = 8 + 11;
    final data = ByteData(dopsSize);
    var offset = 0;

    // Box header
    data.setUint32(offset, dopsSize, Endian.big);
    offset += 4;
    data.setUint8(offset++, 'd'.codeUnitAt(0));
    data.setUint8(offset++, 'O'.codeUnitAt(0));
    data.setUint8(offset++, 'p'.codeUnitAt(0));
    data.setUint8(offset++, 's'.codeUnitAt(0));

    // Version
    data.setUint8(offset++, 0);

    // OutputChannelCount
    data.setUint8(offset++, channels);

    // PreSkip (samples to skip at start)
    data.setUint16(offset, preSkip, Endian.big);
    offset += 2;

    // InputSampleRate (the original input sample rate, not Opus internal rate)
    data.setUint32(offset, sampleRate, Endian.big);
    offset += 4;

    // OutputGain (0 dB)
    data.setInt16(offset, 0, Endian.big);
    offset += 2;

    // ChannelMappingFamily (0 = mono/stereo, 1 = surround, 255 = discrete)
    data.setUint8(offset++, channels <= 2 ? 0 : 1);

    return Uint8List.view(data.buffer);
  }

  // Update trun data offset field
  Uint8List _updateTrunDataOffset(Uint8List moof, int dataOffset) {
    final result = Uint8List.fromList(moof);

    var offset = 8; // Skip moof header

    // Skip mfhd
    final mfhdSize = (result[offset] << 24) |
        (result[offset + 1] << 16) |
        (result[offset + 2] << 8) |
        result[offset + 3];
    offset += mfhdSize;

    // Now in traf
    offset += 8; // Skip traf header

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

    // Now at trun
    // Skip header (8) + version/flags (4) + sample_count (4) = 16
    offset += 16;

    // Write data offset
    result[offset] = (dataOffset >> 24) & 0xFF;
    result[offset + 1] = (dataOffset >> 16) & 0xFF;
    result[offset + 2] = (dataOffset >> 8) & 0xFF;
    result[offset + 3] = dataOffset & 0xFF;

    return result;
  }
}
