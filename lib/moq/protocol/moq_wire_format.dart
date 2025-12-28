part of 'moq_messages.dart';

/// Wire format utilities for MoQ protocol
class MoQWireFormat {
  /// Maximum varint size (64-bit)
  static const int maxVarintSize = 10;

  /// Encode a varint
  static Uint8List encodeVarint(int value) {
    final buffer = Uint8List(maxVarintSize);
    int offset = 0;
    int v = value;

    do {
      int byte = v & 0x7F;
      v >>= 7;
      if (v > 0) {
        byte |= 0x80;
      }
      buffer[offset++] = byte;
    } while (v > 0);

    return buffer.sublist(0, offset);
  }

  /// Decode a varint
  static (int value, int bytesRead) decodeVarint(Uint8List data, int offset) {
    int value = 0;
    int shift = 0;
    int bytesRead = 0;

    do {
      if (offset + bytesRead >= data.length) {
        throw FormatException('Unexpected end of varint');
      }
      int b = data[offset + bytesRead];
      value |= (b & 0x7F) << shift;
      shift += 7;
      bytesRead++;

      if (bytesRead > maxVarintSize) {
        throw FormatException('Varint too long');
      }
    } while ((data[offset + bytesRead - 1] & 0x80) != 0);

    return (value, bytesRead);
  }

  /// Encode a 64-bit varint
  static Uint8List encodeVarint64(Int64 value) {
    final buffer = Uint8List(maxVarintSize);
    int offset = 0;
    Int64 v = value;

    do {
      int byte = (v.toInt()) & 0x7F;
      v = v >> 7;
      if (v > Int64(0)) {
        byte |= 0x80;
      }
      buffer[offset++] = byte;
    } while (v > Int64(0));

    return buffer.sublist(0, offset);
  }

  /// Decode a 64-bit varint
  static (Int64 value, int bytesRead) decodeVarint64(
      Uint8List data, int offset) {
    int value = 0;
    int shift = 0;
    int bytesRead = 0;

    do {
      if (offset + bytesRead >= data.length) {
        throw FormatException('Unexpected end of varint64');
      }
      int b = data[offset + bytesRead];
      value |= (b & 0x7F) << shift;
      shift += 7;
      bytesRead++;

      if (bytesRead > maxVarintSize) {
        throw FormatException('Varint64 too long');
      }
    } while ((data[offset + bytesRead - 1] & 0x80) != 0);

    return (Int64(value), bytesRead);
  }

  /// Encode a tuple (array of byte arrays)
  static Uint8List encodeTuple(List<Uint8List> tuple) {
    // Count: varint + each element: varint length + data
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

  /// Calculate varint size
  static int _varintSize(int value) {
    if (value < 0) return maxVarintSize;
    int size = 1;
    while (value >= 0x80) {
      value >>= 7;
      size++;
    }
    return size;
  }

  /// Calculate 64-bit varint size
  static int _varintSize64(Int64 value) {
    // For 64-bit, we need to check the actual value
    if (value < Int64(0)) return maxVarintSize;
    int v = value.toInt();
    int size = 1;
    while (v >= 0x80) {
      v >>= 7;
      size++;
    }
    return size;
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

    // Read message type (varint)
    final (type, typeBytes) = MoQWireFormat.decodeVarint(data, offset);
    offset += typeBytes;

    // Read message length (16-bit)
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
      default:
        // Unknown or unimplemented message type
        return null;
    }
  }
}
