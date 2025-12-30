part of 'moq_messages.dart';

/// Object Datagram - carries a single object in a datagram
///
/// Wire format:
/// OBJECT_DATAGRAM Message {
///   Type (i) = Object Datagram Type (0x00-0x07, 0x20-0x27),
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
class ObjectDatagram {
  final Int64 trackAlias;
  final Int64 groupId;
  final Int64? objectId;
  final int publisherPriority;
  final List<KeyValuePair> extensionHeaders;
  final ObjectStatus? status;
  final Uint8List? payload;

  ObjectDatagram({
    required this.trackAlias,
    required this.groupId,
    this.objectId,
    required this.publisherPriority,
    this.extensionHeaders = const [],
    this.status,
    this.payload,
  });

  /// Get the message type based on status
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

  /// Serialize the object datagram
  Uint8List serialize() {
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
        len += MoQWireFormat._varintSize(param.value!.length) + param.value!.length;
      }
    }
    // Status (conditional - omit if normal)
    if (status != null && status != ObjectStatus.normal) {
      len += 1;
    }
    // Payload (conditional)
    if (payload != null && status == ObjectStatus.normal) {
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
        offset += _writeVarint(buffer, offset, param.value!.length);
        buffer.setAll(offset, param.value!);
        offset += param.value!.length;
      }
    }

    // Status
    if (status != null && status != ObjectStatus.normal) {
      buffer[offset++] = status!.value;
    }

    // Payload
    if (payload != null && status == ObjectStatus.normal) {
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

  /// Deserialize an object datagram from bytes
  static ObjectDatagram deserialize(Uint8List data) {
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
        final (length, lengthLen) = MoQWireFormat.decodeVarint(data, offset);
        offset += lengthLen;
        if (length > 0 && offset + length <= data.length) {
          value = data.sublist(offset, offset + length);
          offset += length;
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
///   Type (i) = Subgroup Type (0x10-0x1D),
///   Track Alias (i),
///   Group ID (i),
///   Subgroup ID (i),
///   [First Object ID (i),]
///   Publisher Priority (8),
///   [Number of Extension Headers (i),
///   Extension Headers (..) ...,]
/// }
class SubgroupHeader {
  final Int64 trackAlias;
  final Int64 groupId;
  final Int64 subgroupId;
  final Int64? firstObjectId;
  final int publisherPriority;
  final List<KeyValuePair> extensionHeaders;

  SubgroupHeader({
    required this.trackAlias,
    required this.groupId,
    required this.subgroupId,
    this.firstObjectId,
    required this.publisherPriority,
    this.extensionHeaders = const [],
  });

  /// Get the message type based on forwarding preference
  int get messageType => 0x10; // SUBGROUP_HEADER_BASE

  /// Serialize the subgroup header
  Uint8List serialize() {
    int len = 0;
    len += MoQWireFormat._varintSize(messageType);
    len += MoQWireFormat._varintSize64(trackAlias);
    len += MoQWireFormat._varintSize64(groupId);
    len += MoQWireFormat._varintSize64(subgroupId);
    if (firstObjectId != null) {
      len += MoQWireFormat._varintSize64(firstObjectId!);
    }
    len += 1; // Publisher Priority
    len += MoQWireFormat._varintSize(extensionHeaders.length);
    for (final param in extensionHeaders) {
      len += MoQWireFormat._varintSize(param.type);
      if (param.value != null) {
        len += MoQWireFormat._varintSize(param.value!.length) + param.value!.length;
      }
    }

    final buffer = Uint8List(len);
    int offset = 0;

    offset += _writeVarint(buffer, offset, messageType);
    offset += _writeVarint64(buffer, offset, trackAlias);
    offset += _writeVarint64(buffer, offset, groupId);
    offset += _writeVarint64(buffer, offset, subgroupId);

    if (firstObjectId != null) {
      offset += _writeVarint64(buffer, offset, firstObjectId!);
    }

    buffer[offset++] = publisherPriority;

    offset += _writeVarint(buffer, offset, extensionHeaders.length);
    for (final param in extensionHeaders) {
      offset += _writeVarint(buffer, offset, param.type);
      if (param.value != null) {
        offset += _writeVarint(buffer, offset, param.value!.length);
        buffer.setAll(offset, param.value!);
        offset += param.value!.length;
      }
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

  /// Deserialize a subgroup header from bytes
  static SubgroupHeader deserialize(Uint8List data) {
    int offset = 0;

    // Type
    final (type, typeLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += typeLen;

    // Track Alias
    final (trackAlias, aliasLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += aliasLen;

    // Group ID
    final (groupId, groupLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += groupLen;

    // Subgroup ID
    final (subgroupId, subgroupLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += subgroupLen;

    // First Object ID (conditional)
    Int64? firstObjectId;
    if (offset < data.length) {
      try {
        final (fid, fidLen) = MoQWireFormat.decodeVarint64(data, offset);
        offset += fidLen;
        firstObjectId = fid;
      } catch (_) {
        // Not an object ID, continue
      }
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
        final (length, lengthLen) = MoQWireFormat.decodeVarint(data, offset);
        offset += lengthLen;
        if (length > 0 && offset + length <= data.length) {
          value = data.sublist(offset, offset + length);
          offset += length;
        }
      }
      headers.add(KeyValuePair(type: headerType, value: value));
    }

    return SubgroupHeader(
      trackAlias: trackAlias,
      groupId: groupId,
      subgroupId: subgroupId,
      firstObjectId: firstObjectId,
      publisherPriority: publisherPriority,
      extensionHeaders: headers,
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
        len += MoQWireFormat._varintSize(param.value!.length) + param.value!.length;
      }
    }
    if (status != null && status != ObjectStatus.normal) {
      len += 1;
    }
    if (payload != null && status == ObjectStatus.normal) {
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
        offset += _writeVarint(buffer, offset, param.value!.length);
        buffer.setAll(offset, param.value!);
        offset += param.value!.length;
      }
    }

    if (status != null && status != ObjectStatus.normal) {
      buffer[offset++] = status!.value;
    }

    if (payload != null && status == ObjectStatus.normal) {
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
        final (length, lengthLen) = MoQWireFormat.decodeVarint(data, offset);
        offset += lengthLen;
        if (length > 0 && offset + length <= data.length) {
          value = data.sublist(offset, offset + length);
          offset += length;
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
