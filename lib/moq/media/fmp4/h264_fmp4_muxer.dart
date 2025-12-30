import 'dart:convert';
import 'dart:typed_data';
import 'fmp4_boxes.dart';

/// H.264 video muxer for fragmented MP4 (fMP4/CMAF)
///
/// Creates init segments (ftyp+moov) and media segments (moof+mdat)
/// from H.264 NAL units in Annex B format.
class H264Fmp4Muxer {
  final int width;
  final int height;
  final int frameRate;
  final int timescale;
  final int trackId;

  // Codec configuration from SPS/PPS
  Uint8List? _spsData;
  Uint8List? _ppsData;
  Uint8List? _initSegment;
  String? _codecString;

  // Fragment state
  int _sequenceNumber = 0;
  int _baseDecodeTime = 0;

  H264Fmp4Muxer({
    required this.width,
    required this.height,
    this.frameRate = 30,
    this.timescale = 90000, // Standard video timescale
    this.trackId = 1,
  });

  /// Set SPS (Sequence Parameter Set) from H.264 stream
  void setSps(Uint8List sps) {
    // Strip start code if present
    _spsData = _stripStartCode(sps);
    _initSegment = null; // Invalidate cached init segment
    _parseCodecString();
  }

  /// Set PPS (Picture Parameter Set) from H.264 stream
  void setPps(Uint8List pps) {
    // Strip start code if present
    _ppsData = _stripStartCode(pps);
    _initSegment = null;
  }

  /// Extract SPS/PPS from an H.264 bitstream with Annex B start codes
  void parseSpsPpsFromBitstream(Uint8List data) {
    final nalUnits = _extractNalUnits(data);

    for (final nal in nalUnits) {
      if (nal.isEmpty) continue;
      final nalType = nal[0] & 0x1F;

      if (nalType == 7) {
        // SPS
        _spsData = nal;
        _parseCodecString();
      } else if (nalType == 8) {
        // PPS
        _ppsData = nal;
      }
    }
    _initSegment = null;
  }

  /// Get the codec string (e.g., "avc1.64001f")
  String? get codecString => _codecString;

  /// Check if init segment is ready
  bool get isInitReady => _spsData != null && _ppsData != null;

  /// Get init segment data (ftyp + moov)
  Uint8List? get initSegment {
    if (!isInitReady) return null;
    _initSegment ??= _createInitSegment();
    return _initSegment;
  }

  /// Get init segment as base64 for catalog
  String? get initDataBase64 {
    final init = initSegment;
    return init != null ? base64.encode(init) : null;
  }

  /// Create a media segment (moof + mdat) from H.264 frame data
  ///
  /// [frameData] is the H.264 frame with Annex B start codes
  /// [isKeyframe] indicates if this is an IDR frame
  /// [durationMs] is the frame duration in milliseconds
  Uint8List createMediaSegment({
    required Uint8List frameData,
    required bool isKeyframe,
    int? durationMs,
  }) {
    final duration = durationMs != null
        ? (durationMs * timescale ~/ 1000)
        : (timescale ~/ frameRate);

    // Convert Annex B to AVCC format (length-prefixed)
    final avccData = _annexBToAvcc(frameData);

    // Create moof
    final moof = writeMoof(
      sequenceNumber: ++_sequenceNumber,
      trackId: trackId,
      baseMediaDecodeTime: _baseDecodeTime,
      sampleSizes: [avccData.length],
      sampleDurations: [duration],
      sampleFlags: [isKeyframe ? SampleFlags.keyframe : SampleFlags.nonKeyframe],
    );

    // Update data offset in trun
    // The data offset points from the start of moof to the start of mdat data
    final moofWithOffset = _updateTrunDataOffset(moof, moof.length + 8);

    // Create mdat
    final mdat = writeMdat(avccData);

    // Update base decode time for next segment
    _baseDecodeTime += duration;

    // Combine moof + mdat
    final result = Uint8List(moofWithOffset.length + mdat.length);
    result.setAll(0, moofWithOffset);
    result.setAll(moofWithOffset.length, mdat);

    return result;
  }

  /// Reset the muxer state (for new stream)
  void reset() {
    _sequenceNumber = 0;
    _baseDecodeTime = 0;
  }

  // Helper to strip Annex B start codes
  Uint8List _stripStartCode(Uint8List data) {
    if (data.length < 4) return data;

    int offset = 0;
    if (data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1) {
      offset = 4;
    } else if (data[0] == 0 && data[1] == 0 && data[2] == 1) {
      offset = 3;
    }

    return offset > 0 ? Uint8List.sublistView(data, offset) : data;
  }

  // Parse codec string from SPS
  void _parseCodecString() {
    if (_spsData == null || _spsData!.length < 4) return;

    final profile = _spsData![1];
    final constraints = _spsData![2];
    final level = _spsData![3];

    _codecString =
        'avc1.${profile.toRadixString(16).padLeft(2, '0')}${constraints.toRadixString(16).padLeft(2, '0')}${level.toRadixString(16).padLeft(2, '0')}';
  }

  // Extract NAL units from Annex B bitstream
  List<Uint8List> _extractNalUnits(Uint8List data) {
    final nalUnits = <Uint8List>[];
    int start = -1;

    for (var i = 0; i < data.length - 3; i++) {
      bool isStartCode = false;
      int startCodeLen = 0;

      if (i + 3 < data.length &&
          data[i] == 0 &&
          data[i + 1] == 0 &&
          data[i + 2] == 0 &&
          data[i + 3] == 1) {
        isStartCode = true;
        startCodeLen = 4;
      } else if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
        isStartCode = true;
        startCodeLen = 3;
      }

      if (isStartCode) {
        if (start >= 0) {
          nalUnits.add(Uint8List.sublistView(data, start, i));
        }
        start = i + startCodeLen;
        i += startCodeLen - 1;
      }
    }

    if (start >= 0 && start < data.length) {
      nalUnits.add(Uint8List.sublistView(data, start));
    }

    return nalUnits;
  }

  // Convert Annex B format to AVCC format (length-prefixed NAL units)
  Uint8List _annexBToAvcc(Uint8List data) {
    final nalUnits = _extractNalUnits(data);
    if (nalUnits.isEmpty) return data;

    // Filter out SPS/PPS/SEI - keep only VCL NAL units for mdat
    final vclUnits = <Uint8List>[];
    for (final nal in nalUnits) {
      if (nal.isEmpty) continue;
      final nalType = nal[0] & 0x1F;
      // Include slice types (1-5) but not parameter sets (6-9)
      if (nalType >= 1 && nalType <= 5) {
        vclUnits.add(nal);
      }
    }

    if (vclUnits.isEmpty) {
      // No VCL units, just convert all
      return _lengthPrefixNalUnits(nalUnits);
    }

    return _lengthPrefixNalUnits(vclUnits);
  }

  Uint8List _lengthPrefixNalUnits(List<Uint8List> nalUnits) {
    // Calculate total size
    int totalSize = 0;
    for (final nal in nalUnits) {
      totalSize += 4 + nal.length; // 4-byte length prefix
    }

    final result = Uint8List(totalSize);
    final byteData = ByteData.view(result.buffer);
    var offset = 0;

    for (final nal in nalUnits) {
      byteData.setUint32(offset, nal.length, Endian.big);
      offset += 4;
      result.setAll(offset, nal);
      offset += nal.length;
    }

    return result;
  }

  // Create init segment (ftyp + moov)
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

  // Create moov box
  Uint8List _createMoov() {
    final mvhd = writeMvhd(
      timescale: timescale,
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

  // Create trak box for video
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

  // Create mdia box
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

  // Create minf box
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

  // Create stbl box with avc1 sample entry
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

  // Create stsd box with avc1 sample entry
  Uint8List _createStsd() {
    final avc1 = _createAvc1();

    final stsdSize = 12 + 4 + avc1.length;
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
    result.setAll(offset, avc1);

    return result;
  }

  // Create avc1 sample entry box
  Uint8List _createAvc1() {
    final avcc = _createAvcc();

    // avc1 box: 8 (header) + 78 (sample entry) + avcc
    final avc1Size = 8 + 78 + avcc.length;
    final data = ByteData(avc1Size);
    var offset = 0;

    // Box header
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

    // Pre-defined
    data.setUint16(offset, 0, Endian.big);
    offset += 2;

    // Reserved
    data.setUint16(offset, 0, Endian.big);
    offset += 2;

    // Pre-defined (12 bytes)
    for (var i = 0; i < 12; i++) {
      data.setUint8(offset++, 0);
    }

    // Width
    data.setUint16(offset, width, Endian.big);
    offset += 2;

    // Height
    data.setUint16(offset, height, Endian.big);
    offset += 2;

    // Horizontal resolution (72 dpi = 0x00480000)
    data.setUint32(offset, 0x00480000, Endian.big);
    offset += 4;

    // Vertical resolution (72 dpi)
    data.setUint32(offset, 0x00480000, Endian.big);
    offset += 4;

    // Reserved
    data.setUint32(offset, 0, Endian.big);
    offset += 4;

    // Frame count
    data.setUint16(offset, 1, Endian.big);
    offset += 2;

    // Compressor name (32 bytes) - empty
    for (var i = 0; i < 32; i++) {
      data.setUint8(offset++, 0);
    }

    // Depth
    data.setUint16(offset, 0x0018, Endian.big);
    offset += 2;

    // Pre-defined
    data.setInt16(offset, -1, Endian.big);
    offset += 2;

    final result = Uint8List(avc1Size);
    result.setAll(0, Uint8List.view(data.buffer, 0, offset));
    result.setAll(offset, avcc);

    return result;
  }

  // Create avcC box (AVC Decoder Configuration Record)
  Uint8List _createAvcc() {
    if (_spsData == null || _ppsData == null) {
      throw StateError('SPS and PPS must be set before creating init segment');
    }

    // avcC structure:
    // 8 bytes header
    // 1 byte configurationVersion = 1
    // 1 byte AVCProfileIndication (from SPS)
    // 1 byte profile_compatibility (from SPS)
    // 1 byte AVCLevelIndication (from SPS)
    // 1 byte lengthSizeMinusOne = 3 (4-byte NAL length)
    // 1 byte numOfSPS (lower 5 bits) | 0xE0
    // 2 bytes SPS length
    // SPS data
    // 1 byte numOfPPS
    // 2 bytes PPS length
    // PPS data

    final avccSize = 8 + 6 + 2 + _spsData!.length + 1 + 2 + _ppsData!.length;
    final data = ByteData(avccSize);
    var offset = 0;

    // Box header
    data.setUint32(offset, avccSize, Endian.big);
    offset += 4;
    data.setUint8(offset++, 'a'.codeUnitAt(0));
    data.setUint8(offset++, 'v'.codeUnitAt(0));
    data.setUint8(offset++, 'c'.codeUnitAt(0));
    data.setUint8(offset++, 'C'.codeUnitAt(0));

    // configurationVersion
    data.setUint8(offset++, 1);

    // AVCProfileIndication
    data.setUint8(offset++, _spsData![1]);

    // profile_compatibility
    data.setUint8(offset++, _spsData![2]);

    // AVCLevelIndication
    data.setUint8(offset++, _spsData![3]);

    // lengthSizeMinusOne = 3 (4-byte lengths) | 0xFC reserved bits
    data.setUint8(offset++, 0xFF);

    // numOfSPS = 1 | 0xE0 reserved bits
    data.setUint8(offset++, 0xE1);

    // SPS length
    data.setUint16(offset, _spsData!.length, Endian.big);
    offset += 2;

    // SPS data
    final result = Uint8List(avccSize);
    result.setAll(0, Uint8List.view(data.buffer, 0, offset));
    result.setAll(offset, _spsData!);
    offset += _spsData!.length;

    // numOfPPS
    result[offset++] = 1;

    // PPS length
    result[offset] = (_ppsData!.length >> 8) & 0xFF;
    result[offset + 1] = _ppsData!.length & 0xFF;
    offset += 2;

    // PPS data
    result.setAll(offset, _ppsData!);

    return result;
  }

  // Update trun data offset field
  Uint8List _updateTrunDataOffset(Uint8List moof, int dataOffset) {
    // Find trun box and update its data offset
    // trun is inside moof -> traf
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
