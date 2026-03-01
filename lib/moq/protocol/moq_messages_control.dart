part of 'moq_messages.dart';

/// Base class for all MoQ control messages
abstract class MoQControlMessage {
  MoQMessageType get type;

  /// Serialize the message to bytes.
  /// [version] selects the wire format (default draft-14).
  Uint8List serialize({int version = MoQVersion.draft14});

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
  int get payloadLength => _payloadLength(MoQVersion.draft14);

  int _payloadLength(int version) {
    int len = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    if (!MoQVersion.isDraft16OrLater(version)) {
      // Draft-14: version list
      len += MoQWireFormat._varintSize(supportedVersions.length);
      for (final v in supportedVersions) {
        len += MoQWireFormat._varintSize(v);
      }
    }

    // Parameters (uses KVP encoding helper for size calc)
    len += MoQWireFormat._varintSize(parameters.length);
    int lastType = 0;
    for (final param in parameters) {
      final typeToWrite = useDelta ? (param.type - lastType) : param.type;
      len += MoQWireFormat._varintSize(typeToWrite);
      if (param.isVarintType) {
        len += MoQWireFormat._varintSize(param.intValue ?? 0);
      } else if (param.value != null) {
        len += MoQWireFormat._varintSize(param.value!.length) + param.value!.length;
      }
      if (useDelta) lastType = param.type;
    }
    return len;
  }

  @override
  Uint8List serialize({int version = MoQVersion.draft14}) {
    final payload = Uint8List(_payloadLength(version));
    int offset = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    if (!MoQVersion.isDraft16OrLater(version)) {
      // Draft-14: write version list
      offset += _writeVarint(payload, offset, supportedVersions.length);
      for (final v in supportedVersions) {
        offset += _writeVarint(payload, offset, v);
      }
    }

    // Write parameters
    offset += _writeVarint(payload, offset, parameters.length);
    int lastType = 0;
    for (final param in parameters) {
      final typeToWrite = useDelta ? (param.type - lastType) : param.type;
      offset += _writeVarint(payload, offset, typeToWrite);
      if (param.isVarintType) {
        offset += _writeVarint(payload, offset, param.intValue ?? 0);
      } else if (param.value != null) {
        offset += _writeVarint(payload, offset, param.value!.length);
        payload.setAll(offset, param.value!);
        offset += param.value!.length;
      }
      if (useDelta) lastType = param.type;
    }

    return _wrapMessage(payload);
  }

  /// Deserialize a CLIENT_SETUP message
  static ClientSetupMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
    int offset = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    // Draft-14: read version list; draft-16: version comes from ALPN
    final versions = <int>[];
    if (!MoQVersion.isDraft16OrLater(version)) {
      final (numVersions, versionsLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += versionsLen;
      for (int i = 0; i < numVersions; i++) {
        final (v, len) = MoQWireFormat.decodeVarint(data, offset);
        offset += len;
        versions.add(v);
      }
    }

    // Read parameters
    final (numParams, paramsLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += paramsLen;

    final (params, paramsRead) =
        MoQWireFormat.decodeKeyValuePairs(data, offset, numParams, useDelta: useDelta);
    offset += paramsRead;

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
  int get payloadLength => _payloadLength(MoQVersion.draft14);

  int _payloadLength(int version) {
    int len = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    if (!MoQVersion.isDraft16OrLater(version)) {
      // Draft-14: selected version field
      len += MoQWireFormat._varintSize(selectedVersion);
    }

    len += MoQWireFormat._varintSize(parameters.length);
    int lastType = 0;
    for (final param in parameters) {
      final typeToWrite = useDelta ? (param.type - lastType) : param.type;
      len += MoQWireFormat._varintSize(typeToWrite);
      if (param.isVarintType) {
        len += MoQWireFormat._varintSize(param.intValue ?? 0);
      } else if (param.value != null) {
        len += MoQWireFormat._varintSize(param.value!.length) + param.value!.length;
      }
      if (useDelta) lastType = param.type;
    }
    return len;
  }

  @override
  Uint8List serialize({int version = MoQVersion.draft14}) {
    final payload = Uint8List(_payloadLength(version));
    int offset = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    if (!MoQVersion.isDraft16OrLater(version)) {
      // Draft-14: write selected version
      offset += _writeVarint(payload, offset, selectedVersion);
    }

    // Write parameters
    offset += _writeVarint(payload, offset, parameters.length);
    int lastType = 0;
    for (final param in parameters) {
      final typeToWrite = useDelta ? (param.type - lastType) : param.type;
      offset += _writeVarint(payload, offset, typeToWrite);
      if (param.isVarintType) {
        offset += _writeVarint(payload, offset, param.intValue ?? 0);
      } else if (param.value != null) {
        offset += _writeVarint(payload, offset, param.value!.length);
        payload.setAll(offset, param.value!);
        offset += param.value!.length;
      }
      if (useDelta) lastType = param.type;
    }

    return _wrapMessage(payload);
  }

  /// Deserialize a SERVER_SETUP message
  static ServerSetupMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
    int offset = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    // Draft-14: read selected version; draft-16: already known from ALPN
    int selectedVer = version; // default to the negotiated version
    if (!MoQVersion.isDraft16OrLater(version)) {
      final (sv, versionLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += versionLen;
      selectedVer = sv;
    }

    // Read parameters
    final (numParams, paramsLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += paramsLen;

    final (params, paramsRead) =
        MoQWireFormat.decodeKeyValuePairs(data, offset, numParams, useDelta: useDelta);
    offset += paramsRead;

    return ServerSetupMessage(
      selectedVersion: selectedVer,
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
  int get payloadLength => _payloadLength(MoQVersion.draft14);

  int _payloadLength(int version) {
    int len = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    // Request ID (varint)
    len += MoQWireFormat._varintSize64(requestId);
    // Track Namespace (tuple)
    len += _tupleSize(trackNamespace);
    // Track Name length (varint) + Track Name
    len += MoQWireFormat._varintSize(trackName.length) + trackName.length;

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: inline fields moved to params
      final allParams = _buildDraft16Params();
      final kvpBytes = MoQWireFormat.encodeKeyValuePairs(allParams, useDelta: useDelta);
      len += kvpBytes.length;
    } else {
      // Draft-14: inline fields
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
    }
    return len;
  }

  /// Build the combined parameter list for draft-16 serialization.
  /// Inline fields (priority, group order, forward, filter) become params.
  List<KeyValuePair> _buildDraft16Params() {
    final allParams = <KeyValuePair>[
      // forward (0x10, even) -> varint
      KeyValuePair.varint(SubscribeParameterType.forward, forward),
      // subscriberPriority (0x20, even) -> varint
      KeyValuePair.varint(SubscribeParameterType.subscriberPriority, subscriberPriority),
      // subscriptionFilter (0x21, odd) -> buffer: FilterType [+ StartLocation] [+ EndGroup]
      KeyValuePair.buffer(SubscribeParameterType.subscriptionFilter, _encodeFilterParam()),
      // groupOrder (0x22, even) -> varint
      KeyValuePair.varint(SubscribeParameterType.groupOrder, groupOrder.value),
    ];
    // Append any user-supplied parameters
    allParams.addAll(parameters);
    return allParams;
  }

  /// Encode the subscription filter as a buffer for draft-16 param 0x21.
  /// Contents: FilterType(i) [StartLocation] [EndGroup(i)]
  Uint8List _encodeFilterParam() {
    // Calculate size
    int size = MoQWireFormat._varintSize(filterType.value);
    if (filterType == FilterType.absoluteStart ||
        filterType == FilterType.absoluteRange) {
      size += MoQWireFormat._varintSize64(startLocation?.group ?? Int64(0));
      size += MoQWireFormat._varintSize64(startLocation?.object ?? Int64(0));
    }
    if (filterType == FilterType.absoluteRange && endGroup != null) {
      size += MoQWireFormat._varintSize64(endGroup!);
    }

    final buf = Uint8List(size);
    int off = 0;
    final ftBytes = MoQWireFormat.encodeVarint(filterType.value);
    buf.setAll(off, ftBytes);
    off += ftBytes.length;

    if (filterType == FilterType.absoluteStart ||
        filterType == FilterType.absoluteRange) {
      final loc = startLocation ?? Location.zero();
      final locBytes = MoQWireFormat.encodeLocation(loc);
      buf.setAll(off, locBytes);
      off += locBytes.length;
    }

    if (filterType == FilterType.absoluteRange && endGroup != null) {
      final egBytes = MoQWireFormat.encodeVarint64(endGroup!);
      buf.setAll(off, egBytes);
      off += egBytes.length;
    }

    return buf;
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
  Uint8List serialize({int version = MoQVersion.draft14}) {
    final payload = Uint8List(_payloadLength(version));
    int offset = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    // Request ID
    offset += _writeVarint64(payload, offset, requestId);

    // Track Namespace (tuple)
    offset += _writeTuple(payload, offset, trackNamespace);

    // Track Name
    offset += _writeVarint(payload, offset, trackName.length);
    payload.setAll(offset, trackName);
    offset += trackName.length;

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: write all fields as delta-encoded KVP params
      final allParams = _buildDraft16Params();
      final kvpBytes = MoQWireFormat.encodeKeyValuePairs(allParams, useDelta: useDelta);
      payload.setAll(offset, kvpBytes);
      offset += kvpBytes.length;
    } else {
      // Draft-14: inline fields
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
  static SubscribeMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
    int offset = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

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

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: all inline fields are in params
      final (numParams, numParamsLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += numParamsLen;

      final (allParams, paramsRead) =
          MoQWireFormat.decodeKeyValuePairs(data, offset, numParams, useDelta: useDelta);
      offset += paramsRead;

      // Extract inline fields from params, using defaults if not present
      int subscriberPriority = 0;
      var groupOrder = GroupOrder.none;
      int forward = 0;
      var filterType = FilterType.largestObject;
      Location? startLocation;
      Int64? endGroup;
      final remainingParams = <KeyValuePair>[];

      for (final param in allParams) {
        switch (param.type) {
          case SubscribeParameterType.subscriberPriority:
            subscriberPriority = param.intValue ?? 0;
            break;
          case SubscribeParameterType.groupOrder:
            groupOrder = GroupOrder.fromValue(param.intValue ?? 0) ?? GroupOrder.none;
            break;
          case SubscribeParameterType.forward:
            forward = param.intValue ?? 0;
            break;
          case SubscribeParameterType.subscriptionFilter:
            // Decode filter buffer: FilterType(i) [StartLocation] [EndGroup(i)]
            if (param.value != null && param.value!.isNotEmpty) {
              int fOff = 0;
              final (ftVal, ftLen) = MoQWireFormat.decodeVarint(param.value!, fOff);
              fOff += ftLen;
              filterType = FilterType.fromValue(ftVal) ?? FilterType.largestObject;

              if (filterType == FilterType.absoluteStart ||
                  filterType == FilterType.absoluteRange) {
                if (fOff < param.value!.length) {
                  final (loc, locLen) = MoQWireFormat.decodeLocation(param.value!, fOff);
                  fOff += locLen;
                  startLocation = loc;
                }
              }
              if (filterType == FilterType.absoluteRange && fOff < param.value!.length) {
                final (eg, egLen) = MoQWireFormat.decodeVarint64(param.value!, fOff);
                fOff += egLen;
                endGroup = eg;
              }
            }
            break;
          default:
            remainingParams.add(param);
        }
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
        parameters: remainingParams,
      );
    }

    // Draft-14: inline fields
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
  /// Draft-16: track extensions appended after params
  final List<KeyValuePair> trackExtensions;

  SubscribeOkMessage({
    required this.requestId,
    required this.trackAlias,
    required this.expires,
    required this.groupOrder,
    required this.contentExists,
    this.largestLocation,
    this.parameters = const [],
    this.trackExtensions = const [],
  });

  @override
  MoQMessageType get type => MoQMessageType.subscribeOk;

  @override
  int get payloadLength => _payloadLength(MoQVersion.draft14);

  int _payloadLength(int version) {
    int len = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    // RequestID + TrackAlias are always present
    len += MoQWireFormat._varintSize64(requestId);
    len += MoQWireFormat._varintSize64(trackAlias);

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: Expires/GroupOrder/ContentExists/LargestLocation as params
      final allParams = _buildDraft16Params();
      final kvpBytes = MoQWireFormat.encodeKeyValuePairs(allParams, useDelta: useDelta);
      len += kvpBytes.length;
      // Track extensions
      final extBytes = MoQWireFormat.encodeKeyValuePairs(trackExtensions, useDelta: useDelta);
      len += extBytes.length;
    } else {
      // Draft-14: inline fields
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
    }
    return len;
  }

  /// Build the combined parameter list for draft-16 serialization.
  /// Inline fields (expires, groupOrder, contentExists, largestLocation) become params.
  List<KeyValuePair> _buildDraft16Params() {
    final allParams = <KeyValuePair>[
      // expires (TrackPropertyType.expires = 0x8, even) -> varint
      KeyValuePair.varint(TrackPropertyType.expires, expires.toInt()),
      // groupOrder (SubscribeParameterType.groupOrder = 0x22, even) -> varint
      KeyValuePair.varint(SubscribeParameterType.groupOrder, groupOrder.value),
    ];
    // ContentExists + LargestLocation encoded via largestObject param
    // Only include if content exists and we have a location
    if (contentExists == 1 && largestLocation != null) {
      // largestObject (TrackPropertyType.largestObject = 0x9, odd) -> buffer: Location
      final locBytes = MoQWireFormat.encodeLocation(largestLocation!);
      allParams.add(KeyValuePair.buffer(TrackPropertyType.largestObject, locBytes));
    }
    // Append any user-supplied parameters
    allParams.addAll(parameters);
    return allParams;
  }

  int _locationSize() {
    int len = MoQWireFormat._varintSize64(largestLocation?.group ?? Int64(0));
    len += MoQWireFormat._varintSize64(largestLocation?.object ?? Int64(0));
    return len;
  }

  @override
  Uint8List serialize({int version = MoQVersion.draft14}) {
    final payload = Uint8List(_payloadLength(version));
    int offset = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    offset += _writeVarint64(payload, offset, requestId);
    offset += _writeVarint64(payload, offset, trackAlias);

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: delta-encoded params then track extensions
      final allParams = _buildDraft16Params();
      final kvpBytes = MoQWireFormat.encodeKeyValuePairs(allParams, useDelta: useDelta);
      payload.setAll(offset, kvpBytes);
      offset += kvpBytes.length;

      final extBytes = MoQWireFormat.encodeKeyValuePairs(trackExtensions, useDelta: useDelta);
      payload.setAll(offset, extBytes);
      offset += extBytes.length;
    } else {
      // Draft-14: inline fields
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
  static SubscribeOkMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
    int offset = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    final (trackAlias, len2) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len2;

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: params then track extensions
      final (numParams, numParamsLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += numParamsLen;

      final (allParams, paramsRead) =
          MoQWireFormat.decodeKeyValuePairs(data, offset, numParams, useDelta: useDelta);
      offset += paramsRead;

      // Extract inline fields from params
      var expires = Int64(0);
      var groupOrder = GroupOrder.none;
      int contentExists = 0;
      Location? largestLocation;
      final remainingParams = <KeyValuePair>[];

      for (final param in allParams) {
        switch (param.type) {
          case TrackPropertyType.expires:
            expires = Int64(param.intValue ?? 0);
            break;
          case SubscribeParameterType.groupOrder:
            groupOrder = GroupOrder.fromValue(param.intValue ?? 0) ?? GroupOrder.none;
            break;
          case TrackPropertyType.largestObject:
            // Buffer containing Location
            if (param.value != null && param.value!.isNotEmpty) {
              final (loc, _) = MoQWireFormat.decodeLocation(param.value!, 0);
              largestLocation = loc;
              contentExists = 1;
            }
            break;
          default:
            remainingParams.add(param);
        }
      }

      // Read track extensions
      var trackExtensions = <KeyValuePair>[];
      if (offset < data.length) {
        final (numExt, numExtLen) = MoQWireFormat.decodeVarint(data, offset);
        offset += numExtLen;

        final (ext, extRead) =
            MoQWireFormat.decodeKeyValuePairs(data, offset, numExt, useDelta: useDelta);
        offset += extRead;
        trackExtensions = ext;
      }

      return SubscribeOkMessage(
        requestId: requestId,
        trackAlias: trackAlias,
        expires: expires,
        groupOrder: groupOrder,
        contentExists: contentExists,
        largestLocation: largestLocation,
        parameters: remainingParams,
        trackExtensions: trackExtensions,
      );
    }

    // Draft-14: inline fields
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
  Uint8List serialize({int version = MoQVersion.draft14}) {
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
  static SubscribeErrorMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
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
  int get payloadLength => _payloadLength(MoQVersion.draft14);

  int _payloadLength(int version) {
    int len = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    // RequestID + ExistingRequestID (subscriptionRequestId) always present
    len += MoQWireFormat._varintSize64(requestId);
    len += MoQWireFormat._varintSize64(subscriptionRequestId);

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: all inline fields moved to params
      final allParams = _buildDraft16Params();
      final kvpBytes = MoQWireFormat.encodeKeyValuePairs(allParams, useDelta: useDelta);
      len += kvpBytes.length;
    } else {
      // Draft-14: inline fields
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
    }
    return len;
  }

  /// Build the combined parameter list for draft-16 serialization.
  /// Inline fields (startLocation, endGroup, priority, forward) become params.
  List<KeyValuePair> _buildDraft16Params() {
    final allParams = <KeyValuePair>[
      // forward (0x10, even) -> varint
      KeyValuePair.varint(SubscribeParameterType.forward, forward),
      // subscriberPriority (0x20, even) -> varint
      KeyValuePair.varint(SubscribeParameterType.subscriberPriority, subscriberPriority),
      // subscriptionFilter (0x21, odd) -> buffer: StartLocation + EndGroup
      KeyValuePair.buffer(SubscribeParameterType.subscriptionFilter, _encodeFilterParam()),
    ];
    // Append any user-supplied parameters
    allParams.addAll(parameters);
    return allParams;
  }

  /// Encode start location and end group as a buffer for draft-16 param 0x21.
  /// Contents: StartLocation (Location) + EndGroup (i)
  Uint8List _encodeFilterParam() {
    final locBytes = MoQWireFormat.encodeLocation(startLocation);
    final egBytes = MoQWireFormat.encodeVarint64(endGroup);
    final buf = Uint8List(locBytes.length + egBytes.length);
    buf.setAll(0, locBytes);
    buf.setAll(locBytes.length, egBytes);
    return buf;
  }

  int _locationSize() {
    int len = MoQWireFormat._varintSize64(startLocation.group);
    len += MoQWireFormat._varintSize64(startLocation.object);
    return len;
  }

  @override
  Uint8List serialize({int version = MoQVersion.draft14}) {
    final payload = Uint8List(_payloadLength(version));
    int offset = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    offset += _writeVarint64(payload, offset, requestId);
    offset += _writeVarint64(payload, offset, subscriptionRequestId);

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: delta-encoded KVP params
      final allParams = _buildDraft16Params();
      final kvpBytes = MoQWireFormat.encodeKeyValuePairs(allParams, useDelta: useDelta);
      payload.setAll(offset, kvpBytes);
      offset += kvpBytes.length;
    } else {
      // Draft-14: inline fields
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
  static SubscribeUpdateMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
    int offset = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    final (subRequestId, len2) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len2;

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: all inline fields are in params
      final (numParams, numParamsLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += numParamsLen;

      final (allParams, paramsRead) =
          MoQWireFormat.decodeKeyValuePairs(data, offset, numParams, useDelta: useDelta);
      offset += paramsRead;

      // Extract inline fields from params, using defaults if not present
      var startLoc = Location.zero();
      var endGroup = Int64(0);
      int subscriberPriority = 0;
      int forward = 0;
      final remainingParams = <KeyValuePair>[];

      for (final param in allParams) {
        switch (param.type) {
          case SubscribeParameterType.subscriberPriority:
            subscriberPriority = param.intValue ?? 0;
            break;
          case SubscribeParameterType.forward:
            forward = param.intValue ?? 0;
            break;
          case SubscribeParameterType.subscriptionFilter:
            // Decode filter buffer: StartLocation (Location) + EndGroup (i)
            if (param.value != null && param.value!.isNotEmpty) {
              int fOff = 0;
              final (loc, locLen) = MoQWireFormat.decodeLocation(param.value!, fOff);
              fOff += locLen;
              startLoc = loc;
              if (fOff < param.value!.length) {
                final (eg, _) = MoQWireFormat.decodeVarint64(param.value!, fOff);
                endGroup = eg;
              }
            }
            break;
          default:
            remainingParams.add(param);
        }
      }

      return SubscribeUpdateMessage(
        requestId: requestId,
        subscriptionRequestId: subRequestId,
        startLocation: startLoc,
        endGroup: endGroup,
        subscriberPriority: subscriberPriority,
        forward: forward,
        parameters: remainingParams,
      );
    }

    // Draft-14: inline fields
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
  Uint8List serialize({int version = MoQVersion.draft14}) {
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
  static UnsubscribeMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
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
  Uint8List serialize({int version = MoQVersion.draft14}) {
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
  static GoawayMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
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
/// Wire format per draft-ietf-moq-transport-14:
/// PUBLISH_DONE Message {
///   Type (i) = 0xB,
///   Length (16),
///   Request ID (i),
///   Status Code (i),
///   Stream Count (i),
///   Error Reason (Reason Phrase)
/// }
/// Note: Error Reason is required per spec (always write length, even if 0)
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
    // Error Reason is required - always include length (even if 0)
    if (errorReason != null) {
      final reasonBytes = const Utf8Encoder().convert(errorReason!.reason);
      len += MoQWireFormat._varintSize(reasonBytes.length) + reasonBytes.length;
    } else {
      len += MoQWireFormat._varintSize(0); // Empty reason phrase
    }
    return len;
  }

  @override
  Uint8List serialize({int version = MoQVersion.draft14}) {
    final payload = Uint8List(payloadLength);
    int offset = 0;

    offset += _writeVarint64(payload, offset, requestId);
    offset += _writeVarint(payload, offset, statusCode);
    offset += _writeVarint64(payload, offset, streamCount);

    // Error Reason is required - always write length (even if 0)
    if (errorReason != null) {
      final reasonBytes = const Utf8Encoder().convert(errorReason!.reason);
      offset += _writeVarint(payload, offset, reasonBytes.length);
      payload.setAll(offset, reasonBytes);
    } else {
      offset += _writeVarint(payload, offset, 0); // Empty reason phrase
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
  static PublishDoneMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
    int offset = 0;

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    final (statusCode, len2) = MoQWireFormat.decodeVarint(data, offset);
    offset += len2;

    final (streamCount, len3) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len3;

    // Error Reason is required per spec - always read the length
    ReasonPhrase? errorReason;
    if (offset < data.length) {
      final (reasonLen, len4) = MoQWireFormat.decodeVarint(data, offset);
      offset += len4;
      if (reasonLen > 0 && offset + reasonLen <= data.length) {
        final reasonBytes = data.sublist(offset, offset + reasonLen);
        final reason = const Utf8Decoder().convert(reasonBytes);
        errorReason = ReasonPhrase(reason);
      }
      // If reasonLen is 0, errorReason remains null (empty reason)
    }
    // Note: Defensive - handle case where sender omits Error Reason entirely
    // (technically not spec-compliant, but we handle gracefully)

    return PublishDoneMessage(
      requestId: requestId,
      statusCode: statusCode,
      streamCount: streamCount,
      errorReason: errorReason,
    );
  }
}
