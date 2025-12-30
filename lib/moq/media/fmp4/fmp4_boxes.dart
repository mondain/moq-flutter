import 'dart:typed_data';

/// Low-level MP4 box (atom) writer utilities for fragmented MP4 (fMP4/CMAF)
///
/// Implements ISO Base Media File Format (ISO/IEC 14496-12) box structures.

/// Write a 32-bit box header
ByteData writeBoxHeader(int size, String type) {
  final header = ByteData(8);
  header.setUint32(0, size, Endian.big);
  header.setUint8(4, type.codeUnitAt(0));
  header.setUint8(5, type.codeUnitAt(1));
  header.setUint8(6, type.codeUnitAt(2));
  header.setUint8(7, type.codeUnitAt(3));
  return header;
}

/// Write a full box header (with version and flags)
ByteData writeFullBoxHeader(int size, String type, int version, int flags) {
  final header = ByteData(12);
  header.setUint32(0, size, Endian.big);
  header.setUint8(4, type.codeUnitAt(0));
  header.setUint8(5, type.codeUnitAt(1));
  header.setUint8(6, type.codeUnitAt(2));
  header.setUint8(7, type.codeUnitAt(3));
  header.setUint8(8, version);
  header.setUint8(9, (flags >> 16) & 0xFF);
  header.setUint8(10, (flags >> 8) & 0xFF);
  header.setUint8(11, flags & 0xFF);
  return header;
}

/// Helper to build boxes from components
class BoxBuilder {
  final List<Uint8List> _parts = [];

  void add(Uint8List data) {
    _parts.add(data);
  }

  void addByteData(ByteData data) {
    _parts.add(Uint8List.view(data.buffer));
  }

  int get length => _parts.fold(0, (sum, part) => sum + part.length);

  Uint8List build() {
    final total = length;
    final result = Uint8List(total);
    var offset = 0;
    for (final part in _parts) {
      result.setAll(offset, part);
      offset += part.length;
    }
    return result;
  }

  Uint8List buildBox(String type) {
    final contentLength = length;
    final boxSize = 8 + contentLength;
    final result = Uint8List(boxSize);

    // Write header
    final header = writeBoxHeader(boxSize, type);
    result.setAll(0, Uint8List.view(header.buffer));

    // Write content
    var offset = 8;
    for (final part in _parts) {
      result.setAll(offset, part);
      offset += part.length;
    }
    return result;
  }
}

/// ftyp box - File Type Box
Uint8List writeFtyp({
  String majorBrand = 'isom',
  int minorVersion = 512,
  List<String> compatibleBrands = const ['isom', 'iso6', 'mp41'],
}) {
  final builder = BoxBuilder();

  // Major brand (4 bytes)
  final brandBytes = ByteData(4);
  for (var i = 0; i < 4; i++) {
    brandBytes.setUint8(i, majorBrand.codeUnitAt(i));
  }
  builder.addByteData(brandBytes);

  // Minor version (4 bytes)
  final version = ByteData(4);
  version.setUint32(0, minorVersion, Endian.big);
  builder.addByteData(version);

  // Compatible brands (4 bytes each)
  for (final brand in compatibleBrands) {
    final cb = ByteData(4);
    for (var i = 0; i < 4; i++) {
      cb.setUint8(i, brand.codeUnitAt(i));
    }
    builder.addByteData(cb);
  }

  return builder.buildBox('ftyp');
}

/// mvhd box - Movie Header Box
Uint8List writeMvhd({
  int timescale = 1000,
  int duration = 0,
  int nextTrackId = 2,
}) {
  // Version 0: 32-bit times
  final size = 12 + 96; // full box header + content
  final data = ByteData(size);
  var offset = 0;

  // Box header
  data.setUint32(offset, size, Endian.big);
  offset += 4;
  data.setUint8(offset++, 'm'.codeUnitAt(0));
  data.setUint8(offset++, 'v'.codeUnitAt(0));
  data.setUint8(offset++, 'h'.codeUnitAt(0));
  data.setUint8(offset++, 'd'.codeUnitAt(0));

  // Version and flags
  data.setUint32(offset, 0, Endian.big); // version 0, flags 0
  offset += 4;

  // Creation time (4 bytes)
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Modification time (4 bytes)
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Timescale (4 bytes)
  data.setUint32(offset, timescale, Endian.big);
  offset += 4;

  // Duration (4 bytes)
  data.setUint32(offset, duration, Endian.big);
  offset += 4;

  // Rate (4 bytes) - 1.0 = 0x00010000
  data.setUint32(offset, 0x00010000, Endian.big);
  offset += 4;

  // Volume (2 bytes) - 1.0 = 0x0100
  data.setUint16(offset, 0x0100, Endian.big);
  offset += 2;

  // Reserved (2 bytes)
  data.setUint16(offset, 0, Endian.big);
  offset += 2;

  // Reserved (8 bytes)
  for (var i = 0; i < 8; i++) {
    data.setUint8(offset++, 0);
  }

  // Matrix (36 bytes) - identity matrix
  // { 0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000 }
  data.setUint32(offset, 0x00010000, Endian.big);
  offset += 4;
  for (var i = 0; i < 3; i++) {
    data.setUint32(offset, 0, Endian.big);
    offset += 4;
  }
  data.setUint32(offset, 0x00010000, Endian.big);
  offset += 4;
  for (var i = 0; i < 3; i++) {
    data.setUint32(offset, 0, Endian.big);
    offset += 4;
  }
  data.setUint32(offset, 0x40000000, Endian.big);
  offset += 4;

  // Pre-defined (24 bytes)
  for (var i = 0; i < 24; i++) {
    data.setUint8(offset++, 0);
  }

  // Next track ID (4 bytes)
  data.setUint32(offset, nextTrackId, Endian.big);

  return Uint8List.view(data.buffer);
}

/// tkhd box - Track Header Box
Uint8List writeTkhd({
  required int trackId,
  int duration = 0,
  int width = 0,
  int height = 0,
  bool isVideo = true,
  int volume = 0x0100, // 1.0 for audio, 0 for video
}) {
  // Version 0
  final size = 12 + 80;
  final data = ByteData(size);
  var offset = 0;

  // Box header
  data.setUint32(offset, size, Endian.big);
  offset += 4;
  data.setUint8(offset++, 't'.codeUnitAt(0));
  data.setUint8(offset++, 'k'.codeUnitAt(0));
  data.setUint8(offset++, 'h'.codeUnitAt(0));
  data.setUint8(offset++, 'd'.codeUnitAt(0));

  // Version 0, flags 0x000003 (track enabled, in movie)
  data.setUint8(offset++, 0);
  data.setUint8(offset++, 0);
  data.setUint8(offset++, 0);
  data.setUint8(offset++, 3);

  // Creation time
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Modification time
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Track ID
  data.setUint32(offset, trackId, Endian.big);
  offset += 4;

  // Reserved
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Duration
  data.setUint32(offset, duration, Endian.big);
  offset += 4;

  // Reserved (8 bytes)
  for (var i = 0; i < 8; i++) {
    data.setUint8(offset++, 0);
  }

  // Layer
  data.setUint16(offset, 0, Endian.big);
  offset += 2;

  // Alternate group
  data.setUint16(offset, 0, Endian.big);
  offset += 2;

  // Volume (audio: 0x0100, video: 0)
  data.setUint16(offset, isVideo ? 0 : volume, Endian.big);
  offset += 2;

  // Reserved
  data.setUint16(offset, 0, Endian.big);
  offset += 2;

  // Matrix (36 bytes) - identity
  data.setUint32(offset, 0x00010000, Endian.big);
  offset += 4;
  for (var i = 0; i < 3; i++) {
    data.setUint32(offset, 0, Endian.big);
    offset += 4;
  }
  data.setUint32(offset, 0x00010000, Endian.big);
  offset += 4;
  for (var i = 0; i < 3; i++) {
    data.setUint32(offset, 0, Endian.big);
    offset += 4;
  }
  data.setUint32(offset, 0x40000000, Endian.big);
  offset += 4;

  // Width (16.16 fixed point)
  data.setUint32(offset, (width << 16), Endian.big);
  offset += 4;

  // Height (16.16 fixed point)
  data.setUint32(offset, (height << 16), Endian.big);

  return Uint8List.view(data.buffer);
}

/// mdhd box - Media Header Box
Uint8List writeMdhd({
  int timescale = 90000,
  int duration = 0,
  String language = 'und', // undetermined
}) {
  final size = 12 + 20;
  final data = ByteData(size);
  var offset = 0;

  // Box header
  data.setUint32(offset, size, Endian.big);
  offset += 4;
  data.setUint8(offset++, 'm'.codeUnitAt(0));
  data.setUint8(offset++, 'd'.codeUnitAt(0));
  data.setUint8(offset++, 'h'.codeUnitAt(0));
  data.setUint8(offset++, 'd'.codeUnitAt(0));

  // Version and flags
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Creation time
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Modification time
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Timescale
  data.setUint32(offset, timescale, Endian.big);
  offset += 4;

  // Duration
  data.setUint32(offset, duration, Endian.big);
  offset += 4;

  // Language (ISO-639-2/T packed as 3x5 bits)
  // 'und' = 0x55C4
  int langCode = 0;
  for (var i = 0; i < 3; i++) {
    langCode = (langCode << 5) | (language.codeUnitAt(i) - 0x60);
  }
  data.setUint16(offset, langCode, Endian.big);
  offset += 2;

  // Pre-defined
  data.setUint16(offset, 0, Endian.big);

  return Uint8List.view(data.buffer);
}

/// hdlr box - Handler Reference Box
Uint8List writeHdlr({
  required String handlerType, // 'vide' or 'soun'
  String name = '',
}) {
  final nameBytes = Uint8List.fromList([...name.codeUnits, 0]); // null terminated
  final size = 12 + 20 + nameBytes.length;
  final data = ByteData(size);
  var offset = 0;

  // Box header
  data.setUint32(offset, size, Endian.big);
  offset += 4;
  data.setUint8(offset++, 'h'.codeUnitAt(0));
  data.setUint8(offset++, 'd'.codeUnitAt(0));
  data.setUint8(offset++, 'l'.codeUnitAt(0));
  data.setUint8(offset++, 'r'.codeUnitAt(0));

  // Version and flags
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Pre-defined
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Handler type
  for (var i = 0; i < 4; i++) {
    data.setUint8(offset++, handlerType.codeUnitAt(i));
  }

  // Reserved (12 bytes)
  for (var i = 0; i < 12; i++) {
    data.setUint8(offset++, 0);
  }

  // Name
  final result = Uint8List(size);
  result.setAll(0, Uint8List.view(data.buffer, 0, offset));
  result.setAll(offset, nameBytes);

  return result;
}

/// vmhd box - Video Media Header Box
Uint8List writeVmhd() {
  final size = 12 + 8;
  final data = ByteData(size);
  var offset = 0;

  // Box header
  data.setUint32(offset, size, Endian.big);
  offset += 4;
  data.setUint8(offset++, 'v'.codeUnitAt(0));
  data.setUint8(offset++, 'm'.codeUnitAt(0));
  data.setUint8(offset++, 'h'.codeUnitAt(0));
  data.setUint8(offset++, 'd'.codeUnitAt(0));

  // Version 0, flags 1
  data.setUint8(offset++, 0);
  data.setUint8(offset++, 0);
  data.setUint8(offset++, 0);
  data.setUint8(offset++, 1);

  // Graphics mode
  data.setUint16(offset, 0, Endian.big);
  offset += 2;

  // Opcolor (6 bytes)
  for (var i = 0; i < 6; i++) {
    data.setUint8(offset++, 0);
  }

  return Uint8List.view(data.buffer);
}

/// smhd box - Sound Media Header Box
Uint8List writeSmhd() {
  final size = 12 + 4;
  final data = ByteData(size);
  var offset = 0;

  // Box header
  data.setUint32(offset, size, Endian.big);
  offset += 4;
  data.setUint8(offset++, 's'.codeUnitAt(0));
  data.setUint8(offset++, 'm'.codeUnitAt(0));
  data.setUint8(offset++, 'h'.codeUnitAt(0));
  data.setUint8(offset++, 'd'.codeUnitAt(0));

  // Version and flags
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Balance
  data.setUint16(offset, 0, Endian.big);
  offset += 2;

  // Reserved
  data.setUint16(offset, 0, Endian.big);

  return Uint8List.view(data.buffer);
}

/// dinf + dref box - Data Information Box
Uint8List writeDinf() {
  // dref box with url entry
  final drefSize = 12 + 16; // full box + single url entry
  final dinfSize = 8 + drefSize;

  final data = ByteData(dinfSize);
  var offset = 0;

  // dinf header
  data.setUint32(offset, dinfSize, Endian.big);
  offset += 4;
  data.setUint8(offset++, 'd'.codeUnitAt(0));
  data.setUint8(offset++, 'i'.codeUnitAt(0));
  data.setUint8(offset++, 'n'.codeUnitAt(0));
  data.setUint8(offset++, 'f'.codeUnitAt(0));

  // dref header
  data.setUint32(offset, drefSize, Endian.big);
  offset += 4;
  data.setUint8(offset++, 'd'.codeUnitAt(0));
  data.setUint8(offset++, 'r'.codeUnitAt(0));
  data.setUint8(offset++, 'e'.codeUnitAt(0));
  data.setUint8(offset++, 'f'.codeUnitAt(0));

  // Version and flags
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Entry count
  data.setUint32(offset, 1, Endian.big);
  offset += 4;

  // url box (12 bytes)
  data.setUint32(offset, 12, Endian.big);
  offset += 4;
  data.setUint8(offset++, 'u'.codeUnitAt(0));
  data.setUint8(offset++, 'r'.codeUnitAt(0));
  data.setUint8(offset++, 'l'.codeUnitAt(0));
  data.setUint8(offset++, ' '.codeUnitAt(0));

  // Version 0, flags 1 (self-contained)
  data.setUint8(offset++, 0);
  data.setUint8(offset++, 0);
  data.setUint8(offset++, 0);
  data.setUint8(offset++, 1);

  return Uint8List.view(data.buffer);
}

/// Empty stts box - Decoding Time to Sample Box
Uint8List writeStts() {
  final size = 12 + 4;
  final data = ByteData(size);
  var offset = 0;

  data.setUint32(offset, size, Endian.big);
  offset += 4;
  data.setUint8(offset++, 's'.codeUnitAt(0));
  data.setUint8(offset++, 't'.codeUnitAt(0));
  data.setUint8(offset++, 't'.codeUnitAt(0));
  data.setUint8(offset++, 's'.codeUnitAt(0));

  // Version and flags
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Entry count = 0
  data.setUint32(offset, 0, Endian.big);

  return Uint8List.view(data.buffer);
}

/// Empty stsc box - Sample To Chunk Box
Uint8List writeStsc() {
  final size = 12 + 4;
  final data = ByteData(size);
  var offset = 0;

  data.setUint32(offset, size, Endian.big);
  offset += 4;
  data.setUint8(offset++, 's'.codeUnitAt(0));
  data.setUint8(offset++, 't'.codeUnitAt(0));
  data.setUint8(offset++, 's'.codeUnitAt(0));
  data.setUint8(offset++, 'c'.codeUnitAt(0));

  // Version and flags
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Entry count = 0
  data.setUint32(offset, 0, Endian.big);

  return Uint8List.view(data.buffer);
}

/// Empty stsz box - Sample Size Box
Uint8List writeStsz() {
  final size = 12 + 8;
  final data = ByteData(size);
  var offset = 0;

  data.setUint32(offset, size, Endian.big);
  offset += 4;
  data.setUint8(offset++, 's'.codeUnitAt(0));
  data.setUint8(offset++, 't'.codeUnitAt(0));
  data.setUint8(offset++, 's'.codeUnitAt(0));
  data.setUint8(offset++, 'z'.codeUnitAt(0));

  // Version and flags
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Sample size = 0 (variable)
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Sample count = 0
  data.setUint32(offset, 0, Endian.big);

  return Uint8List.view(data.buffer);
}

/// Empty stco box - Chunk Offset Box
Uint8List writeStco() {
  final size = 12 + 4;
  final data = ByteData(size);
  var offset = 0;

  data.setUint32(offset, size, Endian.big);
  offset += 4;
  data.setUint8(offset++, 's'.codeUnitAt(0));
  data.setUint8(offset++, 't'.codeUnitAt(0));
  data.setUint8(offset++, 'c'.codeUnitAt(0));
  data.setUint8(offset++, 'o'.codeUnitAt(0));

  // Version and flags
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Entry count = 0
  data.setUint32(offset, 0, Endian.big);

  return Uint8List.view(data.buffer);
}

/// mvex box - Movie Extends Box (for fragmented MP4)
Uint8List writeMvex({required int trackId}) {
  final trexData = writeTrex(trackId: trackId);
  final size = 8 + trexData.length;

  final builder = BoxBuilder();
  builder.add(trexData);

  final result = Uint8List(size);
  final header = writeBoxHeader(size, 'mvex');
  result.setAll(0, Uint8List.view(header.buffer));
  result.setAll(8, trexData);

  return result;
}

/// trex box - Track Extends Box
Uint8List writeTrex({required int trackId}) {
  final size = 12 + 20;
  final data = ByteData(size);
  var offset = 0;

  data.setUint32(offset, size, Endian.big);
  offset += 4;
  data.setUint8(offset++, 't'.codeUnitAt(0));
  data.setUint8(offset++, 'r'.codeUnitAt(0));
  data.setUint8(offset++, 'e'.codeUnitAt(0));
  data.setUint8(offset++, 'x'.codeUnitAt(0));

  // Version and flags
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Track ID
  data.setUint32(offset, trackId, Endian.big);
  offset += 4;

  // Default sample description index
  data.setUint32(offset, 1, Endian.big);
  offset += 4;

  // Default sample duration
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Default sample size
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Default sample flags
  data.setUint32(offset, 0, Endian.big);

  return Uint8List.view(data.buffer);
}

/// moof box - Movie Fragment Box
Uint8List writeMoof({
  required int sequenceNumber,
  required int trackId,
  required int baseMediaDecodeTime,
  required List<int> sampleSizes,
  required List<int> sampleDurations,
  required List<int> sampleFlags,
  int? defaultSampleDuration,
  int? defaultSampleSize,
  int? defaultSampleFlags,
}) {
  final mfhdData = writeMfhd(sequenceNumber: sequenceNumber);
  final trafData = writeTraf(
    trackId: trackId,
    baseMediaDecodeTime: baseMediaDecodeTime,
    sampleSizes: sampleSizes,
    sampleDurations: sampleDurations,
    sampleFlags: sampleFlags,
    defaultSampleDuration: defaultSampleDuration,
    defaultSampleSize: defaultSampleSize,
    defaultSampleFlags: defaultSampleFlags,
  );

  final size = 8 + mfhdData.length + trafData.length;
  final result = Uint8List(size);

  final header = writeBoxHeader(size, 'moof');
  result.setAll(0, Uint8List.view(header.buffer));
  result.setAll(8, mfhdData);
  result.setAll(8 + mfhdData.length, trafData);

  return result;
}

/// mfhd box - Movie Fragment Header Box
Uint8List writeMfhd({required int sequenceNumber}) {
  final size = 12 + 4;
  final data = ByteData(size);
  var offset = 0;

  data.setUint32(offset, size, Endian.big);
  offset += 4;
  data.setUint8(offset++, 'm'.codeUnitAt(0));
  data.setUint8(offset++, 'f'.codeUnitAt(0));
  data.setUint8(offset++, 'h'.codeUnitAt(0));
  data.setUint8(offset++, 'd'.codeUnitAt(0));

  // Version and flags
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Sequence number
  data.setUint32(offset, sequenceNumber, Endian.big);

  return Uint8List.view(data.buffer);
}

/// traf box - Track Fragment Box
Uint8List writeTraf({
  required int trackId,
  required int baseMediaDecodeTime,
  required List<int> sampleSizes,
  required List<int> sampleDurations,
  required List<int> sampleFlags,
  int? defaultSampleDuration,
  int? defaultSampleSize,
  int? defaultSampleFlags,
}) {
  final tfhdData = writeTfhd(
    trackId: trackId,
    defaultSampleDuration: defaultSampleDuration,
    defaultSampleSize: defaultSampleSize,
    defaultSampleFlags: defaultSampleFlags,
  );
  final tfdtData = writeTfdt(baseMediaDecodeTime: baseMediaDecodeTime);
  final trunData = writeTrun(
    sampleSizes: sampleSizes,
    sampleDurations: sampleDurations,
    sampleFlags: sampleFlags,
  );

  final size = 8 + tfhdData.length + tfdtData.length + trunData.length;
  final result = Uint8List(size);

  final header = writeBoxHeader(size, 'traf');
  var offset = 0;
  result.setAll(offset, Uint8List.view(header.buffer));
  offset += 8;
  result.setAll(offset, tfhdData);
  offset += tfhdData.length;
  result.setAll(offset, tfdtData);
  offset += tfdtData.length;
  result.setAll(offset, trunData);

  return result;
}

/// tfhd box - Track Fragment Header Box
Uint8List writeTfhd({
  required int trackId,
  int? defaultSampleDuration,
  int? defaultSampleSize,
  int? defaultSampleFlags,
}) {
  // Calculate flags
  int flags = 0x020000; // default-base-is-moof
  int extraSize = 0;

  if (defaultSampleDuration != null) {
    flags |= 0x000008;
    extraSize += 4;
  }
  if (defaultSampleSize != null) {
    flags |= 0x000010;
    extraSize += 4;
  }
  if (defaultSampleFlags != null) {
    flags |= 0x000020;
    extraSize += 4;
  }

  final size = 12 + 4 + extraSize;
  final data = ByteData(size);
  var offset = 0;

  data.setUint32(offset, size, Endian.big);
  offset += 4;
  data.setUint8(offset++, 't'.codeUnitAt(0));
  data.setUint8(offset++, 'f'.codeUnitAt(0));
  data.setUint8(offset++, 'h'.codeUnitAt(0));
  data.setUint8(offset++, 'd'.codeUnitAt(0));

  // Version 0 and flags
  data.setUint8(offset++, 0);
  data.setUint8(offset++, (flags >> 16) & 0xFF);
  data.setUint8(offset++, (flags >> 8) & 0xFF);
  data.setUint8(offset++, flags & 0xFF);

  // Track ID
  data.setUint32(offset, trackId, Endian.big);
  offset += 4;

  if (defaultSampleDuration != null) {
    data.setUint32(offset, defaultSampleDuration, Endian.big);
    offset += 4;
  }
  if (defaultSampleSize != null) {
    data.setUint32(offset, defaultSampleSize, Endian.big);
    offset += 4;
  }
  if (defaultSampleFlags != null) {
    data.setUint32(offset, defaultSampleFlags, Endian.big);
  }

  return Uint8List.view(data.buffer);
}

/// tfdt box - Track Fragment Decode Time Box
Uint8List writeTfdt({required int baseMediaDecodeTime}) {
  // Use version 1 for 64-bit time
  final size = 12 + 8;
  final data = ByteData(size);
  var offset = 0;

  data.setUint32(offset, size, Endian.big);
  offset += 4;
  data.setUint8(offset++, 't'.codeUnitAt(0));
  data.setUint8(offset++, 'f'.codeUnitAt(0));
  data.setUint8(offset++, 'd'.codeUnitAt(0));
  data.setUint8(offset++, 't'.codeUnitAt(0));

  // Version 1, flags 0
  data.setUint32(offset, 0x01000000, Endian.big);
  offset += 4;

  // Base media decode time (64-bit)
  data.setUint64(offset, baseMediaDecodeTime, Endian.big);

  return Uint8List.view(data.buffer);
}

/// trun box - Track Run Box
Uint8List writeTrun({
  required List<int> sampleSizes,
  required List<int> sampleDurations,
  required List<int> sampleFlags,
}) {
  // Flags: data-offset-present, sample-duration-present, sample-size-present, sample-flags-present
  const flags = 0x000F01; // data offset + first sample flags + sample duration + sample size + sample flags

  final sampleCount = sampleSizes.length;
  final perSampleSize = 4 + 4 + 4; // duration + size + flags
  final size = 12 + 4 + 4 + (sampleCount * perSampleSize);

  final data = ByteData(size);
  var offset = 0;

  data.setUint32(offset, size, Endian.big);
  offset += 4;
  data.setUint8(offset++, 't'.codeUnitAt(0));
  data.setUint8(offset++, 'r'.codeUnitAt(0));
  data.setUint8(offset++, 'u'.codeUnitAt(0));
  data.setUint8(offset++, 'n'.codeUnitAt(0));

  // Version 0 and flags
  data.setUint8(offset++, 0);
  data.setUint8(offset++, (flags >> 16) & 0xFF);
  data.setUint8(offset++, (flags >> 8) & 0xFF);
  data.setUint8(offset++, flags & 0xFF);

  // Sample count
  data.setUint32(offset, sampleCount, Endian.big);
  offset += 4;

  // Data offset (will be calculated after moof is complete)
  // For now, set to 0 - caller should update this
  data.setUint32(offset, 0, Endian.big);
  offset += 4;

  // Per-sample data
  for (var i = 0; i < sampleCount; i++) {
    data.setUint32(offset, sampleDurations[i], Endian.big);
    offset += 4;
    data.setUint32(offset, sampleSizes[i], Endian.big);
    offset += 4;
    data.setUint32(offset, sampleFlags[i], Endian.big);
    offset += 4;
  }

  return Uint8List.view(data.buffer);
}

/// mdat box - Media Data Box
Uint8List writeMdat(Uint8List data) {
  final size = 8 + data.length;
  final result = Uint8List(size);

  final header = writeBoxHeader(size, 'mdat');
  result.setAll(0, Uint8List.view(header.buffer));
  result.setAll(8, data);

  return result;
}

/// Sample flags for H.264
class SampleFlags {
  /// Keyframe (sync sample, depends on nothing)
  static const int keyframe = 0x02000000;

  /// Non-keyframe (non-sync sample, depends on other samples)
  static const int nonKeyframe = 0x01010000;
}
