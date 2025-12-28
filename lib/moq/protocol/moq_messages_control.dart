part of 'moq_messages.dart';

/// Base class for all MoQ control messages
abstract class MoQControlMessage {
  MoQMessageType get type;

  /// Serialize the message to bytes
  Uint8List serialize();

  /// Get the message payload length (excluding type and length fields)
  int get payloadLength;
}

/// CLIENT_SETUP message (0x20)
///
/// Wire format:
/// CLIENT_SETUP Message {
///   Type (i) = 0x20,
///   Length (16),
///   Number of Supported Versions (i),
///   Supported Versions (i) ...,
///   Number of Parameters (i),
///   Setup Parameters (..) ...,
/// }
class ClientSetupMessage extends MoQControlMessage {
  final List<int> supportedVersions;
  final List<KeyValuePair> parameters;

  ClientSetupMessage({
    required this.supportedVersions,
    this.parameters = const [],
  });

  @override
  MoQMessageType get type => MoQMessageType.clientSetup;

  @override
  int get payloadLength {
    int len = 0;
    // Number of versions
    len += MoQWireFormat._varintSize(supportedVersions.length);
    // Each version (varint)
    for (final version in supportedVersions) {
      len += MoQWireFormat._varintSize(version);
    }
    // Number of parameters
    len += MoQWireFormat._varintSize(parameters.length);
    // Each parameter
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

    // Write number of versions
    offset += _writeVarint(payload, offset, supportedVersions.length);

    // Write versions
    for (final version in supportedVersions) {
      offset += _writeVarint(payload, offset, version);
    }

    // Write number of parameters
    offset += _writeVarint(payload, offset, parameters.length);

    // Write parameters
    for (final param in parameters) {
      offset += _writeVarint(payload, offset, param.type);
      if (param.value != null) {
        offset += _writeVarint(payload, offset, param.value!.length);
        payload.setAll(offset, param.value!);
        offset += param.value!.length;
      }
    }

    // Wrap with type and length
    return _wrapMessage(payload);
  }

  /// Deserialize a CLIENT_SETUP message
  static ClientSetupMessage deserialize(Uint8List data) {
    int offset = 0;

    // Read number of versions
    final (numVersions, versionsLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += versionsLen;

    // Read versions
    final versions = <int>[];
    for (int i = 0; i < numVersions; i++) {
      final (version, len) = MoQWireFormat.decodeVarint(data, offset);
      offset += len;
      versions.add(version);
    }

    // Read number of parameters
    final (numParams, paramsLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += paramsLen;

    // Read parameters
    final params = <KeyValuePair>[];
    for (int i = 0; i < numParams; i++) {
      final (type, typeLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += typeLen;

      Uint8List? value;
      // Check if there's a value (length varint + data)
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

    return ClientSetupMessage(
      supportedVersions: versions,
      parameters: params,
    );
  }

  /// Write varint to buffer at offset, return bytes written
  int _writeVarint(Uint8List buffer, int offset, int value) {
    final bytes = MoQWireFormat.encodeVarint(value);
    buffer.setAll(offset, bytes);
    return bytes.length;
  }

  /// Wrap payload with type and length
  Uint8List _wrapMessage(Uint8List payload) {
    final typeBytes = MoQWireFormat.encodeVarint(type.value);
    final buffer = Uint8List(typeBytes.length + 2 + payload.length);
    int offset = 0;

    // Type
    buffer.setAll(offset, typeBytes);
    offset += typeBytes.length;

    // Length (16-bit big endian)
    buffer[offset++] = (payload.length >> 8) & 0xFF;
    buffer[offset++] = payload.length & 0xFF;

    // Payload
    buffer.setAll(offset, payload);

    return buffer;
  }
}

/// SERVER_SETUP message (0x21)
///
/// Wire format:
/// SERVER_SETUP Message {
///   Type (i) = 0x21,
///   Length (16),
///   Selected Version (i),
///   Number of Parameters (i),
///   Setup Parameters (..) ...,
/// }
class ServerSetupMessage extends MoQControlMessage {
  final int selectedVersion;
  final List<KeyValuePair> parameters;

  ServerSetupMessage({
    required this.selectedVersion,
    this.parameters = const [],
  });

  @override
  MoQMessageType get type => MoQMessageType.serverSetup;

  @override
  int get payloadLength {
    int len = MoQWireFormat._varintSize(selectedVersion);
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

    // Write selected version
    offset += _writeVarint(payload, offset, selectedVersion);

    // Write number of parameters
    offset += _writeVarint(payload, offset, parameters.length);

    // Write parameters
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

  /// Deserialize a SERVER_SETUP message
  static ServerSetupMessage deserialize(Uint8List data) {
    int offset = 0;

    // Read selected version
    final (version, versionLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += versionLen;

    // Read number of parameters
    final (numParams, paramsLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += paramsLen;

    // Read parameters
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

    return ServerSetupMessage(
      selectedVersion: version,
      parameters: params,
    );
  }

  int _writeVarint(Uint8List buffer, int offset, int value) {
    final bytes = MoQWireFormat.encodeVarint(value);
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
}

/// SUBSCRIBE message (0x3)
///
/// Wire format:
/// SUBSCRIBE Message {
///   Type (i) = 0x3,
///   Length (16),
///   Request ID (i),
///   Track Namespace (tuple),
///   Track Name Length (i),
///   Track Name (..),
///   Subscriber Priority (8),
///   Group Order (8),
///   Forward (8),
///   Filter Type (i),
///   [Start Location (Location),]
///   [End Group (i),]
///   Number of Parameters (i),
///   Parameters (..) ...
/// }
class SubscribeMessage extends MoQControlMessage {
  final Int64 requestId;
  final List<Uint8List> trackNamespace;
  final Uint8List trackName;
  final int subscriberPriority;
  final GroupOrder groupOrder;
  final int forward; // 0 or 1
  final FilterType filterType;
  final Location? startLocation;
  final Int64? endGroup;
  final List<KeyValuePair> parameters;

  SubscribeMessage({
    required this.requestId,
    required this.trackNamespace,
    required this.trackName,
    required this.subscriberPriority,
    required this.groupOrder,
    required this.forward,
    required this.filterType,
    this.startLocation,
    this.endGroup,
    this.parameters = const [],
  });

  @override
  MoQMessageType get type => MoQMessageType.subscribe;

  @override
  int get payloadLength {
    int len = 0;
    // Request ID (varint)
    len += MoQWireFormat._varintSize64(requestId);
    // Track Namespace (tuple)
    len += _tupleSize(trackNamespace);
    // Track Name length (varint) + Track Name
    len += MoQWireFormat._varintSize(trackName.length) + trackName.length;
    // Subscriber Priority (1 byte)
    len += 1;
    // Group Order (1 byte)
    len += 1;
    // Forward (1 byte)
    len += 1;
    // Filter Type (varint)
    len += MoQWireFormat._varintSize(filterType.value);
    // Start Location (if present)
    if (filterType == FilterType.absoluteStart ||
        filterType == FilterType.absoluteRange) {
      len += _locationSize();
    }
    // End Group (varint, if present)
    if (filterType == FilterType.absoluteRange && endGroup != null) {
      len += MoQWireFormat._varintSize64(endGroup!);
    }
    // Number of parameters
    len += MoQWireFormat._varintSize(parameters.length);
    // Parameters
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

  int _locationSize() {
    // Location is two varints (group, object)
    int len = MoQWireFormat._varintSize64(startLocation?.group ?? Int64(0));
    len += MoQWireFormat._varintSize64(startLocation?.object ?? Int64(0));
    return len;
  }

  @override
  Uint8List serialize() {
    final payload = Uint8List(payloadLength);
    int offset = 0;

    // Request ID
    offset += _writeVarint64(payload, offset, requestId);

    // Track Namespace (tuple)
    offset += _writeTuple(payload, offset, trackNamespace);

    // Track Name
    offset += _writeVarint(payload, offset, trackName.length);
    payload.setAll(offset, trackName);
    offset += trackName.length;

    // Subscriber Priority
    payload[offset++] = subscriberPriority;

    // Group Order
    payload[offset++] = groupOrder.value;

    // Forward
    payload[offset++] = forward;

    // Filter Type
    offset += _writeVarint(payload, offset, filterType.value);

    // Start Location (if present)
    if (filterType == FilterType.absoluteStart ||
        filterType == FilterType.absoluteRange) {
      if (startLocation != null) {
        offset += _writeLocation(payload, offset, startLocation!);
      } else {
        // Write default location {0, 0}
        offset += _writeLocation(payload, offset, Location.zero());
      }
    }

    // End Group (if present)
    if (filterType == FilterType.absoluteRange && endGroup != null) {
      offset += _writeVarint64(payload, offset, endGroup!);
    }

    // Number of parameters
    offset += _writeVarint(payload, offset, parameters.length);

    // Parameters
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

  /// Deserialize a SUBSCRIBE message
  static SubscribeMessage deserialize(Uint8List data) {
    int offset = 0;

    // Request ID
    final (requestId, requestIdLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += requestIdLen;

    // Track Namespace (tuple)
    final (namespace, namespaceLen) = MoQWireFormat.decodeTuple(data, offset);
    offset += namespaceLen;

    // Track Name length
    final (nameLen, nameLenLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += nameLenLen;

    // Track Name
    final trackName = data.sublist(offset, offset + nameLen);
    offset += nameLen;

    // Subscriber Priority
    final subscriberPriority = data[offset++];

    // Group Order
    final groupOrder = GroupOrder.fromValue(data[offset++]) ?? GroupOrder.none;

    // Forward
    final forward = data[offset++];

    // Filter Type
    final (filterTypeValue, filterTypeLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += filterTypeLen;
    final filterType = FilterType.fromValue(filterTypeValue) ?? FilterType.largestObject;

    // Start Location (if present)
    Location? startLocation;
    if (filterType == FilterType.absoluteStart ||
        filterType == FilterType.absoluteRange) {
      final (location, locLen) = MoQWireFormat.decodeLocation(data, offset);
      offset += locLen;
      startLocation = location;
    }

    // End Group (if present)
    Int64? endGroup;
    if (filterType == FilterType.absoluteRange) {
      final (eg, egLen) = MoQWireFormat.decodeVarint64(data, offset);
      offset += egLen;
      endGroup = eg;
    }

    // Number of parameters
    final (numParams, numParamsLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += numParamsLen;

    // Parameters
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

    return SubscribeMessage(
      requestId: requestId,
      trackNamespace: namespace,
      trackName: trackName,
      subscriberPriority: subscriberPriority,
      groupOrder: groupOrder,
      forward: forward,
      filterType: filterType,
      startLocation: startLocation,
      endGroup: endGroup,
      parameters: params,
    );
  }
}

/// SUBSCRIBE_OK message (0x4)
///
/// Wire format:
/// SUBSCRIBE_OK Message {
///   Type (i) = 0x4,
///   Length (16),
///   Request ID (i),
///   Track Alias (i),
///   Expires (i),
///   Group Order (8),
///   Content Exists (8),
///   [Largest Location (Location),]
///   Number of Parameters (i),
///   Parameters (..) ...
/// }
class SubscribeOkMessage extends MoQControlMessage {
  final Int64 requestId;
  final Int64 trackAlias;
  final Int64 expires;
  final GroupOrder groupOrder;
  final int contentExists;
  final Location? largestLocation;
  final List<KeyValuePair> parameters;

  SubscribeOkMessage({
    required this.requestId,
    required this.trackAlias,
    required this.expires,
    required this.groupOrder,
    required this.contentExists,
    this.largestLocation,
    this.parameters = const [],
  });

  @override
  MoQMessageType get type => MoQMessageType.subscribeOk;

  @override
  int get payloadLength {
    int len = 0;
    len += MoQWireFormat._varintSize64(requestId);
    len += MoQWireFormat._varintSize64(trackAlias);
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
    offset += _writeVarint64(payload, offset, trackAlias);
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

  /// Deserialize a SUBSCRIBE_OK message
  static SubscribeOkMessage deserialize(Uint8List data) {
    int offset = 0;

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    final (trackAlias, len2) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len2;

    final (expires, len3) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len3;

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

    return SubscribeOkMessage(
      requestId: requestId,
      trackAlias: trackAlias,
      expires: expires,
      groupOrder: groupOrder,
      contentExists: contentExists,
      largestLocation: largestLocation,
      parameters: params,
    );
  }
}

/// SUBSCRIBE_ERROR message (0x5)
///
/// Wire format:
/// SUBSCRIBE_ERROR Message {
///   Type (i) = 0x5,
///   Length (16),
///   Request ID (i),
///   Error Code (i),
///   Error Reason (Reason Phrase)
/// }
class SubscribeErrorMessage extends MoQControlMessage {
  final Int64 requestId;
  final int errorCode;
  final ReasonPhrase errorReason;

  SubscribeErrorMessage({
    required this.requestId,
    required this.errorCode,
    required this.errorReason,
  });

  @override
  MoQMessageType get type => MoQMessageType.subscribeError;

  @override
  int get payloadLength {
    int len = MoQWireFormat._varintSize64(requestId);
    len += MoQWireFormat._varintSize(errorCode);
    // Reason Phrase: varint length + UTF-8 bytes
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

  /// Deserialize a SUBSCRIBE_ERROR message
  static SubscribeErrorMessage deserialize(Uint8List data) {
    int offset = 0;

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    final (errorCode, len2) = MoQWireFormat.decodeVarint(data, offset);
    offset += len2;

    final (reasonLen, len3) = MoQWireFormat.decodeVarint(data, offset);
    offset += len3;

    final reasonBytes = data.sublist(offset, offset + reasonLen);
    final reason = const Utf8Decoder().convert(reasonBytes);

    return SubscribeErrorMessage(
      requestId: requestId,
      errorCode: errorCode,
      errorReason: ReasonPhrase(reason),
    );
  }
}

/// SUBSCRIBE_UPDATE message (0x2)
///
/// Wire format:
/// SUBSCRIBE_UPDATE Message {
///   Type (i) = 0x2,
///   Length (16),
///   Request ID (i),
///   Subscription Request ID (i),
///   Start Location (Location),
///   End Group (i),
///   Subscriber Priority (8),
///   Forward (8),
///   Number of Parameters (i),
///   Parameters (..) ...
/// }
class SubscribeUpdateMessage extends MoQControlMessage {
  final Int64 requestId;
  final Int64 subscriptionRequestId;
  final Location startLocation;
  final Int64 endGroup;
  final int subscriberPriority;
  final int forward;
  final List<KeyValuePair> parameters;

  SubscribeUpdateMessage({
    required this.requestId,
    required this.subscriptionRequestId,
    required this.startLocation,
    required this.endGroup,
    required this.subscriberPriority,
    required this.forward,
    this.parameters = const [],
  });

  @override
  MoQMessageType get type => MoQMessageType.subscribeUpdate;

  @override
  int get payloadLength {
    int len = 0;
    len += MoQWireFormat._varintSize64(requestId);
    len += MoQWireFormat._varintSize64(subscriptionRequestId);
    len += _locationSize();
    len += MoQWireFormat._varintSize64(endGroup);
    len += 1; // Subscriber Priority
    len += 1; // Forward
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
    int len = MoQWireFormat._varintSize64(startLocation.group);
    len += MoQWireFormat._varintSize64(startLocation.object);
    return len;
  }

  @override
  Uint8List serialize() {
    final payload = Uint8List(payloadLength);
    int offset = 0;

    offset += _writeVarint64(payload, offset, requestId);
    offset += _writeVarint64(payload, offset, subscriptionRequestId);
    offset += _writeLocation(payload, offset, startLocation);
    offset += _writeVarint64(payload, offset, endGroup);
    payload[offset++] = subscriberPriority;
    payload[offset++] = forward;
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

  /// Deserialize a SUBSCRIBE_UPDATE message
  static SubscribeUpdateMessage deserialize(Uint8List data) {
    int offset = 0;

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    final (subRequestId, len2) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len2;

    final (startLoc, len3) = MoQWireFormat.decodeLocation(data, offset);
    offset += len3;

    final (endGroup, len4) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len4;

    final subscriberPriority = data[offset++];
    final forward = data[offset++];

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

    return SubscribeUpdateMessage(
      requestId: requestId,
      subscriptionRequestId: subRequestId,
      startLocation: startLoc,
      endGroup: endGroup,
      subscriberPriority: subscriberPriority,
      forward: forward,
      parameters: params,
    );
  }
}

/// UNSUBSCRIBE message (0xA)
///
/// Wire format:
/// UNSUBSCRIBE Message {
///   Type (i) = 0xA,
///   Length (16),
///   Request ID (i)
/// }
class UnsubscribeMessage extends MoQControlMessage {
  final Int64 requestId;

  UnsubscribeMessage({
    required this.requestId,
  });

  @override
  MoQMessageType get type => MoQMessageType.unsubscribe;

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

  /// Deserialize an UNSUBSCRIBE message
  static UnsubscribeMessage deserialize(Uint8List data) {
    final (requestId, _) = MoQWireFormat.decodeVarint64(data, 0);
    return UnsubscribeMessage(requestId: requestId);
  }
}

/// GOAWAY message (0x10)
///
/// Wire format:
/// GOAWAY Message {
///   Type (i) = 0x10,
///   Length (16),
///   [Last Request ID (i),]
///   [New URI (..)]
/// }
class GoawayMessage extends MoQControlMessage {
  final Int64? lastRequestId;
  final String? newUri;

  GoawayMessage({
    this.lastRequestId,
    this.newUri,
  });

  @override
  MoQMessageType get type => MoQMessageType.goaway;

  @override
  int get payloadLength {
    int len = 0;
    if (lastRequestId != null) {
      len += MoQWireFormat._varintSize64(lastRequestId!);
    }
    if (newUri != null) {
      final uriBytes = const Utf8Encoder().convert(newUri!);
      len += MoQWireFormat._varintSize(uriBytes.length) + uriBytes.length;
    }
    return len;
  }

  @override
  Uint8List serialize() {
    final payload = Uint8List(payloadLength);
    int offset = 0;

    if (lastRequestId != null) {
      offset += _writeVarint64(payload, offset, lastRequestId!);
    }

    if (newUri != null) {
      final uriBytes = const Utf8Encoder().convert(newUri!);
      offset += _writeVarint(payload, offset, uriBytes.length);
      payload.setAll(offset, uriBytes);
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

  /// Deserialize a GOAWAY message
  static GoawayMessage deserialize(Uint8List data) {
    int offset = 0;
    Int64? lastRequestId;
    String? newUri;

    if (data.isNotEmpty) {
      // Try to read Last Request ID (might be present or not)
      // This is tricky - we need to determine if there's more data
      // For now, assume it's present if data is not empty
      final (reqId, reqIdLen) = MoQWireFormat.decodeVarint64(data, offset);
      offset += reqIdLen;

      if (offset < data.length) {
        lastRequestId = reqId;
        // Try to read New URI
        final (uriLen, uriLenLen) = MoQWireFormat.decodeVarint(data, offset);
        offset += uriLenLen;
        if (uriLen > 0 && offset + uriLen <= data.length) {
          final uriBytes = data.sublist(offset, offset + uriLen);
          newUri = const Utf8Decoder().convert(uriBytes);
        }
      } else {
        lastRequestId = reqId;
      }
    }

    return GoawayMessage(
      lastRequestId: lastRequestId,
      newUri: newUri,
    );
  }
}

/// PUBLISH_DONE message (0xB)
///
/// Wire format:
/// PUBLISH_DONE Message {
///   Type (i) = 0xB,
///   Length (16),
///   Request ID (i),
///   Status Code (i),
///   Stream Count (i),
///   [Error Reason (Reason Phrase)]
/// }
class PublishDoneMessage extends MoQControlMessage {
  final Int64 requestId;
  final int statusCode;
  final Int64 streamCount;
  final ReasonPhrase? errorReason;

  PublishDoneMessage({
    required this.requestId,
    required this.statusCode,
    required this.streamCount,
    this.errorReason,
  });

  @override
  MoQMessageType get type => MoQMessageType.publishDone;

  @override
  int get payloadLength {
    int len = 0;
    len += MoQWireFormat._varintSize64(requestId);
    len += MoQWireFormat._varintSize(statusCode);
    len += MoQWireFormat._varintSize64(streamCount);
    if (errorReason != null) {
      final reasonBytes = const Utf8Encoder().convert(errorReason!.reason);
      len += MoQWireFormat._varintSize(reasonBytes.length) + reasonBytes.length;
    }
    return len;
  }

  @override
  Uint8List serialize() {
    final payload = Uint8List(payloadLength);
    int offset = 0;

    offset += _writeVarint64(payload, offset, requestId);
    offset += _writeVarint(payload, offset, statusCode);
    offset += _writeVarint64(payload, offset, streamCount);

    if (errorReason != null) {
      final reasonBytes = const Utf8Encoder().convert(errorReason!.reason);
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

  /// Deserialize a PUBLISH_DONE message
  static PublishDoneMessage deserialize(Uint8List data) {
    int offset = 0;

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    final (statusCode, len2) = MoQWireFormat.decodeVarint(data, offset);
    offset += len2;

    final (streamCount, len3) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len3;

    ReasonPhrase? errorReason;
    if (offset < data.length) {
      final (reasonLen, len4) = MoQWireFormat.decodeVarint(data, offset);
      offset += len4;
      if (reasonLen > 0 && offset + reasonLen <= data.length) {
        final reasonBytes = data.sublist(offset, offset + reasonLen);
        final reason = const Utf8Decoder().convert(reasonBytes);
        errorReason = ReasonPhrase(reason);
      }
    }

    return PublishDoneMessage(
      requestId: requestId,
      statusCode: statusCode,
      streamCount: streamCount,
      errorReason: errorReason,
    );
  }
}
