part of 'moq_messages.dart';

/// Object Datagram - carries a single object in a datagram
///
/// Draft-14 wire format (types 0x00-0x07, 0x20-0x27):
/// OBJECT_DATAGRAM Message {
///   Type (i) = Object Datagram Type,
///   Track Alias (i),
///   [Group ID (i),]
///   [Object ID (i),]
///   Publisher Priority (8),
///   [Number of Extension Headers (i),
///   Extension Headers (..) ...,]
///   [Object Status (8),]
///   [Object Payload Length (i),
///   Object Payload (..)]
/// }
///
/// Draft-16 wire format (types 0x00-0x0F, 0x20-0x2D):
/// OBJECT_DATAGRAM Message {
///   Type (i) = 0x00..0x0F / 0x20..0x21 / 0x24..0x25 /
///              0x28..0x29 / 0x2C..0x2D,
///   Track Alias (i),
///   Group ID (i),
///   [Object ID (i),]
///   [Publisher Priority (8),]
///   [Extensions (..),]
///   [Object Status (i),]
///   [Object Payload (..),]
/// }
///
/// Draft-16 type bitfield (0b00X0XXXX):
///   Bit 0 (0x01): EXTENSIONS present
///   Bit 1 (0x02): END_OF_GROUP
///   Bit 2 (0x04): ZERO_OBJECT_ID (Object ID omitted, implied 0)
///   Bit 3 (0x08): DEFAULT_PRIORITY (Publisher Priority omitted)
///   Bit 5 (0x20): STATUS (Object Status present instead of payload)
class ObjectDatagram {
  final Int64 trackAlias;
  final Int64 groupId;
  final Int64? objectId;
  final int publisherPriority;
  final List<KeyValuePair> extensionHeaders;
  final ObjectStatus? status;
  final Uint8List? payload;
  /// Draft-16: when true, Publisher Priority byte is omitted and
  /// inherited from the subscription's control message.
  final bool useDefaultPriority;

  ObjectDatagram({
    required this.trackAlias,
    required this.groupId,
    this.objectId,
    required this.publisherPriority,
    this.extensionHeaders = const [],
    this.status,
    this.payload,
    this.useDefaultPriority = false,
  });

  /// Get the message type for draft-14 based on status
  int get messageType {
    if (status == null) return 0x00; // OBJECT_DATAGRAM_NORMAL
    switch (status!) {
      case ObjectStatus.normal:
        return 0x00;
      case ObjectStatus.doesNotExist:
        return 0x01;
      case ObjectStatus.endOfGroup:
        return 0x03;
      case ObjectStatus.endOfTrack:
        return 0x04;
      case ObjectStatus.endOfSubgroup:
        return 0x05;
    }
  }

  /// Compute the message type for a given version.
  ///
  /// Draft-14: type encodes status directly.
  /// Draft-16: type is a bitfield (0b00X0XXXX):
  ///   Bit 0 (0x01): EXTENSIONS present
  ///   Bit 1 (0x02): END_OF_GROUP
  ///   Bit 2 (0x04): ZERO_OBJECT_ID
  ///   Bit 3 (0x08): DEFAULT_PRIORITY
  ///   Bit 5 (0x20): STATUS (status present instead of payload)
  int _messageType(int version) {
    if (!MoQVersion.isDraft16OrLater(version)) {
      return messageType;
    }
    int type = 0;
    // Bit 0: EXTENSIONS
    if (extensionHeaders.isNotEmpty) {
      type |= 0x01;
    }
    // Bit 1: END_OF_GROUP
    if (status == ObjectStatus.endOfGroup) {
      type |= 0x02;
    }
    // Bit 2: ZERO_OBJECT_ID
    if (objectId == null || objectId == Int64(0)) {
      type |= 0x04;
    }
    // Bit 3: DEFAULT_PRIORITY
    if (useDefaultPriority) {
      type |= 0x08;
    }
    // Bit 5: STATUS (status present instead of payload)
    if (status != null && status != ObjectStatus.normal) {
      type |= 0x20;
    }
    return type;
  }

  /// Serialize the object datagram
  Uint8List serialize({int version = MoQVersion.draft14}) {
    if (MoQVersion.isDraft16OrLater(version)) {
      return _serializeDraft16();
    }
    return _serializeDraft14();
  }

  /// Draft-14 serialization (original behavior)
  Uint8List _serializeDraft14() {
    int len = 0;
    // Type (object datagram type is in first varint byte)
    len += MoQWireFormat._varintSize(messageType);
    // Track Alias
    len += MoQWireFormat._varintSize64(trackAlias);
    // Group ID (always present)
    len += MoQWireFormat._varintSize64(groupId);
    // Object ID (conditional - if objectId is null, it's inferred)
    if (objectId != null) {
      len += MoQWireFormat._varintSize64(objectId!);
    }
    // Publisher Priority
    len += 1;
    // Extension Headers
    len += MoQWireFormat._varintSize(extensionHeaders.length);
    for (final param in extensionHeaders) {
      len += MoQWireFormat._varintSize(param.type);
      if (param.value != null) {
        // Even types have varint value, odd types have length-prefixed buffer
        if (param.type % 2 == 0) {
          // Even type: value is a single varint (stored as first byte of value array)
          len += MoQWireFormat._varintSize(param.value![0]);
        } else {
          // Odd type: length-prefixed buffer
          len += MoQWireFormat._varintSize(param.value!.length) + param.value!.length;
        }
      }
    }
    // Status (conditional - omit if normal)
    if (status != null && status != ObjectStatus.normal) {
      len += 1;
    }
    // Payload (conditional)
    if (payload != null && isNormal) {
      len += MoQWireFormat._varintSize(payload!.length) + payload!.length;
    }

    final buffer = Uint8List(len);
    int offset = 0;

    // Type
    offset += _writeVarint(buffer, offset, messageType);

    // Track Alias
    offset += _writeVarint64(buffer, offset, trackAlias);

    // Group ID
    offset += _writeVarint64(buffer, offset, groupId);

    // Object ID
    if (objectId != null) {
      offset += _writeVarint64(buffer, offset, objectId!);
    }

    // Publisher Priority
    buffer[offset++] = publisherPriority;

    // Extension Headers
    offset += _writeVarint(buffer, offset, extensionHeaders.length);
    for (final param in extensionHeaders) {
      offset += _writeVarint(buffer, offset, param.type);
      if (param.value != null) {
        // Even types have varint value, odd types have length-prefixed buffer
        if (param.type % 2 == 0) {
          // Even type: value is a single varint
          offset += _writeVarint(buffer, offset, param.value![0]);
        } else {
          // Odd type: length-prefixed buffer
          offset += _writeVarint(buffer, offset, param.value!.length);
          buffer.setAll(offset, param.value!);
          offset += param.value!.length;
        }
      }
    }

    // Status
    if (status != null && status != ObjectStatus.normal) {
      buffer[offset++] = status!.value;
    }

    // Payload
    if (payload != null && isNormal) {
      offset += _writeVarint(buffer, offset, payload!.length);
      buffer.setAll(offset, payload!);
    }

    return buffer;
  }

  /// Draft-16 serialization with expanded bitfield type
  Uint8List _serializeDraft16() {
    final type = _messageType(MoQVersion.draft16);
    final hasExtensions = (type & 0x01) != 0;
    final zeroObjectId = (type & 0x04) != 0;
    final defaultPriority = (type & 0x08) != 0;
    final hasStatus = (type & 0x20) != 0;

    // Build extensions block first so we know its size
    Uint8List? extensionsBlock;
    if (hasExtensions) {
      extensionsBlock = _buildExtensionsBlock();
    }

    int len = 0;
    // Type
    len += MoQWireFormat._varintSize(type);
    // Track Alias
    len += MoQWireFormat._varintSize64(trackAlias);
    // Group ID (always present)
    len += MoQWireFormat._varintSize64(groupId);
    // Object ID (omitted when ZERO_OBJECT_ID bit set)
    if (!zeroObjectId && objectId != null) {
      len += MoQWireFormat._varintSize64(objectId!);
    }
    // Publisher Priority (omitted when DEFAULT_PRIORITY bit set)
    if (!defaultPriority) {
      len += 1;
    }
    // Extensions block (Extension Headers Length + Extension Headers)
    if (extensionsBlock != null) {
      len += extensionsBlock.length;
    }
    // Object Status (varint, when STATUS bit set)
    if (hasStatus && status != null) {
      len += MoQWireFormat._varintSize(status!.value);
    }
    // Object Payload (rest of datagram, no explicit length field)
    if (!hasStatus && payload != null) {
      len += payload!.length;
    }

    final buffer = Uint8List(len);
    int offset = 0;

    // Type
    offset += _writeVarint(buffer, offset, type);

    // Track Alias
    offset += _writeVarint64(buffer, offset, trackAlias);

    // Group ID
    offset += _writeVarint64(buffer, offset, groupId);

    // Object ID (omitted when ZERO_OBJECT_ID bit set)
    if (!zeroObjectId && objectId != null) {
      offset += _writeVarint64(buffer, offset, objectId!);
    }

    // Publisher Priority (omitted when DEFAULT_PRIORITY bit set)
    if (!defaultPriority) {
      buffer[offset++] = publisherPriority;
    }

    // Extensions block
    if (extensionsBlock != null) {
      buffer.setAll(offset, extensionsBlock);
      offset += extensionsBlock.length;
    }

    // Object Status (varint)
    if (hasStatus && status != null) {
      offset += _writeVarint(buffer, offset, status!.value);
    }

    // Object Payload (no explicit length - rest of datagram is payload)
    if (!hasStatus && payload != null) {
      buffer.setAll(offset, payload!);
      offset += payload!.length;
    }

    return buffer;
  }

  /// Build the Extensions block for draft-16:
  /// Extension Headers Length (i) + Extension Headers (..)
  /// where headers use delta-encoded Key-Value-Pairs.
  Uint8List _buildExtensionsBlock() {
    // Sort headers by type ascending for delta encoding
    final sorted = List<KeyValuePair>.from(extensionHeaders)
      ..sort((a, b) => a.type.compareTo(b.type));

    // Calculate size of KVP payload (delta-encoded, no count prefix)
    int kvpSize = 0;
    int lastType = 0;
    for (final param in sorted) {
      final delta = param.type - lastType;
      kvpSize += MoQWireFormat._varintSize(delta);
      if (param.isVarintType) {
        kvpSize += MoQWireFormat._varintSize(param.intValue ?? 0);
      } else if (param.value != null) {
        kvpSize +=
            MoQWireFormat._varintSize(param.value!.length) +
            param.value!.length;
      } else {
        kvpSize += MoQWireFormat._varintSize(0);
      }
      lastType = param.type;
    }

    // Total block = Extension Headers Length (varint) + KVP bytes
    final totalSize = MoQWireFormat._varintSize(kvpSize) + kvpSize;
    final buffer = Uint8List(totalSize);
    int offset = 0;

    // Write Extension Headers Length
    final lenBytes = MoQWireFormat.encodeVarint(kvpSize);
    buffer.setAll(offset, lenBytes);
    offset += lenBytes.length;

    // Write delta-encoded KVPs
    lastType = 0;
    for (final param in sorted) {
      final delta = param.type - lastType;
      final deltaBytes = MoQWireFormat.encodeVarint(delta);
      buffer.setAll(offset, deltaBytes);
      offset += deltaBytes.length;

      if (param.isVarintType) {
        final valBytes = MoQWireFormat.encodeVarint(param.intValue ?? 0);
        buffer.setAll(offset, valBytes);
        offset += valBytes.length;
      } else if (param.value != null) {
        final valLenBytes = MoQWireFormat.encodeVarint(param.value!.length);
        buffer.setAll(offset, valLenBytes);
        offset += valLenBytes.length;
        buffer.setAll(offset, param.value!);
        offset += param.value!.length;
      } else {
        final zeroBytes = MoQWireFormat.encodeVarint(0);
        buffer.setAll(offset, zeroBytes);
        offset += zeroBytes.length;
      }
      lastType = param.type;
    }

    return buffer;
  }

  int _writeVarint(Uint8List buffer, int offset, int value) {
    final bytes = MoQWireFormat.encodeVarint(value);
    buffer.setAll(offset, bytes);
    return bytes.length;
  }

  int _writeVarint64(Uint8List buffer, int offset, Int64 value) {
    final bytes = MoQWireFormat.encodeVarint64(value);
    buffer.setAll(offset, bytes);
    return bytes.length;
  }

  /// Deserialize an object datagram from bytes
  static ObjectDatagram deserialize(Uint8List data,
      {int version = MoQVersion.draft14}) {
    if (MoQVersion.isDraft16OrLater(version)) {
      return _deserializeDraft16(data);
    }
    return _deserializeDraft14(data);
  }

  /// Draft-14 deserialization (original behavior)
  static ObjectDatagram _deserializeDraft14(Uint8List data) {
    int offset = 0;

    // Read type
    final (type, typeLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += typeLen;

    // Read Track Alias
    final (trackAlias, aliasLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += aliasLen;

    // Read Group ID (always present in datagram)
    final (groupId, groupLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += groupLen;

    // Object ID is conditional - check based on position
    Int64? objectId;
    if (offset < data.length) {
      final (oid, oidLen) = MoQWireFormat.decodeVarint64(data, offset);
      offset += oidLen;
      objectId = oid;
    }

    // Publisher Priority
    final publisherPriority = data[offset++];

    // Extension Headers
    final (numHeaders, headersLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += headersLen;

    final headers = <KeyValuePair>[];
    for (int i = 0; i < numHeaders; i++) {
      final (headerType, typeLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += typeLen;

      Uint8List? value;
      if (offset < data.length) {
        // Even types have varint value, odd types have length-prefixed buffer
        if (headerType % 2 == 0) {
          // Even type: value is a single varint
          final (varintValue, varintLen) = MoQWireFormat.decodeVarint(data, offset);
          offset += varintLen;
          // Store varint as single-byte array for consistency
          value = Uint8List.fromList([varintValue & 0xFF]);
        } else {
          // Odd type: value is length-prefixed buffer
          final (length, lengthLen) = MoQWireFormat.decodeVarint(data, offset);
          offset += lengthLen;
          if (length > 0 && offset + length <= data.length) {
            value = data.sublist(offset, offset + length);
            offset += length;
          }
        }
      }
      headers.add(KeyValuePair(type: headerType, value: value));
    }

    // Status (conditional)
    ObjectStatus? status;
    Uint8List? payload;

    if (offset < data.length) {
      // Check if remaining bytes look like a status or payload
      final nextByte = data[offset];

      // If next byte is a valid status value and remaining data is small, it's a status
      if (nextByte <= 0x04 && (data.length - offset) <= 2) {
        status = ObjectStatus.fromValue(data[offset++]);
      } else {
        // It's a payload
        final (payloadLen, payloadLenLen) = MoQWireFormat.decodeVarint(data, offset);
        offset += payloadLenLen;
        if (payloadLen > 0 && offset + payloadLen <= data.length) {
          payload = data.sublist(offset, offset + payloadLen);
        }
        status = ObjectStatus.normal;
      }
    }

    return ObjectDatagram(
      trackAlias: trackAlias,
      groupId: groupId,
      objectId: objectId,
      publisherPriority: publisherPriority,
      extensionHeaders: headers,
      status: status ?? ObjectStatus.normal,
      payload: payload,
    );
  }

  /// Draft-16 deserialization with expanded bitfield type
  static ObjectDatagram _deserializeDraft16(Uint8List data) {
    int offset = 0;

    // Read type (bitfield)
    final (type, typeLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += typeLen;

    // Decode bitfield flags
    final hasExtensions = (type & 0x01) != 0;
    final endOfGroup = (type & 0x02) != 0;
    final zeroObjectId = (type & 0x04) != 0;
    final defaultPriority = (type & 0x08) != 0;
    final hasStatus = (type & 0x20) != 0;

    // Read Track Alias
    final (trackAlias, aliasLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += aliasLen;

    // Read Group ID (always present in datagram)
    final (groupId, groupLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += groupLen;

    // Object ID: omitted when ZERO_OBJECT_ID bit set (implied 0)
    Int64? objectId;
    if (zeroObjectId) {
      objectId = Int64(0);
    } else {
      final (oid, oidLen) = MoQWireFormat.decodeVarint64(data, offset);
      offset += oidLen;
      objectId = oid;
    }

    // Publisher Priority: omitted when DEFAULT_PRIORITY bit set
    int publisherPriority = 0;
    if (!defaultPriority) {
      publisherPriority = data[offset++];
    }

    // Extensions: Extension Headers Length (i) + delta-encoded KVPs
    final headers = <KeyValuePair>[];
    if (hasExtensions) {
      // Read Extension Headers Length (total byte length of KVP block)
      final (extLen, extLenLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += extLenLen;

      if (extLen > 0) {
        final extEnd = offset + extLen;
        int lastType = 0;
        while (offset < extEnd) {
          // Read delta-encoded type
          final (delta, deltaLen) = MoQWireFormat.decodeVarint(data, offset);
          offset += deltaLen;
          final absoluteType = lastType + delta;

          if (absoluteType % 2 == 0) {
            // Even type: value is a direct varint
            final (intValue, intLen) =
                MoQWireFormat.decodeVarint(data, offset);
            offset += intLen;
            headers
                .add(KeyValuePair(type: absoluteType, intValue: intValue));
          } else {
            // Odd type: value is length-prefixed buffer
            final (length, lengthLen) =
                MoQWireFormat.decodeVarint(data, offset);
            offset += lengthLen;
            Uint8List? value;
            if (length > 0 && offset + length <= data.length) {
              value = data.sublist(offset, offset + length);
              offset += length;
            }
            headers.add(KeyValuePair(type: absoluteType, value: value));
          }
          lastType = absoluteType;
        }
      }
    }

    // Status or Payload based on STATUS bit
    ObjectStatus? status;
    Uint8List? payload;

    if (hasStatus) {
      // STATUS bit set: read Object Status as varint
      if (offset < data.length) {
        final (statusVal, statusLen) =
            MoQWireFormat.decodeVarint(data, offset);
        offset += statusLen;
        status = ObjectStatus.fromValue(statusVal);
      }
    } else {
      // No STATUS bit: remaining bytes are Object Payload (no explicit length)
      if (offset < data.length) {
        payload = data.sublist(offset);
      }
      status = ObjectStatus.normal;
    }

    // END_OF_GROUP bit overrides status if set
    if (endOfGroup && (status == null || status == ObjectStatus.normal)) {
      status = ObjectStatus.endOfGroup;
    }

    return ObjectDatagram(
      trackAlias: trackAlias,
      groupId: groupId,
      objectId: objectId,
      publisherPriority: publisherPriority,
      extensionHeaders: headers,
      status: status ?? ObjectStatus.normal,
      payload: payload,
      useDefaultPriority: defaultPriority,
    );
  }

  /// Check if this is a normal object with payload
  bool get isNormal => status == null || status == ObjectStatus.normal;

  /// Check if this object exists
  bool get exists => status != ObjectStatus.doesNotExist;

  /// Check if this marks end of group
  bool get isEndOfGroup => status == ObjectStatus.endOfGroup;

  /// Check if this marks end of track
  bool get isEndOfTrack => status == ObjectStatus.endOfTrack;
}

/// Subgroup Header - identifies a stream carrying objects
///
/// Wire format:
/// SUBGROUP_HEADER Message {
///   Type (i) = Subgroup Type (draft-14: 0x10-0x1D, draft-16: 0x10-0x1D/0x30-0x3D),
///   Track Alias (i),
///   Group ID (i),
///   Subgroup ID (i),
///   [First Object ID (i),]
///   [Publisher Priority (8),]  // omitted when draft-16 DEFAULT_PRIORITY bit set
///   [Number of Extension Headers (i),
///   Extension Headers (..) ...,]
/// }
///
/// Draft-14 type bitfield (0x10-0x1D):
///   Bit 0 (0x01): EXTENSIONS present
///   Bits 1-2: subgroupId mode (00=absent/0, 01=first obj ID, 10=explicit field)
///   Type >= 0x18: END_OF_GROUP
///
/// Draft-16 type bitfield (0x10-0x15, 0x18-0x1D, 0x30-0x35, 0x38-0x3D):
///   Bit 0 (0x01): EXTENSIONS present
///   Bits 1-2 (mask 0x06): SUBGROUP_ID_MODE
///   Bit 3 (0x08): END_OF_GROUP
///   Bit 4: always 1 (0x10 base for subgroup)
///   Bit 5 (0x20): DEFAULT_PRIORITY - Publisher Priority omitted
class SubgroupHeader {
  final Int64 trackAlias;
  final Int64 groupId;
  final Int64 subgroupId;
  final Int64? firstObjectId;
  final int publisherPriority;
  final List<KeyValuePair> extensionHeaders;
  final bool useDefaultPriority; // draft-16: when true, omit Publisher Priority byte
  final bool endOfGroup; // draft-16: explicit END_OF_GROUP flag
  final bool _extensionsBitSet; // true when type bit 0 is set (per-object extensions present)

  SubgroupHeader({
    required this.trackAlias,
    required this.groupId,
    required this.subgroupId,
    this.firstObjectId,
    required this.publisherPriority,
    this.extensionHeaders = const [],
    this.useDefaultPriority = false,
    this.endOfGroup = false,
    bool extensionsBitSet = false,
  }) : _extensionsBitSet = extensionsBitSet || extensionHeaders.isNotEmpty;

  /// Get the message type based on forwarding preference (draft-14 default)
  int get messageType => _messageType(MoQVersion.draft14);

  /// Compute the message type for a given protocol version.
  ///
  /// Draft-14 type bitfield (0x10-0x1D):
  ///   Bit 0 (0x01): EXTENSIONS present
  ///   Bits 1-2: subgroupId mode (00=absent/0, 01=first obj ID, 10=explicit field)
  ///   Bit 3 (0x08): END_OF_GROUP
  ///
  /// Draft-16 adds:
  ///   Bit 5 (0x20): DEFAULT_PRIORITY - Publisher Priority omitted
  int _messageType(int version) {
    int type = 0x10; // base subgroup type
    // Bit 0: extensions present
    if (_extensionsBitSet) {
      type |= 0x01;
    }
    // Bits 1-2: subgroup ID mode
    if (firstObjectId != null) {
      // Mode 01: subgroupId is first object ID
      type |= 0x02;
    } else if (subgroupId != Int64(0)) {
      // Mode 10: explicit subgroup ID field
      type |= 0x04;
    }
    // Bit 3: END_OF_GROUP
    if (endOfGroup) {
      type |= 0x08;
    }
    // Bit 5: DEFAULT_PRIORITY (draft-16+ only)
    if (MoQVersion.isDraft16OrLater(version) && useDefaultPriority) {
      type |= 0x20;
    }
    return type;
  }

  /// Serialize the subgroup header per draft-14 Section 10.4.2:
  ///   Type (i) + Track Alias (i) + Group ID (i) + [Subgroup ID (i)] + Publisher Priority (8)
  ///
  /// Subgroup ID field is only present when type bits 1-2 == 10 (explicit mode).
  /// Extension headers are per-object, NOT in the subgroup header.
  Uint8List serialize({int version = MoQVersion.draft14}) {
    final type = _messageType(version);
    final skipPriority = MoQVersion.isDraft16OrLater(version) && useDefaultPriority;
    final hasSubgroupIdField = (type & 0x06) == 0x04; // bits 1-2 == 10: explicit field

    int len = 0;
    len += MoQWireFormat._varintSize(type);
    len += MoQWireFormat._varintSize64(trackAlias);
    len += MoQWireFormat._varintSize64(groupId);
    if (hasSubgroupIdField) {
      len += MoQWireFormat._varintSize64(subgroupId);
    }
    if (!skipPriority) {
      len += 1; // Publisher Priority
    }

    final buffer = Uint8List(len);
    int offset = 0;

    offset += _writeVarint(buffer, offset, type);
    offset += _writeVarint64(buffer, offset, trackAlias);
    offset += _writeVarint64(buffer, offset, groupId);
    if (hasSubgroupIdField) {
      offset += _writeVarint64(buffer, offset, subgroupId);
    }

    if (!skipPriority) {
      buffer[offset++] = publisherPriority;
    }

    return buffer;
  }

  int _writeVarint(Uint8List buffer, int offset, int value) {
    final bytes = MoQWireFormat.encodeVarint(value);
    buffer.setAll(offset, bytes);
    return bytes.length;
  }

  int _writeVarint64(Uint8List buffer, int offset, Int64 value) {
    final bytes = MoQWireFormat.encodeVarint64(value);
    buffer.setAll(offset, bytes);
    return bytes.length;
  }

  /// Whether this subgroup's objects have extension headers (type bit 0).
  bool get extensionsPresent => _extensionsBitSet;

  /// Deserialize a subgroup header per draft-14 Section 10.4.2:
  ///   Type (i) + Track Alias (i) + Group ID (i) + [Subgroup ID (i)] + Publisher Priority (8)
  static SubgroupHeader deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
    int offset = 0;

    // Type
    final (type, typeLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += typeLen;

    // Decode type flags from bitfield
    final hasExtBit = (type & 0x01) != 0;
    final subgroupIdMode = (type & 0x06) >> 1; // 00=zero, 01=firstObjId, 10=explicit
    final eog = (type & 0x08) != 0;
    bool defaultPriority = false;

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: accept 0x10-0x1D and 0x30-0x3D
      final masked = type & ~0x20; // mask out bit 5 for validation
      if (masked < 0x10 || masked > 0x1D) {
        throw FormatException('Invalid draft-16 subgroup header type: 0x${type.toRadixString(16)}');
      }
      defaultPriority = (type & 0x20) != 0;
    }

    // Track Alias
    final (trackAlias, aliasLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += aliasLen;

    // Group ID
    final (groupId, groupLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += groupLen;

    // Subgroup ID - only present when bits 1-2 == 10 (explicit field)
    Int64 subgroupId = Int64(0);
    Int64? firstObjectId;
    if (subgroupIdMode == 2) {
      // Explicit subgroup ID field
      final (sid, sidLen) = MoQWireFormat.decodeVarint64(data, offset);
      offset += sidLen;
      subgroupId = sid;
    }
    // Mode 1 (firstObjectId): subgroupId determined from first object, leave as 0 for now

    // Publisher Priority (skipped when draft-16 DEFAULT_PRIORITY bit is set)
    int publisherPriority = 0;
    if (!(MoQVersion.isDraft16OrLater(version) && defaultPriority)) {
      publisherPriority = data[offset++];
    }

    // Note: extension headers are per-object, not in the subgroup header.
    // The type's extension bit tells the receiver whether objects have extensions.

    return SubgroupHeader(
      trackAlias: trackAlias,
      groupId: groupId,
      subgroupId: subgroupId,
      firstObjectId: firstObjectId,
      publisherPriority: publisherPriority,
      useDefaultPriority: defaultPriority,
      endOfGroup: eog,
      extensionsBitSet: hasExtBit,
    );
  }
}

/// Object within a subgroup stream
///
/// Wire format:
/// SUBGROUP_OBJECT {
///   [Object ID (i),]
///   Publisher Priority (8),
///   [Object Status (8),]
///   [Number of Extension Headers (i),
///   Extension Headers (..) ...,]
///   [Object Payload Length (i),
///   Object Payload (..)]
/// }
class SubgroupObject {
  final Int64? objectId;
  final int publisherPriority;
  final ObjectStatus? status;
  final List<KeyValuePair> extensionHeaders;
  final Uint8List? payload;

  SubgroupObject({
    this.objectId,
    required this.publisherPriority,
    this.status,
    this.extensionHeaders = const [],
    this.payload,
  });

  /// Serialize the object
  Uint8List serialize() {
    int len = 0;
    if (objectId != null) {
      len += MoQWireFormat._varintSize64(objectId!);
    }
    len += 1; // Publisher Priority
    len += MoQWireFormat._varintSize(extensionHeaders.length);
    for (final param in extensionHeaders) {
      len += MoQWireFormat._varintSize(param.type);
      if (param.value != null) {
        // Even types have varint value, odd types have length-prefixed buffer
        if (param.type % 2 == 0) {
          len += MoQWireFormat._varintSize(param.value![0]);
        } else {
          len += MoQWireFormat._varintSize(param.value!.length) + param.value!.length;
        }
      }
    }
    if (status != null && status != ObjectStatus.normal) {
      len += 1;
    }
    if (payload != null && isNormal) {
      len += MoQWireFormat._varintSize(payload!.length) + payload!.length;
    }

    final buffer = Uint8List(len);
    int offset = 0;

    if (objectId != null) {
      offset += _writeVarint64(buffer, offset, objectId!);
    }

    buffer[offset++] = publisherPriority;

    offset += _writeVarint(buffer, offset, extensionHeaders.length);
    for (final param in extensionHeaders) {
      offset += _writeVarint(buffer, offset, param.type);
      if (param.value != null) {
        // Even types have varint value, odd types have length-prefixed buffer
        if (param.type % 2 == 0) {
          offset += _writeVarint(buffer, offset, param.value![0]);
        } else {
          offset += _writeVarint(buffer, offset, param.value!.length);
          buffer.setAll(offset, param.value!);
          offset += param.value!.length;
        }
      }
    }

    if (status != null && status != ObjectStatus.normal) {
      buffer[offset++] = status!.value;
    }

    if (payload != null && isNormal) {
      offset += _writeVarint(buffer, offset, payload!.length);
      buffer.setAll(offset, payload!);
    }

    return buffer;
  }

  int _writeVarint(Uint8List buffer, int offset, int value) {
    final bytes = MoQWireFormat.encodeVarint(value);
    buffer.setAll(offset, bytes);
    return bytes.length;
  }

  int _writeVarint64(Uint8List buffer, int offset, Int64 value) {
    final bytes = MoQWireFormat.encodeVarint64(value);
    buffer.setAll(offset, bytes);
    return bytes.length;
  }

  /// Deserialize a subgroup object
  static SubgroupObject deserialize(Uint8List data, {bool hasObjectId = true}) {
    int offset = 0;

    Int64? objectId;
    if (hasObjectId && offset < data.length) {
      final (oid, oidLen) = MoQWireFormat.decodeVarint64(data, offset);
      offset += oidLen;
      objectId = oid;
    }

    final publisherPriority = data[offset++];

    final (numHeaders, headersLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += headersLen;

    final headers = <KeyValuePair>[];
    for (int i = 0; i < numHeaders; i++) {
      final (headerType, typeLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += typeLen;

      Uint8List? value;
      if (offset < data.length) {
        // Even types have varint value, odd types have length-prefixed buffer
        if (headerType % 2 == 0) {
          // Even type: value is a single varint
          final (varintValue, varintLen) = MoQWireFormat.decodeVarint(data, offset);
          offset += varintLen;
          // Store varint as single-byte array for consistency
          value = Uint8List.fromList([varintValue & 0xFF]);
        } else {
          // Odd type: value is length-prefixed buffer
          final (length, lengthLen) = MoQWireFormat.decodeVarint(data, offset);
          offset += lengthLen;
          if (length > 0 && offset + length <= data.length) {
            value = data.sublist(offset, offset + length);
            offset += length;
          }
        }
      }
      headers.add(KeyValuePair(type: headerType, value: value));
    }

    ObjectStatus? status;
    Uint8List? payload;

    if (offset < data.length) {
      final nextByte = data[offset];
      if (nextByte <= 0x04 && (data.length - offset) <= 2) {
        status = ObjectStatus.fromValue(data[offset++]);
      } else {
        final (payloadLen, payloadLenLen) = MoQWireFormat.decodeVarint(data, offset);
        offset += payloadLenLen;
        if (payloadLen > 0 && offset + payloadLen <= data.length) {
          payload = data.sublist(offset, offset + payloadLen);
        }
        status = ObjectStatus.normal;
      }
    }

    return SubgroupObject(
      objectId: objectId,
      publisherPriority: publisherPriority,
      status: status ?? ObjectStatus.normal,
      extensionHeaders: headers,
      payload: payload,
    );
  }

  /// Check if this is a normal object with payload
  bool get isNormal => status == null || status == ObjectStatus.normal;

  /// Check if this object exists
  bool get exists => status != ObjectStatus.doesNotExist;

  /// Check if this marks end of group
  bool get isEndOfGroup => status == ObjectStatus.endOfGroup;

  /// Check if this marks end of track
  bool get isEndOfTrack => status == ObjectStatus.endOfTrack;
}

/// Canonical MoQ Object
class MoQObject {
  final List<Uint8List> trackNamespace;
  final Uint8List trackName;
  final Int64 groupId;
  final Int64 objectId;
  final int publisherPriority;
  final ObjectForwardingPreference forwardingPreference;
  final Int64? subgroupId;
  final ObjectStatus status;
  final List<KeyValuePair> extensionHeaders;
  final Uint8List? payload;

  MoQObject({
    required this.trackNamespace,
    required this.trackName,
    required this.groupId,
    required this.objectId,
    required this.publisherPriority,
    required this.forwardingPreference,
    this.subgroupId,
    required this.status,
    this.extensionHeaders = const [],
    this.payload,
  });

  /// Get the location of this object
  Location get location => Location(group: groupId, object: objectId);

  /// Check if this is a normal object with payload
  bool get isNormal => status == ObjectStatus.normal;

  /// Check if this object exists
  bool get exists => status != ObjectStatus.doesNotExist;

  /// Check if this marks end of group
  bool get isEndOfGroup => status == ObjectStatus.endOfGroup;

  /// Check if this marks end of track
  bool get isEndOfTrack => status == ObjectStatus.endOfTrack;

  /// Convert to ObjectDatagram
  ObjectDatagram toObjectDatagram(Int64 trackAlias) {
    return ObjectDatagram(
      trackAlias: trackAlias,
      groupId: groupId,
      objectId: objectId,
      publisherPriority: publisherPriority,
      extensionHeaders: extensionHeaders,
      status: status,
      payload: payload,
    );
  }

  /// Convert to SubgroupObject
  SubgroupObject toSubgroupObject() {
    return SubgroupObject(
      objectId: objectId,
      publisherPriority: publisherPriority,
      status: status,
      extensionHeaders: extensionHeaders,
      payload: payload,
    );
  }
}

/// Object Forwarding Preference
enum ObjectForwardingPreference {
  subgroup,
  datagram,
}
