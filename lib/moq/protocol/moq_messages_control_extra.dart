part of 'moq_messages.dart';

// NOTE: This file contains the remaining control messages for MoQ draft-14
// These are appended to moq_messages_control.dart

/// FETCH message (0x16)
///
/// Wire format:
/// FETCH Message {
///   Type (i) = 0x16,
///   Length (16),
///   Request ID (i),
///   Track Namespace (tuple),
///   Track Name Length (i),
///   Track Name (..),
///   Start Group (i),
///   Start Object (i),
///   End Group (i),
///   End Object (i),
///   Fetch Priority (8),
///   Number of Parameters (i),
///   Parameters (..) ...
/// }
class FetchMessage extends MoQControlMessage {
  final Int64 requestId;
  final List<Uint8List> trackNamespace;
  final Uint8List trackName;
  final Int64 startGroup;
  final Int64 startObject;
  final Int64 endGroup;
  final Int64 endObject;
  final int fetchPriority;
  final List<KeyValuePair> parameters;

  FetchMessage({
    required this.requestId,
    required this.trackNamespace,
    required this.trackName,
    required this.startGroup,
    required this.startObject,
    required this.endGroup,
    required this.endObject,
    required this.fetchPriority,
    this.parameters = const [],
  });

  @override
  MoQMessageType get type => MoQMessageType.fetch;

  @override
  int get payloadLength {
    int len = 0;
    len += MoQWireFormat._varintSize64(requestId);
    len += _tupleSize(trackNamespace);
    len += MoQWireFormat._varintSize(trackName.length) + trackName.length;
    len += MoQWireFormat._varintSize64(startGroup);
    len += MoQWireFormat._varintSize64(startObject);
    len += MoQWireFormat._varintSize64(endGroup);
    len += MoQWireFormat._varintSize64(endObject);
    len += 1; // Fetch Priority
    len += MoQWireFormat._varintSize(parameters.length);
    for (final param in parameters) {
      len += MoQWireFormat._varintSize(param.type);
      if (param.value != null) {
        len += MoQWireFormat._varintSize(param.value!.length) + param.value!.length;
      }
    }
    return len;
  }

  int _tupleSize(List<Uint8List> tuple) {
    int len = MoQWireFormat._varintSize(tuple.length);
    for (final element in tuple) {
      len += MoQWireFormat._varintSize(element.length) + element.length;
    }
    return len;
  }

  @override
  Uint8List serialize() {
    final payload = Uint8List(payloadLength);
    int offset = 0;

    offset += _writeVarint64(payload, offset, requestId);
    offset += _writeTuple(payload, offset, trackNamespace);
    offset += _writeVarint(payload, offset, trackName.length);
    payload.setAll(offset, trackName);
    offset += trackName.length;
    offset += _writeVarint64(payload, offset, startGroup);
    offset += _writeVarint64(payload, offset, startObject);
    offset += _writeVarint64(payload, offset, endGroup);
    offset += _writeVarint64(payload, offset, endObject);
    payload[offset++] = fetchPriority;
    offset += _writeVarint(payload, offset, parameters.length);

    for (final param in parameters) {
      offset += _writeVarint(payload, offset, param.type);
      if (param.value != null) {
        offset += _writeVarint(payload, offset, param.value!.length);
        payload.setAll(offset, param.value!);
        offset += param.value!.length;
      }
    }

    return _wrapMessage(payload);
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

  int _writeTuple(Uint8List buffer, int offset, List<Uint8List> tuple) {
    final bytes = MoQWireFormat.encodeTuple(tuple);
    buffer.setAll(offset, bytes);
    return bytes.length;
  }

  Uint8List _wrapMessage(Uint8List payload) {
    final typeBytes = MoQWireFormat.encodeVarint(type.value);
    final buffer = Uint8List(typeBytes.length + 2 + payload.length);
    int offset = 0;

    buffer.setAll(offset, typeBytes);
    offset += typeBytes.length;

    buffer[offset++] = (payload.length >> 8) & 0xFF;
    buffer[offset++] = payload.length & 0xFF;

    buffer.setAll(offset, payload);

    return buffer;
  }

  static FetchMessage deserialize(Uint8List data) {
    int offset = 0;

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    final (namespace, len2) = MoQWireFormat.decodeTuple(data, offset);
    offset += len2;

    final (nameLen, len3) = MoQWireFormat.decodeVarint(data, offset);
    offset += len3;
    final trackName = data.sublist(offset, offset + nameLen);
    offset += nameLen;

    final (startGroup, len4) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len4;

    final (startObject, len5) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len5;

    final (endGroup, len6) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len6;

    final (endObject, len7) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len7;

    final fetchPriority = data[offset++];

    final (numParams, numParamsLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += numParamsLen;

    final params = <KeyValuePair>[];
    for (int i = 0; i < numParams; i++) {
      final (type, typeLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += typeLen;

      Uint8List? value;
      if (offset < data.length) {
        final (length, lengthLen) = MoQWireFormat.decodeVarint(data, offset);
        offset += lengthLen;
        if (length > 0) {
          value = data.sublist(offset, offset + length);
          offset += length;
        }
      }
      params.add(KeyValuePair(type: type, value: value));
    }

    return FetchMessage(
      requestId: requestId,
      trackNamespace: namespace,
      trackName: trackName,
      startGroup: startGroup,
      startObject: startObject,
      endGroup: endGroup,
      endObject: endObject,
      fetchPriority: fetchPriority,
      parameters: params,
    );
  }
}

/// FETCH_OK message (0x18)
class FetchOkMessage extends MoQControlMessage {
  final Int64 requestId;
  final Int64 expires;
  final GroupOrder groupOrder;
  final int contentExists;
  final Location? largestLocation;
  final List<KeyValuePair> parameters;

  FetchOkMessage({
    required this.requestId,
    required this.expires,
    required this.groupOrder,
    required this.contentExists,
    this.largestLocation,
    this.parameters = const [],
  });

  @override
  MoQMessageType get type => MoQMessageType.fetchOk;

  @override
  int get payloadLength {
    int len = 0;
    len += MoQWireFormat._varintSize64(requestId);
    len += MoQWireFormat._varintSize64(expires);
    len += 1; // Group Order
    len += 1; // Content Exists
    if (contentExists == 1 && largestLocation != null) {
      len += _locationSize();
    }
    len += MoQWireFormat._varintSize(parameters.length);
    for (final param in parameters) {
      len += MoQWireFormat._varintSize(param.type);
      if (param.value != null) {
        len += MoQWireFormat._varintSize(param.value!.length) + param.value!.length;
      }
    }
    return len;
  }

  int _locationSize() {
    int len = MoQWireFormat._varintSize64(largestLocation?.group ?? Int64(0));
    len += MoQWireFormat._varintSize64(largestLocation?.object ?? Int64(0));
    return len;
  }

  @override
  Uint8List serialize() {
    final payload = Uint8List(payloadLength);
    int offset = 0;

    offset += _writeVarint64(payload, offset, requestId);
    offset += _writeVarint64(payload, offset, expires);
    payload[offset++] = groupOrder.value;
    payload[offset++] = contentExists;

    if (contentExists == 1 && largestLocation != null) {
      offset += _writeLocation(payload, offset, largestLocation!);
    }

    offset += _writeVarint(payload, offset, parameters.length);

    for (final param in parameters) {
      offset += _writeVarint(payload, offset, param.type);
      if (param.value != null) {
        offset += _writeVarint(payload, offset, param.value!.length);
        payload.setAll(offset, param.value!);
        offset += param.value!.length;
      }
    }

    return _wrapMessage(payload);
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

  int _writeLocation(Uint8List buffer, int offset, Location location) {
    final bytes = MoQWireFormat.encodeLocation(location);
    buffer.setAll(offset, bytes);
    return bytes.length;
  }

  Uint8List _wrapMessage(Uint8List payload) {
    final typeBytes = MoQWireFormat.encodeVarint(type.value);
    final buffer = Uint8List(typeBytes.length + 2 + payload.length);
    int offset = 0;

    buffer.setAll(offset, typeBytes);
    offset += typeBytes.length;

    buffer[offset++] = (payload.length >> 8) & 0xFF;
    buffer[offset++] = payload.length & 0xFF;

    buffer.setAll(offset, payload);

    return buffer;
  }

  static FetchOkMessage deserialize(Uint8List data) {
    int offset = 0;

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    final (expires, len2) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len2;

    final groupOrder = GroupOrder.fromValue(data[offset++]) ?? GroupOrder.none;
    final contentExists = data[offset++];

    Location? largestLocation;
    if (contentExists == 1 && offset < data.length) {
      final (location, locLen) = MoQWireFormat.decodeLocation(data, offset);
      offset += locLen;
      largestLocation = location;
    }

    final (numParams, numParamsLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += numParamsLen;

    final params = <KeyValuePair>[];
    for (int i = 0; i < numParams; i++) {
      final (type, typeLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += typeLen;

      Uint8List? value;
      if (offset < data.length) {
        final (length, lengthLen) = MoQWireFormat.decodeVarint(data, offset);
        offset += lengthLen;
        if (length > 0) {
          value = data.sublist(offset, offset + length);
          offset += length;
        }
      }
      params.add(KeyValuePair(type: type, value: value));
    }

    return FetchOkMessage(
      requestId: requestId,
      expires: expires,
      groupOrder: groupOrder,
      contentExists: contentExists,
      largestLocation: largestLocation,
      parameters: params,
    );
  }
}

/// FETCH_ERROR message (0x19)
class FetchErrorMessage extends MoQControlMessage {
  final Int64 requestId;
  final int errorCode;
  final ReasonPhrase errorReason;

  FetchErrorMessage({
    required this.requestId,
    required this.errorCode,
    required this.errorReason,
  });

  @override
  MoQMessageType get type => MoQMessageType.fetchError;

  @override
  int get payloadLength {
    int len = 0;
    len += MoQWireFormat._varintSize64(requestId);
    len += MoQWireFormat._varintSize(errorCode);
    final reasonBytes = const Utf8Encoder().convert(errorReason.reason);
    len += MoQWireFormat._varintSize(reasonBytes.length) + reasonBytes.length;
    return len;
  }

  @override
  Uint8List serialize() {
    final reasonBytes = const Utf8Encoder().convert(errorReason.reason);
    final payload = Uint8List(payloadLength);
    int offset = 0;

    offset += _writeVarint64(payload, offset, requestId);
    offset += _writeVarint(payload, offset, errorCode);
    offset += _writeVarint(payload, offset, reasonBytes.length);
    payload.setAll(offset, reasonBytes);

    return _wrapMessage(payload);
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

  Uint8List _wrapMessage(Uint8List payload) {
    final typeBytes = MoQWireFormat.encodeVarint(type.value);
    final buffer = Uint8List(typeBytes.length + 2 + payload.length);
    int offset = 0;

    buffer.setAll(offset, typeBytes);
    offset += typeBytes.length;

    buffer[offset++] = (payload.length >> 8) & 0xFF;
    buffer[offset++] = payload.length & 0xFF;

    buffer.setAll(offset, payload);

    return buffer;
  }

  static FetchErrorMessage deserialize(Uint8List data) {
    int offset = 0;

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    final (errorCode, len2) = MoQWireFormat.decodeVarint(data, offset);
    offset += len2;

    final (reasonLen, len3) = MoQWireFormat.decodeVarint(data, offset);
    offset += len3;

    final reasonBytes = data.sublist(offset, offset + reasonLen);
    final reason = const Utf8Decoder().convert(reasonBytes);

    return FetchErrorMessage(
      requestId: requestId,
      errorCode: errorCode,
      errorReason: ReasonPhrase(reason),
    );
  }
}

/// FETCH_CANCEL message (0x17)
class FetchCancelMessage extends MoQControlMessage {
  final Int64 requestId;

  FetchCancelMessage({
    required this.requestId,
  });

  @override
  MoQMessageType get type => MoQMessageType.fetchCancel;

  @override
  int get payloadLength => MoQWireFormat._varintSize64(requestId);

  @override
  Uint8List serialize() {
    final payload = Uint8List(payloadLength);
    int offset = 0;
    offset += _writeVarint64(payload, offset, requestId);

    return _wrapMessage(payload);
  }

  int _writeVarint64(Uint8List buffer, int offset, Int64 value) {
    final bytes = MoQWireFormat.encodeVarint64(value);
    buffer.setAll(offset, bytes);
    return bytes.length;
  }

  Uint8List _wrapMessage(Uint8List payload) {
    final typeBytes = MoQWireFormat.encodeVarint(type.value);
    final buffer = Uint8List(typeBytes.length + 2 + payload.length);
    int offset = 0;

    buffer.setAll(offset, typeBytes);
    offset += typeBytes.length;

    buffer[offset++] = (payload.length >> 8) & 0xFF;
    buffer[offset++] = payload.length & 0xFF;

    buffer.setAll(offset, payload);

    return buffer;
  }

  static FetchCancelMessage deserialize(Uint8List data) {
    final (requestId, _) = MoQWireFormat.decodeVarint64(data, 0);
    return FetchCancelMessage(requestId: requestId);
  }
}

/// PUBLISH message (0x1D) per draft-ietf-moq-transport-14
///
/// Sent by publisher to initiate a subscription to a track.
///
/// Wire format:
/// PUBLISH Message {
///   Type (i) = 0x1D,
///   Length (16),
///   Request ID (i),
///   Track Namespace (tuple),
///   Track Name Length (i),
///   Track Name (..),
///   Track Alias (i),
///   Group Order (8),
///   Content Exists (8),
///   [Largest Location (Location),]
///   Forward (8),
///   Number of Parameters (i),
///   Parameters (..) ...,
/// }
class PublishMessage extends MoQControlMessage {
  final Int64 requestId;
  final List<Uint8List> trackNamespace;
  final Uint8List trackName;
  final Int64 trackAlias;
  final GroupOrder groupOrder;
  final bool contentExists;
  final Location? largestLocation; // Only present if contentExists == true
  final int forward; // 0 or 1
  final List<KeyValuePair> parameters;

  PublishMessage({
    required this.requestId,
    required this.trackNamespace,
    required this.trackName,
    required this.trackAlias,
    required this.groupOrder,
    required this.contentExists,
    this.largestLocation,
    required this.forward,
    this.parameters = const [],
  });

  @override
  MoQMessageType get type => MoQMessageType.publish;

  @override
  int get payloadLength {
    int len = 0;
    len += MoQWireFormat._varintSize64(requestId);
    len += _tupleSize(trackNamespace);
    len += MoQWireFormat._varintSize(trackName.length) + trackName.length;
    len += MoQWireFormat._varintSize64(trackAlias);
    len += 1; // Group Order (8 bits)
    len += 1; // Content Exists (8 bits)
    if (contentExists && largestLocation != null) {
      len += MoQWireFormat._varintSize64(largestLocation!.group);
      len += MoQWireFormat._varintSize64(largestLocation!.object);
    }
    len += 1; // Forward (8 bits)
    len += MoQWireFormat._varintSize(parameters.length);
    for (final param in parameters) {
      len += MoQWireFormat._varintSize(param.type);
      if (param.value != null) {
        len += MoQWireFormat._varintSize(param.value!.length) + param.value!.length;
      } else {
        len += MoQWireFormat._varintSize(0);
      }
    }
    return len;
  }

  int _tupleSize(List<Uint8List> tuple) {
    int len = MoQWireFormat._varintSize(tuple.length);
    for (final element in tuple) {
      len += MoQWireFormat._varintSize(element.length) + element.length;
    }
    return len;
  }

  @override
  Uint8List serialize() {
    final payload = Uint8List(payloadLength);
    int offset = 0;

    offset += _writeVarint64(payload, offset, requestId);
    offset += _writeTuple(payload, offset, trackNamespace);
    offset += _writeVarint(payload, offset, trackName.length);
    payload.setAll(offset, trackName);
    offset += trackName.length;
    offset += _writeVarint64(payload, offset, trackAlias);
    payload[offset++] = groupOrder.value;
    payload[offset++] = contentExists ? 1 : 0;

    if (contentExists && largestLocation != null) {
      offset += _writeVarint64(payload, offset, largestLocation!.group);
      offset += _writeVarint64(payload, offset, largestLocation!.object);
    }

    payload[offset++] = forward;
    offset += _writeVarint(payload, offset, parameters.length);

    for (final param in parameters) {
      offset += _writeVarint(payload, offset, param.type);
      if (param.value != null) {
        offset += _writeVarint(payload, offset, param.value!.length);
        payload.setAll(offset, param.value!);
        offset += param.value!.length;
      } else {
        offset += _writeVarint(payload, offset, 0);
      }
    }

    return _wrapMessage(payload);
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

  int _writeTuple(Uint8List buffer, int offset, List<Uint8List> tuple) {
    final bytes = MoQWireFormat.encodeTuple(tuple);
    buffer.setAll(offset, bytes);
    return bytes.length;
  }

  Uint8List _wrapMessage(Uint8List payload) {
    final typeBytes = MoQWireFormat.encodeVarint(type.value);
    final buffer = Uint8List(typeBytes.length + 2 + payload.length);
    int offset = 0;

    buffer.setAll(offset, typeBytes);
    offset += typeBytes.length;

    buffer[offset++] = (payload.length >> 8) & 0xFF;
    buffer[offset++] = payload.length & 0xFF;

    buffer.setAll(offset, payload);

    return buffer;
  }

  static PublishMessage deserialize(Uint8List data) {
    int offset = 0;

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    final (namespace, len2) = MoQWireFormat.decodeTuple(data, offset);
    offset += len2;

    final (nameLen, len3) = MoQWireFormat.decodeVarint(data, offset);
    offset += len3;
    final trackName = data.sublist(offset, offset + nameLen);
    offset += nameLen;

    final (trackAlias, len4) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len4;

    // Group Order (8 bits)
    final groupOrderValue = data[offset++];
    final groupOrder = GroupOrder.fromValue(groupOrderValue) ?? GroupOrder.ascending;

    // Content Exists (8 bits)
    final contentExists = data[offset++] == 1;

    // Largest Location (only present if contentExists == true)
    Location? largestLocation;
    if (contentExists) {
      final (groupId, len5) = MoQWireFormat.decodeVarint64(data, offset);
      offset += len5;
      final (objectId, len6) = MoQWireFormat.decodeVarint64(data, offset);
      offset += len6;
      largestLocation = Location(group: groupId, object: objectId);
    }

    // Forward (8 bits)
    final forward = data[offset++];

    // Parameters
    final (numParams, numParamsLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += numParamsLen;

    final params = <KeyValuePair>[];
    for (int i = 0; i < numParams; i++) {
      final (type, typeLen) = MoQWireFormat.decodeVarint(data, offset);
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
      params.add(KeyValuePair(type: type, value: value));
    }

    return PublishMessage(
      requestId: requestId,
      trackNamespace: namespace,
      trackName: Uint8List.fromList(trackName),
      trackAlias: trackAlias,
      groupOrder: groupOrder,
      contentExists: contentExists,
      largestLocation: largestLocation,
      forward: forward,
      parameters: params,
    );
  }

  /// Get track namespace as a string path
  String get namespacePath {
    return trackNamespace
        .map((e) => const Utf8Decoder().convert(e))
        .join('/');
  }

  /// Get track name as a string
  String get trackNameString => const Utf8Decoder().convert(trackName);
}

/// PUBLISH_OK message (0x1E) per draft-ietf-moq-transport-14
///
/// The subscriber sends PUBLISH_OK to accept a subscription initiated by PUBLISH.
class PublishOkMessage extends MoQControlMessage {
  final Int64 requestId;
  final int forward; // 0 (don't forward) or 1 (forward)
  final int subscriberPriority;
  final GroupOrder groupOrder;
  final FilterType filterType;
  final Location? startLocation; // Present for all filter types in response
  final Int64? endGroup; // Only for AbsoluteRange (0x4)
  final List<KeyValuePair> parameters;

  PublishOkMessage({
    required this.requestId,
    required this.forward,
    required this.subscriberPriority,
    required this.groupOrder,
    required this.filterType,
    this.startLocation,
    this.endGroup,
    this.parameters = const [],
  });

  @override
  MoQMessageType get type => MoQMessageType.publishOk;

  @override
  int get payloadLength {
    int len = 0;
    len += MoQWireFormat._varintSize64(requestId);
    len += 1; // Forward (8)
    len += 1; // Subscriber Priority (8)
    len += 1; // Group Order (8)
    len += MoQWireFormat._varintSize(filterType.value);

    // Start Location is present for all filter types
    if (startLocation != null) {
      len += MoQWireFormat._varintSize64(startLocation!.group);
      len += MoQWireFormat._varintSize64(startLocation!.object);
    }

    // End Group only for AbsoluteRange
    if (filterType == FilterType.absoluteRange && endGroup != null) {
      len += MoQWireFormat._varintSize64(endGroup!);
    }

    len += MoQWireFormat._varintSize(parameters.length);
    for (final param in parameters) {
      len += MoQWireFormat._varintSize(param.type);
      final valueLen = param.value?.length ?? 0;
      len += MoQWireFormat._varintSize(valueLen);
      len += valueLen;
    }
    return len;
  }

  @override
  Uint8List serialize() {
    final payload = Uint8List(payloadLength);
    int offset = 0;

    offset += _writeVarint64(payload, offset, requestId);
    payload[offset++] = forward & 0xFF;
    payload[offset++] = subscriberPriority & 0xFF;
    payload[offset++] = groupOrder.value & 0xFF;
    offset += _writeVarint(payload, offset, filterType.value);

    // Start Location
    if (startLocation != null) {
      offset += _writeVarint64(payload, offset, startLocation!.group);
      offset += _writeVarint64(payload, offset, startLocation!.object);
    }

    // End Group only for AbsoluteRange
    if (filterType == FilterType.absoluteRange && endGroup != null) {
      offset += _writeVarint64(payload, offset, endGroup!);
    }

    offset += _writeVarint(payload, offset, parameters.length);

    for (final param in parameters) {
      offset += _writeVarint(payload, offset, param.type);
      final valueLen = param.value?.length ?? 0;
      offset += _writeVarint(payload, offset, valueLen);
      if (valueLen > 0) {
        payload.setAll(offset, param.value!);
        offset += valueLen;
      }
    }

    return _wrapMessage(payload);
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

  Uint8List _wrapMessage(Uint8List payload) {
    final typeBytes = MoQWireFormat.encodeVarint(type.value);
    final lengthBytes = MoQWireFormat.encodeVarint(payload.length);
    final buffer = Uint8List(typeBytes.length + lengthBytes.length + payload.length);
    int offset = 0;

    buffer.setAll(offset, typeBytes);
    offset += typeBytes.length;

    buffer.setAll(offset, lengthBytes);
    offset += lengthBytes.length;

    buffer.setAll(offset, payload);

    return buffer;
  }

  static PublishOkMessage deserialize(Uint8List data) {
    int offset = 0;

    final (requestId, reqLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += reqLen;

    final forward = data[offset++];
    final subscriberPriority = data[offset++];
    final groupOrderValue = data[offset++];
    final groupOrder = GroupOrder.fromValue(groupOrderValue) ?? GroupOrder.ascending;

    final (filterTypeValue, filterLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += filterLen;
    final filterType = FilterType.fromValue(filterTypeValue) ?? FilterType.largestObject;

    // Start Location is present for all filter types
    Location? startLocation;
    if (offset < data.length) {
      final (group, groupLen) = MoQWireFormat.decodeVarint64(data, offset);
      offset += groupLen;
      final (object, objectLen) = MoQWireFormat.decodeVarint64(data, offset);
      offset += objectLen;
      startLocation = Location(group: group, object: object);
    }

    // End Group only for AbsoluteRange
    Int64? endGroup;
    if (filterType == FilterType.absoluteRange && offset < data.length) {
      final (eg, egLen) = MoQWireFormat.decodeVarint64(data, offset);
      offset += egLen;
      endGroup = eg;
    }

    final (numParams, numParamsLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += numParamsLen;

    final params = <KeyValuePair>[];
    for (int i = 0; i < numParams && offset < data.length; i++) {
      final (paramType, typeLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += typeLen;

      final (valueLen, valueLenLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += valueLenLen;

      Uint8List? value;
      if (valueLen > 0 && offset + valueLen <= data.length) {
        value = data.sublist(offset, offset + valueLen);
        offset += valueLen;
      }
      params.add(KeyValuePair(type: paramType, value: value));
    }

    return PublishOkMessage(
      requestId: requestId,
      forward: forward,
      subscriberPriority: subscriberPriority,
      groupOrder: groupOrder,
      filterType: filterType,
      startLocation: startLocation,
      endGroup: endGroup,
      parameters: params,
    );
  }
}

/// PUBLISH_ERROR message (0x1F)
class PublishErrorMessage extends MoQControlMessage {
  final Int64 requestId;
  final int errorCode;
  final ReasonPhrase errorReason;

  PublishErrorMessage({
    required this.requestId,
    required this.errorCode,
    required this.errorReason,
  });

  @override
  MoQMessageType get type => MoQMessageType.publishError;

  @override
  int get payloadLength {
    int len = 0;
    len += MoQWireFormat._varintSize64(requestId);
    len += MoQWireFormat._varintSize(errorCode);
    final reasonBytes = const Utf8Encoder().convert(errorReason.reason);
    len += MoQWireFormat._varintSize(reasonBytes.length) + reasonBytes.length;
    return len;
  }

  @override
  Uint8List serialize() {
    final reasonBytes = const Utf8Encoder().convert(errorReason.reason);
    final payload = Uint8List(payloadLength);
    int offset = 0;

    offset += _writeVarint64(payload, offset, requestId);
    offset += _writeVarint(payload, offset, errorCode);
    offset += _writeVarint(payload, offset, reasonBytes.length);
    payload.setAll(offset, reasonBytes);

    return _wrapMessage(payload);
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

  Uint8List _wrapMessage(Uint8List payload) {
    final typeBytes = MoQWireFormat.encodeVarint(type.value);
    final buffer = Uint8List(typeBytes.length + 2 + payload.length);
    int offset = 0;

    buffer.setAll(offset, typeBytes);
    offset += typeBytes.length;

    buffer[offset++] = (payload.length >> 8) & 0xFF;
    buffer[offset++] = payload.length & 0xFF;

    buffer.setAll(offset, payload);

    return buffer;
  }

  static PublishErrorMessage deserialize(Uint8List data) {
    int offset = 0;

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    final (errorCode, len2) = MoQWireFormat.decodeVarint(data, offset);
    offset += len2;

    final (reasonLen, len3) = MoQWireFormat.decodeVarint(data, offset);
    offset += len3;

    final reasonBytes = data.sublist(offset, offset + reasonLen);
    final reason = const Utf8Decoder().convert(reasonBytes);

    return PublishErrorMessage(
      requestId: requestId,
      errorCode: errorCode,
      errorReason: ReasonPhrase(reason),
    );
  }
}

/// MAX_REQUEST_ID message (0x15)
class MaxRequestIdMessage extends MoQControlMessage {
  final Int64 maxRequestId;

  MaxRequestIdMessage({
    required this.maxRequestId,
  });

  @override
  MoQMessageType get type => MoQMessageType.maxRequestId;

  @override
  int get payloadLength => MoQWireFormat._varintSize64(maxRequestId);

  @override
  Uint8List serialize() {
    final payload = Uint8List(payloadLength);
    int offset = 0;
    offset += _writeVarint64(payload, offset, maxRequestId);

    return _wrapMessage(payload);
  }

  int _writeVarint64(Uint8List buffer, int offset, Int64 value) {
    final bytes = MoQWireFormat.encodeVarint64(value);
    buffer.setAll(offset, bytes);
    return bytes.length;
  }

  Uint8List _wrapMessage(Uint8List payload) {
    final typeBytes = MoQWireFormat.encodeVarint(type.value);
    final buffer = Uint8List(typeBytes.length + 2 + payload.length);
    int offset = 0;

    buffer.setAll(offset, typeBytes);
    offset += typeBytes.length;

    buffer[offset++] = (payload.length >> 8) & 0xFF;
    buffer[offset++] = payload.length & 0xFF;

    buffer.setAll(offset, payload);

    return buffer;
  }

  static MaxRequestIdMessage deserialize(Uint8List data) {
    final (maxRequestId, _) = MoQWireFormat.decodeVarint64(data, 0);
    return MaxRequestIdMessage(maxRequestId: maxRequestId);
  }
}

/// REQUESTS_BLOCKED message (0x1A)
class RequestsBlockedMessage extends MoQControlMessage {
  final Int64 limit;
  final String? reason;

  RequestsBlockedMessage({
    required this.limit,
    this.reason,
  });

  @override
  MoQMessageType get type => MoQMessageType.requestsBlocked;

  @override
  int get payloadLength {
    int len = MoQWireFormat._varintSize64(limit);
    if (reason != null) {
      final reasonBytes = const Utf8Encoder().convert(reason!);
      len += MoQWireFormat._varintSize(reasonBytes.length) + reasonBytes.length;
    }
    return len;
  }

  @override
  Uint8List serialize() {
    int len = payloadLength;
    final payload = Uint8List(len);
    int offset = 0;

    offset += _writeVarint64(payload, offset, limit);

    if (reason != null) {
      final reasonBytes = const Utf8Encoder().convert(reason!);
      offset += _writeVarint(payload, offset, reasonBytes.length);
      payload.setAll(offset, reasonBytes);
    }

    return _wrapMessage(payload);
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

  Uint8List _wrapMessage(Uint8List payload) {
    final typeBytes = MoQWireFormat.encodeVarint(type.value);
    final buffer = Uint8List(typeBytes.length + 2 + payload.length);
    int offset = 0;

    buffer.setAll(offset, typeBytes);
    offset += typeBytes.length;

    buffer[offset++] = (payload.length >> 8) & 0xFF;
    buffer[offset++] = payload.length & 0xFF;

    buffer.setAll(offset, payload);

    return buffer;
  }

  static RequestsBlockedMessage deserialize(Uint8List data) {
    int offset = 0;

    final (limit, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    String? reason;
    if (offset < data.length) {
      final (reasonLen, len2) = MoQWireFormat.decodeVarint(data, offset);
      offset += len2;
      if (reasonLen > 0 && offset + reasonLen <= data.length) {
        final reasonBytes = data.sublist(offset, offset + reasonLen);
        reason = const Utf8Decoder().convert(reasonBytes);
      }
    }

    return RequestsBlockedMessage(
      limit: limit,
      reason: reason,
    );
  }
}

/// TRACK_STATUS message (0xD)
class TrackStatusMessage extends MoQControlMessage {
  final Int64 requestId;
  final Int64 trackAlias;
  final Int64 statusInterval;

  TrackStatusMessage({
    required this.requestId,
    required this.trackAlias,
    required this.statusInterval,
  });

  @override
  MoQMessageType get type => MoQMessageType.trackStatus;

  @override
  int get payloadLength {
    int len = 0;
    len += MoQWireFormat._varintSize64(requestId);
    len += MoQWireFormat._varintSize64(trackAlias);
    len += MoQWireFormat._varintSize64(statusInterval);
    return len;
  }

  @override
  Uint8List serialize() {
    final payload = Uint8List(payloadLength);
    int offset = 0;

    offset += _writeVarint64(payload, offset, requestId);
    offset += _writeVarint64(payload, offset, trackAlias);
    offset += _writeVarint64(payload, offset, statusInterval);

    return _wrapMessage(payload);
  }

  int _writeVarint64(Uint8List buffer, int offset, Int64 value) {
    final bytes = MoQWireFormat.encodeVarint64(value);
    buffer.setAll(offset, bytes);
    return bytes.length;
  }

  Uint8List _wrapMessage(Uint8List payload) {
    final typeBytes = MoQWireFormat.encodeVarint(type.value);
    final buffer = Uint8List(typeBytes.length + 2 + payload.length);
    int offset = 0;

    buffer.setAll(offset, typeBytes);
    offset += typeBytes.length;

    buffer[offset++] = (payload.length >> 8) & 0xFF;
    buffer[offset++] = payload.length & 0xFF;

    buffer.setAll(offset, payload);

    return buffer;
  }

  static TrackStatusMessage deserialize(Uint8List data) {
    int offset = 0;

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    final (trackAlias, len2) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len2;

    final (statusInterval, len3) = MoQWireFormat.decodeVarint64(data, offset);

    return TrackStatusMessage(
      requestId: requestId,
      trackAlias: trackAlias,
      statusInterval: statusInterval,
    );
  }
}

/// TRACK_STATUS_OK message (0xE)
class TrackStatusOkMessage extends MoQControlMessage {
  final Int64 requestId;
  final Int64 trackAlias;
  final Int64 lastGroup;
  final Int64 lastObject;
  final Int64 expires;
  final List<KeyValuePair> parameters;

  TrackStatusOkMessage({
    required this.requestId,
    required this.trackAlias,
    required this.lastGroup,
    required this.lastObject,
    required this.expires,
    this.parameters = const [],
  });

  @override
  MoQMessageType get type => MoQMessageType.trackStatusOk;

  @override
  int get payloadLength {
    int len = 0;
    len += MoQWireFormat._varintSize64(requestId);
    len += MoQWireFormat._varintSize64(trackAlias);
    len += MoQWireFormat._varintSize64(lastGroup);
    len += MoQWireFormat._varintSize64(lastObject);
    len += MoQWireFormat._varintSize64(expires);
    len += MoQWireFormat._varintSize(parameters.length);
    for (final param in parameters) {
      len += MoQWireFormat._varintSize(param.type);
      if (param.value != null) {
        len += MoQWireFormat._varintSize(param.value!.length) + param.value!.length;
      }
    }
    return len;
  }

  @override
  Uint8List serialize() {
    final payload = Uint8List(payloadLength);
    int offset = 0;

    offset += _writeVarint64(payload, offset, requestId);
    offset += _writeVarint64(payload, offset, trackAlias);
    offset += _writeVarint64(payload, offset, lastGroup);
    offset += _writeVarint64(payload, offset, lastObject);
    offset += _writeVarint64(payload, offset, expires);
    offset += _writeVarint(payload, offset, parameters.length);

    for (final param in parameters) {
      offset += _writeVarint(payload, offset, param.type);
      if (param.value != null) {
        offset += _writeVarint(payload, offset, param.value!.length);
        payload.setAll(offset, param.value!);
        offset += param.value!.length;
      }
    }

    return _wrapMessage(payload);
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

  Uint8List _wrapMessage(Uint8List payload) {
    final typeBytes = MoQWireFormat.encodeVarint(type.value);
    final buffer = Uint8List(typeBytes.length + 2 + payload.length);
    int offset = 0;

    buffer.setAll(offset, typeBytes);
    offset += typeBytes.length;

    buffer[offset++] = (payload.length >> 8) & 0xFF;
    buffer[offset++] = payload.length & 0xFF;

    buffer.setAll(offset, payload);

    return buffer;
  }

  static TrackStatusOkMessage deserialize(Uint8List data) {
    int offset = 0;

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    final (trackAlias, len2) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len2;

    final (lastGroup, len3) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len3;

    final (lastObject, len4) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len4;

    final (expires, len5) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len5;

    final (numParams, numParamsLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += numParamsLen;

    final params = <KeyValuePair>[];
    for (int i = 0; i < numParams; i++) {
      final (type, typeLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += typeLen;

      Uint8List? value;
      if (offset < data.length) {
        final (length, lengthLen) = MoQWireFormat.decodeVarint(data, offset);
        offset += lengthLen;
        if (length > 0) {
          value = data.sublist(offset, offset + length);
          offset += length;
        }
      }
      params.add(KeyValuePair(type: type, value: value));
    }

    return TrackStatusOkMessage(
      requestId: requestId,
      trackAlias: trackAlias,
      lastGroup: lastGroup,
      lastObject: lastObject,
      expires: expires,
      parameters: params,
    );
  }
}

/// TRACK_STATUS_ERROR message (0xF)
class TrackStatusErrorMessage extends MoQControlMessage {
  final Int64 requestId;
  final int errorCode;
  final ReasonPhrase errorReason;

  TrackStatusErrorMessage({
    required this.requestId,
    required this.errorCode,
    required this.errorReason,
  });

  @override
  MoQMessageType get type => MoQMessageType.trackStatusError;

  @override
  int get payloadLength {
    int len = 0;
    len += MoQWireFormat._varintSize64(requestId);
    len += MoQWireFormat._varintSize(errorCode);
    final reasonBytes = const Utf8Encoder().convert(errorReason.reason);
    len += MoQWireFormat._varintSize(reasonBytes.length) + reasonBytes.length;
    return len;
  }

  @override
  Uint8List serialize() {
    final reasonBytes = const Utf8Encoder().convert(errorReason.reason);
    final payload = Uint8List(payloadLength);
    int offset = 0;

    offset += _writeVarint64(payload, offset, requestId);
    offset += _writeVarint(payload, offset, errorCode);
    offset += _writeVarint(payload, offset, reasonBytes.length);
    payload.setAll(offset, reasonBytes);

    return _wrapMessage(payload);
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

  Uint8List _wrapMessage(Uint8List payload) {
    final typeBytes = MoQWireFormat.encodeVarint(type.value);
    final buffer = Uint8List(typeBytes.length + 2 + payload.length);
    int offset = 0;

    buffer.setAll(offset, typeBytes);
    offset += typeBytes.length;

    buffer[offset++] = (payload.length >> 8) & 0xFF;
    buffer[offset++] = payload.length & 0xFF;

    buffer.setAll(offset, payload);

    return buffer;
  }

  static TrackStatusErrorMessage deserialize(Uint8List data) {
    int offset = 0;

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    final (errorCode, len2) = MoQWireFormat.decodeVarint(data, offset);
    offset += len2;

    final (reasonLen, len3) = MoQWireFormat.decodeVarint(data, offset);
    offset += len3;

    final reasonBytes = data.sublist(offset, offset + reasonLen);
    final reason = const Utf8Decoder().convert(reasonBytes);

    return TrackStatusErrorMessage(
      requestId: requestId,
      errorCode: errorCode,
      errorReason: ReasonPhrase(reason),
    );
  }
}

/// SUBSCRIBE_NAMESPACE message (0x11) per draft-ietf-moq-transport-14
///
/// The subscriber sends SUBSCRIBE_NAMESPACE to request the current set of
/// matching published namespaces and established subscriptions, as well as
/// future updates to the set.
class SubscribeNamespaceMessage extends MoQControlMessage {
  final Int64 requestId;
  final List<Uint8List> trackNamespacePrefix;
  final List<KeyValuePair> parameters;

  SubscribeNamespaceMessage({
    required this.requestId,
    required this.trackNamespacePrefix,
    this.parameters = const [],
  });

  @override
  MoQMessageType get type => MoQMessageType.subscribeNamespace;

  @override
  int get payloadLength {
    int len = 0;
    len += MoQWireFormat._varintSize64(requestId);
    len += MoQWireFormat._tupleSize(trackNamespacePrefix);
    len += MoQWireFormat._varintSize(parameters.length);
    for (final param in parameters) {
      len += MoQWireFormat._varintSize(param.type);
      final valueLen = param.value?.length ?? 0;
      len += MoQWireFormat._varintSize(valueLen);
      len += valueLen;
    }
    return len;
  }

  @override
  Uint8List serialize() {
    final payload = Uint8List(payloadLength);
    int offset = 0;

    offset += _writeVarint64(payload, offset, requestId);
    offset += _writeTuple(payload, offset, trackNamespacePrefix);
    offset += _writeVarint(payload, offset, parameters.length);

    for (final param in parameters) {
      offset += _writeVarint(payload, offset, param.type);
      final valueLen = param.value?.length ?? 0;
      offset += _writeVarint(payload, offset, valueLen);
      if (valueLen > 0) {
        payload.setAll(offset, param.value!);
        offset += valueLen;
      }
    }

    return _wrapMessage(payload);
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

  int _writeTuple(Uint8List buffer, int offset, List<Uint8List> tuple) {
    final bytes = MoQWireFormat.encodeTuple(tuple);
    buffer.setAll(offset, bytes);
    return bytes.length;
  }

  Uint8List _wrapMessage(Uint8List payload) {
    final typeBytes = MoQWireFormat.encodeVarint(type.value);
    final buffer = Uint8List(typeBytes.length + 2 + payload.length);
    int offset = 0;

    buffer.setAll(offset, typeBytes);
    offset += typeBytes.length;

    buffer[offset++] = (payload.length >> 8) & 0xFF;
    buffer[offset++] = payload.length & 0xFF;

    buffer.setAll(offset, payload);

    return buffer;
  }

  static SubscribeNamespaceMessage deserialize(Uint8List data) {
    int offset = 0;

    final (requestId, reqLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += reqLen;

    final (namespacePrefix, tupleLen) = MoQWireFormat.decodeTuple(data, offset);
    offset += tupleLen;

    final (numParams, numParamsLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += numParamsLen;

    final params = <KeyValuePair>[];
    for (int i = 0; i < numParams && offset < data.length; i++) {
      final (paramType, typeLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += typeLen;

      final (valueLen, valueLenLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += valueLenLen;

      Uint8List? value;
      if (valueLen > 0 && offset + valueLen <= data.length) {
        value = data.sublist(offset, offset + valueLen);
        offset += valueLen;
      }
      params.add(KeyValuePair(type: paramType, value: value));
    }

    return SubscribeNamespaceMessage(
      requestId: requestId,
      trackNamespacePrefix: namespacePrefix,
      parameters: params,
    );
  }

  /// Get namespace prefix as a string path
  String get namespacePrefixPath {
    return trackNamespacePrefix
        .map((e) => const Utf8Decoder().convert(e))
        .join('/');
  }
}

/// SUBSCRIBE_NAMESPACE_OK message (0x12) per draft-ietf-moq-transport-14
///
/// The publisher sends SUBSCRIBE_NAMESPACE_OK to confirm a namespace subscription.
class SubscribeNamespaceOkMessage extends MoQControlMessage {
  final Int64 requestId;

  SubscribeNamespaceOkMessage({
    required this.requestId,
  });

  @override
  MoQMessageType get type => MoQMessageType.subscribeNamespaceOk;

  @override
  int get payloadLength {
    return MoQWireFormat._varintSize64(requestId);
  }

  @override
  Uint8List serialize() {
    final payload = Uint8List(payloadLength);
    int offset = 0;

    final reqIdBytes = MoQWireFormat.encodeVarint64(requestId);
    payload.setAll(offset, reqIdBytes);

    return _wrapMessage(payload);
  }

  Uint8List _wrapMessage(Uint8List payload) {
    final typeBytes = MoQWireFormat.encodeVarint(type.value);
    final buffer = Uint8List(typeBytes.length + 2 + payload.length);
    int offset = 0;

    buffer.setAll(offset, typeBytes);
    offset += typeBytes.length;

    buffer[offset++] = (payload.length >> 8) & 0xFF;
    buffer[offset++] = payload.length & 0xFF;

    buffer.setAll(offset, payload);

    return buffer;
  }

  static SubscribeNamespaceOkMessage deserialize(Uint8List data) {
    int offset = 0;

    final (requestId, _) = MoQWireFormat.decodeVarint64(data, offset);

    return SubscribeNamespaceOkMessage(requestId: requestId);
  }
}

/// SUBSCRIBE_NAMESPACE_ERROR message (0x13) per draft-ietf-moq-transport-14
///
/// The publisher sends SUBSCRIBE_NAMESPACE_ERROR to reject a namespace subscription.
class SubscribeNamespaceErrorMessage extends MoQControlMessage {
  final Int64 requestId;
  final int errorCode;
  final ReasonPhrase errorReason;

  SubscribeNamespaceErrorMessage({
    required this.requestId,
    required this.errorCode,
    required this.errorReason,
  });

  @override
  MoQMessageType get type => MoQMessageType.subscribeNamespaceError;

  @override
  int get payloadLength {
    final reasonBytes = const Utf8Encoder().convert(errorReason.reason);
    int len = 0;
    len += MoQWireFormat._varintSize64(requestId);
    len += MoQWireFormat._varintSize(errorCode);
    len += MoQWireFormat._varintSize(reasonBytes.length) + reasonBytes.length;
    return len;
  }

  @override
  Uint8List serialize() {
    final reasonBytes = const Utf8Encoder().convert(errorReason.reason);
    final payload = Uint8List(payloadLength);
    int offset = 0;

    offset += _writeVarint64(payload, offset, requestId);
    offset += _writeVarint(payload, offset, errorCode);
    offset += _writeVarint(payload, offset, reasonBytes.length);
    payload.setAll(offset, reasonBytes);

    return _wrapMessage(payload);
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

  Uint8List _wrapMessage(Uint8List payload) {
    final typeBytes = MoQWireFormat.encodeVarint(type.value);
    final buffer = Uint8List(typeBytes.length + 2 + payload.length);
    int offset = 0;

    buffer.setAll(offset, typeBytes);
    offset += typeBytes.length;

    buffer[offset++] = (payload.length >> 8) & 0xFF;
    buffer[offset++] = payload.length & 0xFF;

    buffer.setAll(offset, payload);

    return buffer;
  }

  static SubscribeNamespaceErrorMessage deserialize(Uint8List data) {
    int offset = 0;

    final (requestId, reqLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += reqLen;

    final (errorCode, errLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += errLen;

    final (reasonLen, reasonLenLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += reasonLenLen;

    final reasonBytes = data.sublist(offset, offset + reasonLen);
    final reason = const Utf8Decoder().convert(reasonBytes);

    return SubscribeNamespaceErrorMessage(
      requestId: requestId,
      errorCode: errorCode,
      errorReason: ReasonPhrase(reason),
    );
  }
}

/// UNSUBSCRIBE_NAMESPACE message (0x14) per draft-ietf-moq-transport-14
///
/// The subscriber sends UNSUBSCRIBE_NAMESPACE to end a namespace subscription.
class UnsubscribeNamespaceMessage extends MoQControlMessage {
  final List<Uint8List> trackNamespacePrefix;

  UnsubscribeNamespaceMessage({
    required this.trackNamespacePrefix,
  });

  @override
  MoQMessageType get type => MoQMessageType.unsubscribeNamespace;

  @override
  int get payloadLength {
    return MoQWireFormat._tupleSize(trackNamespacePrefix);
  }

  @override
  Uint8List serialize() {
    final payload = Uint8List(payloadLength);
    int offset = 0;

    final tupleBytes = MoQWireFormat.encodeTuple(trackNamespacePrefix);
    payload.setAll(offset, tupleBytes);

    return _wrapMessage(payload);
  }

  Uint8List _wrapMessage(Uint8List payload) {
    final typeBytes = MoQWireFormat.encodeVarint(type.value);
    final buffer = Uint8List(typeBytes.length + 2 + payload.length);
    int offset = 0;

    buffer.setAll(offset, typeBytes);
    offset += typeBytes.length;

    buffer[offset++] = (payload.length >> 8) & 0xFF;
    buffer[offset++] = payload.length & 0xFF;

    buffer.setAll(offset, payload);

    return buffer;
  }

  static UnsubscribeNamespaceMessage deserialize(Uint8List data) {
    int offset = 0;

    final (namespacePrefix, _) = MoQWireFormat.decodeTuple(data, offset);

    return UnsubscribeNamespaceMessage(trackNamespacePrefix: namespacePrefix);
  }

  /// Get namespace prefix as a string path
  String get namespacePrefixPath {
    return trackNamespacePrefix
        .map((e) => const Utf8Decoder().convert(e))
        .join('/');
  }
}
