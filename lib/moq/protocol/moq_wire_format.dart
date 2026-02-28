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

  /// Encode Key-Value-Pairs to bytes.
  ///
  /// When [useDelta] is true (draft-16+), params are sorted by type ascending
  /// and the type field is encoded as the delta from the previous type.
  static Uint8List encodeKeyValuePairs(List<KeyValuePair> params,
      {bool useDelta = false}) {
    final sorted = useDelta
        ? (List<KeyValuePair>.from(params)
          ..sort((a, b) => a.type.compareTo(b.type)))
        : params;

    // Calculate total size
    int totalSize = _varintSize(sorted.length);
    int lastType = 0;
    for (final param in sorted) {
      final typeToWrite = useDelta ? (param.type - lastType) : param.type;
      totalSize += _varintSize(typeToWrite);
      if (param.isVarintType) {
        totalSize += _varintSize(param.intValue ?? 0);
      } else if (param.value != null) {
        totalSize +=
            _varintSize(param.value!.length) + param.value!.length;
      } else {
        totalSize += _varintSize(0);
      }
      if (useDelta) lastType = param.type;
    }

    final buffer = Uint8List(totalSize);
    int offset = 0;
    lastType = 0;

    // Write count
    final countBytes = encodeVarint(sorted.length);
    buffer.setAll(offset, countBytes);
    offset += countBytes.length;

    // Write each param
    for (final param in sorted) {
      final typeToWrite = useDelta ? (param.type - lastType) : param.type;
      final typeBytes = encodeVarint(typeToWrite);
      buffer.setAll(offset, typeBytes);
      offset += typeBytes.length;

      if (param.isVarintType) {
        final valBytes = encodeVarint(param.intValue ?? 0);
        buffer.setAll(offset, valBytes);
        offset += valBytes.length;
      } else if (param.value != null) {
        final lenBytes = encodeVarint(param.value!.length);
        buffer.setAll(offset, lenBytes);
        offset += lenBytes.length;
        buffer.setAll(offset, param.value!);
        offset += param.value!.length;
      } else {
        final lenBytes = encodeVarint(0);
        buffer.setAll(offset, lenBytes);
        offset += lenBytes.length;
      }
      if (useDelta) lastType = param.type;
    }

    return buffer;
  }

  /// Decode Key-Value-Pairs from bytes.
  ///
  /// When [useDelta] is true (draft-16+), type fields are delta-encoded
  /// from the previous type; this method reconstructs absolute types.
  /// Returns (params, bytesRead) starting from [offset] in [data].
  /// [count] is the number of params to read (already decoded by caller).
  static (List<KeyValuePair> params, int bytesRead) decodeKeyValuePairs(
      Uint8List data, int offset, int count,
      {bool useDelta = false}) {
    final startOffset = offset;
    final params = <KeyValuePair>[];
    int lastType = 0;

    for (int i = 0; i < count; i++) {
      final (rawType, typeLen) = decodeVarint(data, offset);
      offset += typeLen;

      final absoluteType = useDelta ? (lastType + rawType) : rawType;

      if (absoluteType % 2 == 0) {
        // Even types: value is direct varint
        final (intValue, intLen) = decodeVarint(data, offset);
        offset += intLen;
        params.add(KeyValuePair(type: absoluteType, intValue: intValue));
      } else {
        // Odd types: value is length-prefixed buffer
        Uint8List? value;
        final (length, lengthLen) = decodeVarint(data, offset);
        offset += lengthLen;
        if (length > 0 && offset + length <= data.length) {
          value = data.sublist(offset, offset + length);
          offset += length;
        }
        params.add(KeyValuePair(type: absoluteType, value: value));
      }
      if (useDelta) lastType = absoluteType;
    }

    return (params, offset - startOffset);
  }
}

/// Control message parser
class MoQControlMessageParser {
  /// Enable debug logging for message parsing
  static bool enableDebugLogging = false;

  /// Parse a control message from bytes
  ///
  /// Returns (message, totalBytesRead) where totalBytesRead includes
  /// the message type, length, and payload
  static (MoQControlMessage? message, int bytesRead) parse(Uint8List data,
      {int version = MoQVersion.draft14}) {
    if (data.isEmpty) {
      return (null, 0);
    }

    int offset = 0;

    // Read message type (varint - prefix encoded)
    final (type, typeBytes) = MoQWireFormat.decodeVarint(data, offset);
    offset += typeBytes;

    if (enableDebugLogging) {
      print('[MoQParser] Raw data: ${data.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ')}');
      print('[MoQParser] Type value: 0x${type.toRadixString(16)} ($type), bytes: $typeBytes');
    }

    // Read message length (16-bit big endian)
    if (offset + 2 > data.length) {
      throw FormatException('Unexpected end of message length');
    }
    final length = (data[offset] << 8) | data[offset + 1];
    offset += 2;

    if (enableDebugLogging) {
      print('[MoQParser] Length: $length');
    }

    // Check we have enough data
    if (offset + length > data.length) {
      throw FormatException('Incomplete message: need $length bytes, have ${data.length - offset}');
    }

    // Extract payload
    final payload = data.sublist(offset, offset + length);
    final totalBytesRead = offset + length;

    // Parse based on message type (version-aware for type-code collisions)
    final messageType = MoQMessageType.fromValue(type, version: version);
    if (enableDebugLogging) {
      print('[MoQParser] MessageType enum: $messageType');
      print('[MoQParser] Payload: ${payload.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ')}');
    }

    if (messageType == null) {
      return (null, totalBytesRead);
    }

    MoQControlMessage? message;
    try {
      message = _parseMessage(messageType, payload, version: version);
      if (enableDebugLogging) {
        print('[MoQParser] Parsed message: ${message?.type}');
      }
    } catch (e, stack) {
      // Log parsing errors for debugging
      if (enableDebugLogging) {
        print('[MoQParser] Failed to parse $messageType: $e');
        print('[MoQParser] Stack: $stack');
      }
      return (null, totalBytesRead);
    }

    return (message, totalBytesRead);
  }

  static MoQControlMessage? _parseMessage(MoQMessageType type, Uint8List payload,
      {int version = MoQVersion.draft14}) {
    switch (type) {
      case MoQMessageType.clientSetup:
        return ClientSetupMessage.deserialize(payload, version: version);
      case MoQMessageType.serverSetup:
        return ServerSetupMessage.deserialize(payload, version: version);
      case MoQMessageType.subscribe:
        return SubscribeMessage.deserialize(payload, version: version);
      case MoQMessageType.subscribeOk:
        return SubscribeOkMessage.deserialize(payload, version: version);
      case MoQMessageType.subscribeError:
        return SubscribeErrorMessage.deserialize(payload, version: version);
      case MoQMessageType.subscribeUpdate:
        return SubscribeUpdateMessage.deserialize(payload, version: version);
      case MoQMessageType.unsubscribe:
        return UnsubscribeMessage.deserialize(payload, version: version);
      case MoQMessageType.goaway:
        return GoawayMessage.deserialize(payload, version: version);
      case MoQMessageType.publishDone:
        return PublishDoneMessage.deserialize(payload, version: version);
      case MoQMessageType.fetch:
        return FetchMessage.deserialize(payload, version: version);
      case MoQMessageType.fetchOk:
        return FetchOkMessage.deserialize(payload, version: version);
      case MoQMessageType.fetchError:
        return FetchErrorMessage.deserialize(payload, version: version);
      case MoQMessageType.fetchCancel:
        return FetchCancelMessage.deserialize(payload, version: version);
      case MoQMessageType.publish:
        return PublishMessage.deserialize(payload, version: version);
      case MoQMessageType.publishOk:
        return PublishOkMessage.deserialize(payload, version: version);
      case MoQMessageType.publishError:
        return PublishErrorMessage.deserialize(payload, version: version);
      case MoQMessageType.maxRequestId:
        return MaxRequestIdMessage.deserialize(payload, version: version);
      case MoQMessageType.requestsBlocked:
        return RequestsBlockedMessage.deserialize(payload, version: version);
      case MoQMessageType.trackStatus:
        return TrackStatusMessage.deserialize(payload, version: version);
      case MoQMessageType.trackStatusOk:
        return TrackStatusOkMessage.deserialize(payload, version: version);
      case MoQMessageType.trackStatusError:
        return TrackStatusErrorMessage.deserialize(payload, version: version);
      case MoQMessageType.publishNamespace:
        return PublishNamespaceMessage.deserialize(payload, version: version);
      case MoQMessageType.publishNamespaceOk:
        return PublishNamespaceOkMessage.deserialize(payload, version: version);
      case MoQMessageType.publishNamespaceError:
        return PublishNamespaceErrorMessage.deserialize(payload, version: version);
      case MoQMessageType.publishNamespaceDone:
        return PublishNamespaceDoneMessage.deserialize(payload, version: version);
      case MoQMessageType.publishNamespaceCancel:
        return PublishNamespaceCancelMessage.deserialize(payload, version: version);
      case MoQMessageType.subscribeNamespace:
        return SubscribeNamespaceMessage.deserialize(payload, version: version);
      case MoQMessageType.subscribeNamespaceOk:
        return SubscribeNamespaceOkMessage.deserialize(payload, version: version);
      case MoQMessageType.subscribeNamespaceError:
        return SubscribeNamespaceErrorMessage.deserialize(payload, version: version);
      case MoQMessageType.unsubscribeNamespace:
        return UnsubscribeNamespaceMessage.deserialize(payload, version: version);
      // Draft-16 new messages
      case MoQMessageType.requestOk:
        return RequestOkMessage.deserialize(payload, version: version);
      case MoQMessageType.requestError:
        return RequestErrorMessage.deserialize(payload, version: version);
      case MoQMessageType.namespace_:
        return NamespaceMessage.deserialize(payload, version: version);
      case MoQMessageType.namespaceDone:
        return NamespaceDoneMessage.deserialize(payload, version: version);
      default:
        // Unknown or unimplemented message type
        return null;
    }
  }
}
