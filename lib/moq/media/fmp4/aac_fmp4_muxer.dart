import 'package:flutter/foundation.dart';
import 'fmp4_boxes.dart';

/// AAC audio muxer for fragmented MP4 (fMP4/CMAF)
///
/// Creates init segments (ftyp+moov) and media segments (moof+mdat)
/// from AAC audio frames. Supports both raw AAC and ADTS-wrapped AAC.
class AacFmp4Muxer {
  final int sampleRate;
  final int channels;
  final int trackId;

  // AAC profile (1 = AAC-LC)
  final int profile;

  // Cached values
  Uint8List? _initSegment;
  Uint8List? _audioSpecificConfig;

  // Fragment state
  int _sequenceNumber = 0;
  int _baseDecodeTime = 0;

  // Sample rate index for AAC
  static const List<int> _sampleRateTable = [
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
    16000, 12000, 11025, 8000, 7350
  ];

  AacFmp4Muxer({
    this.sampleRate = 48000,
    this.channels = 2,
    this.trackId = 2,
    this.profile = 2, // AAC-LC object type
  });

  /// Get the codec string for AAC
  String get codecString {
    // mp4a.40.2 = AAC-LC
    // mp4a.40.5 = HE-AAC (SBR)
    // mp4a.40.29 = HE-AACv2 (SBR+PS)
    return 'mp4a.40.$profile';
  }

  /// Get the MIME type
  String get mimeType => 'audio/mp4; codecs="$codecString"';

  /// Check if init segment is ready
  bool get isInitReady => true;

  /// Get init segment (ftyp + moov)
  Uint8List get initSegment {
    _initSegment ??= _createInitSegment();
    return _initSegment!;
  }

  /// Get sample rate index for AAC
  int get _sampleRateIndex {
    final idx = _sampleRateTable.indexOf(sampleRate);
    return idx >= 0 ? idx : 3; // Default to 48kHz
  }

  /// Get AudioSpecificConfig for AAC
  Uint8List get audioSpecificConfig {
    if (_audioSpecificConfig != null) return _audioSpecificConfig!;

    // AudioSpecificConfig (2 bytes for AAC-LC):
    // 5 bits: object type (2 = AAC-LC)
    // 4 bits: frequency index
    // 4 bits: channel configuration
    // 3 bits: frame length flag (0) + depends on core coder (0) + extension flag (0)

    final objectType = profile; // AAC-LC = 2
    final freqIndex = _sampleRateIndex;
    final channelConfig = channels;

    // Pack into 2 bytes
    final byte0 = (objectType << 3) | (freqIndex >> 1);
    final byte1 = ((freqIndex & 0x01) << 7) | (channelConfig << 3);

    _audioSpecificConfig = Uint8List.fromList([byte0, byte1]);
    return _audioSpecificConfig!;
  }

  /// Samples per frame (1024 for AAC-LC)
  int get samplesPerFrame => 1024;

  /// Create a media segment from raw AAC frame(s)
  ///
  /// [frames] is a list of raw AAC frames (without ADTS headers)
  Uint8List createMediaSegment({required List<Uint8List> frames}) {
    if (frames.isEmpty) {
      throw ArgumentError('At least one frame must be provided');
    }

    final sampleSizes = frames.map((f) => f.length).toList();
    final sampleDuration = samplesPerFrame;
    final sampleDurations = List.filled(frames.length, sampleDuration);
    final sampleFlags = List.filled(frames.length, 0x02000000); // Sync samples

    // Concatenate frames for mdat
    final totalSize = frames.fold<int>(0, (sum, f) => sum + f.length);
    final mdatPayload = Uint8List(totalSize);
    var offset = 0;
    for (final frame in frames) {
      mdatPayload.setAll(offset, frame);
      offset += frame.length;
    }

    final moof = writeMoof(
      sequenceNumber: ++_sequenceNumber,
      trackId: trackId,
      baseMediaDecodeTime: _baseDecodeTime,
      sampleSizes: sampleSizes,
      sampleDurations: sampleDurations,
      sampleFlags: sampleFlags,
    );

    final moofWithOffset = _updateTrunDataOffset(moof, moof.length + 8);
    final mdat = writeMdat(mdatPayload);

    _baseDecodeTime += sampleDuration * frames.length;

    final result = Uint8List(moofWithOffset.length + mdat.length);
    result.setAll(0, moofWithOffset);
    result.setAll(moofWithOffset.length, mdat);

    return result;
  }

  /// Create a single-frame media segment
  Uint8List createSingleFrameSegment(Uint8List frame) {
    return createMediaSegment(frames: [frame]);
  }

  /// Create media segment from ADTS-wrapped AAC data
  ///
  /// Strips ADTS headers and creates fMP4 segment
  Uint8List createMediaSegmentFromAdts(Uint8List adtsData) {
    final frames = stripAdtsHeaders(adtsData);
    if (frames.isEmpty) {
      throw ArgumentError('No valid AAC frames found in ADTS data');
    }
    return createMediaSegment(frames: frames);
  }

  /// Reset muxer state
  void reset() {
    _sequenceNumber = 0;
    _baseDecodeTime = 0;
    _initSegment = null;
  }

  /// Strip ADTS headers from AAC data and return raw frames
  ///
  /// ADTS header is 7 bytes (or 9 with CRC)
  static List<Uint8List> stripAdtsHeaders(Uint8List data) {
    final frames = <Uint8List>[];
    var offset = 0;

    while (offset + 7 <= data.length) {
      // Check for ADTS sync word (0xFFF)
      if (data[offset] != 0xFF || (data[offset + 1] & 0xF0) != 0xF0) {
        // Not an ADTS frame, skip byte
        offset++;
        continue;
      }

      // Parse ADTS header
      final protectionAbsent = (data[offset + 1] & 0x01) == 1;
      final headerSize = protectionAbsent ? 7 : 9;

      // Frame length (13 bits spanning bytes 3-5)
      final frameLength = ((data[offset + 3] & 0x03) << 11) |
          (data[offset + 4] << 3) |
          ((data[offset + 5] & 0xE0) >> 5);

      if (frameLength < headerSize || offset + frameLength > data.length) {
        debugPrint('AacFmp4Muxer: Invalid ADTS frame length: $frameLength');
        break;
      }

      // Extract raw AAC frame (without header)
      final payloadSize = frameLength - headerSize;
      if (payloadSize > 0) {
        frames.add(
            Uint8List.sublistView(data, offset + headerSize, offset + frameLength));
      }

      offset += frameLength;
    }

    return frames;
  }

  /// Parse ADTS header to get audio parameters
  ///
  /// Returns (sampleRate, channels, profile) or null if invalid
  static (int, int, int)? parseAdtsHeader(Uint8List data) {
    if (data.length < 7) return null;

    // Check sync word
    if (data[0] != 0xFF || (data[1] & 0xF0) != 0xF0) return null;

    // Profile (2 bits) - stored as object_type - 1
    final profileIndex = (data[2] & 0xC0) >> 6;
    final profile = profileIndex + 1; // Convert to object type

    // Sample rate index (4 bits)
    final sampleRateIndex = (data[2] & 0x3C) >> 2;
    final sampleRate = sampleRateIndex < _sampleRateTable.length
        ? _sampleRateTable[sampleRateIndex]
        : 48000;

    // Channel configuration (3 bits spanning bytes 2-3)
    final channels = ((data[2] & 0x01) << 2) | ((data[3] & 0xC0) >> 6);

    return (sampleRate, channels, profile);
  }

  /// Check if data has ADTS headers
  static bool hasAdtsHeader(Uint8List data) {
    return data.length >= 7 &&
        data[0] == 0xFF &&
        (data[1] & 0xF0) == 0xF0;
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
      timescale: sampleRate,
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
      timescale: sampleRate,
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
    final mp4a = _createMp4a();

    final stsdSize = 12 + 4 + mp4a.length;
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
    result.setAll(offset, mp4a);

    return result;
  }

  /// Create mp4a sample entry box with esds
  Uint8List _createMp4a() {
    final esds = _createEsds();

    // mp4a box: 8 (header) + 28 (audio sample entry) + esds
    final mp4aSize = 8 + 28 + esds.length;
    final data = ByteData(mp4aSize);
    var offset = 0;

    // Box header
    data.setUint32(offset, mp4aSize, Endian.big);
    offset += 4;
    data.setUint8(offset++, 'm'.codeUnitAt(0));
    data.setUint8(offset++, 'p'.codeUnitAt(0));
    data.setUint8(offset++, '4'.codeUnitAt(0));
    data.setUint8(offset++, 'a'.codeUnitAt(0));

    // Reserved (6 bytes)
    for (var i = 0; i < 6; i++) {
      data.setUint8(offset++, 0);
    }

    // Data reference index
    data.setUint16(offset, 1, Endian.big);
    offset += 2;

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

    // Sample rate (16.16 fixed point)
    data.setUint32(offset, sampleRate << 16, Endian.big);
    offset += 4;

    final result = Uint8List(mp4aSize);
    result.setAll(0, Uint8List.view(data.buffer, 0, offset));
    result.setAll(offset, esds);

    return result;
  }

  /// Create esds box (Elementary Stream Descriptor)
  Uint8List _createEsds() {
    final asc = audioSpecificConfig;

    // Calculate sizes
    final decSpecificInfoSize = 2 + asc.length; // tag + size + ASC
    final decConfigDescrSize = 2 + 13 + decSpecificInfoSize; // tag + size + fields + DSI
    final esDescrSize = 2 + 3 + decConfigDescrSize + 3; // tag + size + ES_ID + DCD + SL

    final esdsSize = 12 + esDescrSize; // box header + version/flags + ES_Descriptor
    final data = ByteData(esdsSize);
    var offset = 0;

    // Box header
    data.setUint32(offset, esdsSize, Endian.big);
    offset += 4;
    data.setUint8(offset++, 'e'.codeUnitAt(0));
    data.setUint8(offset++, 's'.codeUnitAt(0));
    data.setUint8(offset++, 'd'.codeUnitAt(0));
    data.setUint8(offset++, 's'.codeUnitAt(0));

    // Version and flags
    data.setUint32(offset, 0, Endian.big);
    offset += 4;

    // ES_Descriptor
    data.setUint8(offset++, 0x03); // ES_DescrTag
    data.setUint8(offset++, esDescrSize - 2); // Size (excluding tag and size bytes)

    // ES_ID
    data.setUint16(offset, 1, Endian.big);
    offset += 2;

    // Flags
    data.setUint8(offset++, 0);

    // DecoderConfigDescriptor
    data.setUint8(offset++, 0x04); // DecoderConfigDescrTag
    data.setUint8(offset++, decConfigDescrSize - 2);

    // Object type indication (0x40 = Audio ISO/IEC 14496-3)
    data.setUint8(offset++, 0x40);

    // Stream type (5 = audio) << 2 | upstream flag | reserved
    data.setUint8(offset++, 0x15);

    // Buffer size (3 bytes)
    data.setUint8(offset++, 0x00);
    data.setUint8(offset++, 0x00);
    data.setUint8(offset++, 0x00);

    // Max bitrate
    data.setUint32(offset, 128000, Endian.big);
    offset += 4;

    // Avg bitrate
    data.setUint32(offset, 128000, Endian.big);
    offset += 4;

    // DecoderSpecificInfo
    data.setUint8(offset++, 0x05); // DecSpecificInfoTag
    data.setUint8(offset++, asc.length);

    final result = Uint8List(esdsSize);
    result.setAll(0, Uint8List.view(data.buffer, 0, offset));
    result.setAll(offset, asc);
    offset += asc.length;

    // SLConfigDescriptor
    result[offset++] = 0x06; // SLConfigDescrTag
    result[offset++] = 0x01; // Size
    result[offset++] = 0x02; // Predefined = 2

    return result;
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
