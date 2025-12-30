part of 'moq_messages.dart';

/// Wire format utilities for MoQ protocol
///
/// Uses prefix varint encoding (not standard continuation-bit varint):
/// - 0x00-0x3F: 1 byte (6 bits of data)
/// - 0x40-0x7F: 2 bytes (14 bits of data) - prefix 01
/// - 0x80-0xBF: 4 bytes (30 bits of data) - prefix 10
/// - 0xC0-0xFF: 8 bytes (54 bits of data) - prefix 11
class MoQWireFormat {
  /// Maximum varint size (8 bytes for prefix varint)
  static const int maxVarintSize = 8;

  /// Encode a varint using prefix encoding
  static Uint8List encodeVarint(int value) {
    if (value < 0) {
      throw ArgumentError('Value must be non-negative: $value');
    }

    if (value <= 0x3F) {
      // 1 byte: 00xxxxxx
      return Uint8List.fromList([value]);
    } else if (value <= 0x3FFF) {
      // 2 bytes: 01xxxxxxxxxxxxxx
      return Uint8List.fromList([
        ((value >> 8) & 0x3F) | 0x40,
        value & 0xFF,
      ]);
    } else if (value <= 0x3FFFFFFF) {
      // 4 bytes: 10xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
      return Uint8List.fromList([
        ((value >> 24) & 0x3F) | 0x80,
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ]);
    } else if (value <= 0x3FFFFFFFFFFFFFFF) {
      // 8 bytes: 11xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
      final bytes = Uint8List(8);
      final byteData = ByteData(8)..setUint64(0, value, Endian.big);
      for (int i = 0; i < 8; i++) {
        bytes[i] = byteData.getUint8(i);
      }
      // Set top 2 bits to 11, keep remaining 6 bits of first byte
      bytes[0] = (bytes[0] & 0x3F) | 0xC0;
      return bytes;
    } else {
      throw ArgumentError('Value too large for 54-bit prefix varint: $value');
    }
  }

  /// Decode a prefix varint
  static (int value, int bytesRead) decodeVarint(Uint8List data, int offset) {
    if (offset >= data.length) {
      throw FormatException('No data to decode varint');
    }

    final prefix = data[offset] & 0xC0;

    switch (prefix) {
      case 0x00: // 1 byte
        if (offset + 1 > data.length) {
          throw FormatException('Incomplete 1-byte varint');
        }
        return (data[offset] & 0x3F, 1);

      case 0x40: // 2 bytes
        if (offset + 2 > data.length) {
          throw FormatException('Incomplete 2-byte varint');
        }
        return (
          ((data[offset] & 0x3F) << 8) | data[offset + 1],
          2,
        );

      case 0x80: // 4 bytes
        if (offset + 4 > data.length) {
          throw FormatException('Incomplete 4-byte varint');
        }
        return (
          ((data[offset] & 0x3F) << 24) |
              (data[offset + 1] << 16) |
              (data[offset + 2] << 8) |
              data[offset + 3],
          4,
        );

      case 0xC0: // 8 bytes
        if (offset + 8 > data.length) {
          throw FormatException('Incomplete 8-byte varint');
        }
        final byteData = ByteData(8);
        for (int i = 0; i < 8; i++) {
          byteData.setUint8(i, data[offset + i]);
        }
        return (
          byteData.getUint64(0, Endian.big) & 0x3FFFFFFFFFFFFFFF,
          8,
        );

      default:
        throw FormatException('Invalid varint prefix: 0x${prefix.toRadixString(16)}');
    }
  }

  /// Encode a 64-bit varint using prefix encoding
  static Uint8List encodeVarint64(Int64 value) {
    if (value < Int64(0)) {
      throw ArgumentError('Value must be non-negative: $value');
    }

    // Convert to unsigned for comparison
    final unsigned = value.toUnsigned(64);

    if (unsigned <= Int64(0x3F)) {
      // 1 byte
      return Uint8List.fromList([value.toInt()]);
    } else if (unsigned <= Int64(0x3FFF)) {
      // 2 bytes
      return Uint8List.fromList([
        ((value.toInt() >> 8) & 0x3F) | 0x40,
        value.toInt() & 0xFF,
      ]);
    } else if (unsigned <= Int64(0x3FFFFFFF)) {
      // 4 bytes
      return Uint8List.fromList([
        ((value.toInt() >> 24) & 0x3F) | 0x80,
        (value.toInt() >> 16) & 0xFF,
        (value.toInt() >> 8) & 0xFF,
        value.toInt() & 0xFF,
      ]);
    } else if (unsigned <= Int64(0x3FFFFFFFFFFFFFFF)) {
      // 8 bytes
      final bytes = Uint8List(8);
      final byteData = ByteData(8)..setUint64(0, value.toInt(), Endian.big);
      for (int i = 0; i < 8; i++) {
        bytes[i] = byteData.getUint8(i);
      }
      bytes[0] = (bytes[0] & 0x3F) | 0xC0;
      return bytes;
    } else {
      throw ArgumentError('Value too large for 54-bit prefix varint: $value');
    }
  }

  /// Decode a 64-bit prefix varint
  static (Int64 value, int bytesRead) decodeVarint64(
      Uint8List data, int offset) {
    if (offset >= data.length) {
      throw FormatException('No data to decode varint64');
    }

    final prefix = data[offset] & 0xC0;

    switch (prefix) {
      case 0x00: // 1 byte
        if (offset + 1 > data.length) {
          throw FormatException('Incomplete 1-byte varint64');
        }
        return (Int64(data[offset] & 0x3F), 1);

      case 0x40: // 2 bytes
        if (offset + 2 > data.length) {
          throw FormatException('Incomplete 2-byte varint64');
        }
        return (
          Int64(((data[offset] & 0x3F) << 8) | data[offset + 1]),
          2,
        );

      case 0x80: // 4 bytes
        if (offset + 4 > data.length) {
          throw FormatException('Incomplete 4-byte varint64');
        }
        return (
          Int64(((data[offset] & 0x3F) << 24) |
              (data[offset + 1] << 16) |
              (data[offset + 2] << 8) |
              data[offset + 3]),
          4,
        );

      case 0xC0: // 8 bytes
        if (offset + 8 > data.length) {
          throw FormatException('Incomplete 8-byte varint64');
        }
        final byteData = ByteData(8);
        for (int i = 0; i < 8; i++) {
          byteData.setUint8(i, data[offset + i]);
        }
        final unsigned = byteData.getUint64(0, Endian.big) & 0x3FFFFFFFFFFFFFFF;
        return (Int64(unsigned), 8);

      default:
        throw FormatException('Invalid varint64 prefix: 0x${prefix.toRadixString(16)}');
    }
  }

  /// Encode a tuple (array of byte arrays)
  static Uint8List encodeTuple(List<Uint8List> tuple) {
    // Calculate total size
    int totalSize = 0;
    for (final element in tuple) {
      totalSize += _varintSize(element.length) + element.length;
    }
    totalSize += _varintSize(tuple.length);

    final buffer = Uint8List(totalSize);
    int offset = 0;

    // Write count
    final countBytes = encodeVarint(tuple.length);
    buffer.setAll(offset, countBytes);
    offset += countBytes.length;

    // Write each element
    for (final element in tuple) {
      final lenBytes = encodeVarint(element.length);
      buffer.setAll(offset, lenBytes);
      offset += lenBytes.length;
      buffer.setAll(offset, element);
      offset += element.length;
    }

    return buffer;
  }

  /// Decode a tuple
  static (List<Uint8List> tuple, int bytesRead) decodeTuple(
      Uint8List data, int offset) {
    final (count, countBytes) = decodeVarint(data, offset);
    offset += countBytes;

    final tuple = <Uint8List>[];
    for (int i = 0; i < count; i++) {
      final (length, lengthBytes) = decodeVarint(data, offset);
      offset += lengthBytes;

      if (offset + length > data.length) {
        throw FormatException('Unexpected end of tuple element');
      }

      tuple.add(data.sublist(offset, offset + length));
      offset += length;
    }

    int totalBytes = countBytes;
    for (final element in tuple) {
      totalBytes += _varintSize(element.length) + element.length;
    }

    return (tuple, totalBytes);
  }

  /// Calculate prefix varint size for a given value
  static int _varintSize(int value) {
    if (value < 0) return maxVarintSize;
    if (value <= 0x3F) return 1;
    if (value <= 0x3FFF) return 2;
    if (value <= 0x3FFFFFFF) return 4;
    if (value <= 0x3FFFFFFFFFFFFFFF) return 8;
    return maxVarintSize;
  }

  /// Calculate prefix varint size for a 64-bit value
  static int _varintSize64(Int64 value) {
    if (value < Int64(0)) return maxVarintSize;
    final unsigned = value.toUnsigned(64);
    if (unsigned <= Int64(0x3F)) return 1;
    if (unsigned <= Int64(0x3FFF)) return 2;
    if (unsigned <= Int64(0x3FFFFFFF)) return 4;
    if (unsigned <= Int64(0x3FFFFFFFFFFFFFFF)) return 8;
    return maxVarintSize;
  }

  /// Encode a Location structure
  static Uint8List encodeLocation(Location location) {
    final groupBytes = encodeVarint64(location.group);
    final objectBytes = encodeVarint64(location.object);

    final buffer = Uint8List(groupBytes.length + objectBytes.length);
    int offset = 0;
    buffer.setAll(offset, groupBytes);
    offset += groupBytes.length;
    buffer.setAll(offset, objectBytes);

    return buffer;
  }

  /// Decode a Location structure
  static (Location location, int bytesRead) decodeLocation(
      Uint8List data, int offset) {
    final (group, groupBytes) = decodeVarint64(data, offset);
    offset += groupBytes;
    final (object, objectBytes) = decodeVarint64(data, offset);

    return (Location(group: group, object: object),
        groupBytes + objectBytes);
  }

  /// Calculate the size of a tuple when encoded
  static int _tupleSize(List<Uint8List> tuple) {
    int size = _varintSize(tuple.length);
    for (final element in tuple) {
      size += _varintSize(element.length) + element.length;
    }
    return size;
  }
}

/// Control message parser
class MoQControlMessageParser {
  /// Parse a control message from bytes
  ///
  /// Returns (message, totalBytesRead) where totalBytesRead includes
  /// the message type, length, and payload
  static (MoQControlMessage? message, int bytesRead) parse(Uint8List data) {
    if (data.isEmpty) {
      return (null, 0);
    }

    int offset = 0;

    // Read message type (varint - prefix encoded)
    final (type, typeBytes) = MoQWireFormat.decodeVarint(data, offset);
    offset += typeBytes;

    // Read message length (16-bit big endian)
    if (offset + 2 > data.length) {
      throw FormatException('Unexpected end of message length');
    }
    final length = (data[offset] << 8) | data[offset + 1];
    offset += 2;

    // Check we have enough data
    if (offset + length > data.length) {
      throw FormatException('Incomplete message: need $length bytes, have ${data.length - offset}');
    }

    // Extract payload
    final payload = data.sublist(offset, offset + length);
    final totalBytesRead = offset + length;

    // Parse based on message type
    final messageType = MoQMessageType.fromValue(type);
    if (messageType == null) {
      return (null, totalBytesRead);
    }

    MoQControlMessage? message;
    try {
      message = _parseMessage(messageType, payload);
    } catch (e) {
      // Return null for unparseable messages
      return (null, totalBytesRead);
    }

    return (message, totalBytesRead);
  }

  static MoQControlMessage? _parseMessage(MoQMessageType type, Uint8List payload) {
    switch (type) {
      case MoQMessageType.clientSetup:
        return ClientSetupMessage.deserialize(payload);
      case MoQMessageType.serverSetup:
        return ServerSetupMessage.deserialize(payload);
      case MoQMessageType.subscribe:
        return SubscribeMessage.deserialize(payload);
      case MoQMessageType.subscribeOk:
        return SubscribeOkMessage.deserialize(payload);
      case MoQMessageType.subscribeError:
        return SubscribeErrorMessage.deserialize(payload);
      case MoQMessageType.subscribeUpdate:
        return SubscribeUpdateMessage.deserialize(payload);
      case MoQMessageType.unsubscribe:
        return UnsubscribeMessage.deserialize(payload);
      case MoQMessageType.goaway:
        return GoawayMessage.deserialize(payload);
      case MoQMessageType.publishDone:
        return PublishDoneMessage.deserialize(payload);
      case MoQMessageType.fetch:
        return FetchMessage.deserialize(payload);
      case MoQMessageType.fetchOk:
        return FetchOkMessage.deserialize(payload);
      case MoQMessageType.fetchError:
        return FetchErrorMessage.deserialize(payload);
      case MoQMessageType.fetchCancel:
        return FetchCancelMessage.deserialize(payload);
      case MoQMessageType.publish:
        return PublishMessage.deserialize(payload);
      case MoQMessageType.publishOk:
        return PublishOkMessage.deserialize(payload);
      case MoQMessageType.publishError:
        return PublishErrorMessage.deserialize(payload);
      case MoQMessageType.maxRequestId:
        return MaxRequestIdMessage.deserialize(payload);
      case MoQMessageType.requestsBlocked:
        return RequestsBlockedMessage.deserialize(payload);
      case MoQMessageType.trackStatus:
        return TrackStatusMessage.deserialize(payload);
      case MoQMessageType.trackStatusOk:
        return TrackStatusOkMessage.deserialize(payload);
      case MoQMessageType.trackStatusError:
        return TrackStatusErrorMessage.deserialize(payload);
      case MoQMessageType.publishNamespace:
        return PublishNamespaceMessage.deserialize(payload);
      case MoQMessageType.publishNamespaceOk:
        return PublishNamespaceOkMessage.deserialize(payload);
      case MoQMessageType.publishNamespaceError:
        return PublishNamespaceErrorMessage.deserialize(payload);
      case MoQMessageType.publishNamespaceDone:
        return PublishNamespaceDoneMessage.deserialize(payload);
      case MoQMessageType.publishNamespaceCancel:
        return PublishNamespaceCancelMessage.deserialize(payload);
      case MoQMessageType.subscribeNamespace:
        return SubscribeNamespaceMessage.deserialize(payload);
      case MoQMessageType.subscribeNamespaceOk:
        return SubscribeNamespaceOkMessage.deserialize(payload);
      case MoQMessageType.subscribeNamespaceError:
        return SubscribeNamespaceErrorMessage.deserialize(payload);
      case MoQMessageType.unsubscribeNamespace:
        return UnsubscribeNamespaceMessage.deserialize(payload);
      default:
        // Unknown or unimplemented message type
        return null;
    }
  }
}
