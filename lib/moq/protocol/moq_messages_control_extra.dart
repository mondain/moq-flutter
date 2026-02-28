part of 'moq_messages.dart';

// NOTE: This file contains the remaining control messages for MoQ draft-14
// These are appended to moq_messages_control.dart

/// Fetch type enum per draft-ietf-moq-transport-14 Section 9.16
enum FetchType {
  standalone(0x1),
  relativeJoining(0x2),
  absoluteJoining(0x3);

  final int value;
  const FetchType(this.value);

  static FetchType? fromValue(int value) {
    for (final type in values) {
      if (type.value == value) return type;
    }
    return null;
  }
}

/// FETCH message (0x16) per draft-ietf-moq-transport-14 Section 9.16
///
/// Wire format:
/// FETCH Message {
///   Type (i) = 0x16,
///   Length (16),
///   Request ID (i),
///   Subscriber Priority (8),
///   Group Order (8),
///   Fetch Type (i),
///   [Standalone (Standalone Fetch)],  // if Fetch Type = 0x1
///   [Joining (Joining Fetch)],        // if Fetch Type = 0x2 or 0x3
///   Number of Parameters (i),
///   Parameters (..) ...
/// }
class FetchMessage extends MoQControlMessage {
  final Int64 requestId;
  final int subscriberPriority;
  final GroupOrder groupOrder;
  final FetchType fetchType;

  // Standalone fetch fields (when fetchType == standalone)
  final List<Uint8List>? trackNamespace;
  final Uint8List? trackName;
  final Location? startLocation;
  final Location? endLocation;

  // Joining fetch fields (when fetchType == relativeJoining or absoluteJoining)
  final Int64? joiningRequestId;
  final Int64? joiningStart;

  final List<KeyValuePair> parameters;

  /// Create a standalone fetch
  FetchMessage.standalone({
    required this.requestId,
    required List<Uint8List> trackNamespace,
    required Uint8List trackName,
    required Location startLocation,
    required Location endLocation,
    this.subscriberPriority = 128,
    this.groupOrder = GroupOrder.none,
    this.parameters = const [],
  })  : fetchType = FetchType.standalone,
        trackNamespace = trackNamespace,
        trackName = trackName,
        startLocation = startLocation,
        endLocation = endLocation,
        joiningRequestId = null,
        joiningStart = null;

  /// Create a relative joining fetch (startLocation = Largest.Group - joiningStart, 0)
  FetchMessage.relativeJoining({
    required this.requestId,
    required Int64 joiningRequestId,
    required Int64 joiningStart,
    this.subscriberPriority = 128,
    this.groupOrder = GroupOrder.none,
    this.parameters = const [],
  })  : fetchType = FetchType.relativeJoining,
        joiningRequestId = joiningRequestId,
        joiningStart = joiningStart,
        trackNamespace = null,
        trackName = null,
        startLocation = null,
        endLocation = null;

  /// Create an absolute joining fetch (startLocation = joiningStart as Location)
  FetchMessage.absoluteJoining({
    required this.requestId,
    required Int64 joiningRequestId,
    required Int64 joiningStart,
    this.subscriberPriority = 128,
    this.groupOrder = GroupOrder.none,
    this.parameters = const [],
  })  : fetchType = FetchType.absoluteJoining,
        joiningRequestId = joiningRequestId,
        joiningStart = joiningStart,
        trackNamespace = null,
        trackName = null,
        startLocation = null,
        endLocation = null;

  /// Internal constructor for deserialization
  FetchMessage._({
    required this.requestId,
    required this.subscriberPriority,
    required this.groupOrder,
    required this.fetchType,
    this.trackNamespace,
    this.trackName,
    this.startLocation,
    this.endLocation,
    this.joiningRequestId,
    this.joiningStart,
    this.parameters = const [],
  });

  /// Get track namespace as path string (for standalone fetch)
  String get namespacePath {
    if (trackNamespace == null) return '';
    return trackNamespace!.map((e) => String.fromCharCodes(e)).join('/');
  }

  /// Get track name as string (for standalone fetch)
  String get trackNameString {
    if (trackName == null) return '';
    return String.fromCharCodes(trackName!);
  }

  @override
  MoQMessageType get type => MoQMessageType.fetch;

  @override
  int get payloadLength => _payloadLength(MoQVersion.draft14);

  int _payloadLength(int version) {
    int len = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    len += MoQWireFormat._varintSize64(requestId);

    if (!MoQVersion.isDraft16OrLater(version)) {
      len += 1; // Subscriber Priority
      len += 1; // Group Order
    }

    len += MoQWireFormat._varintSize(fetchType.value);

    if (fetchType == FetchType.standalone) {
      len += MoQWireFormat._tupleSize(trackNamespace!);
      len += MoQWireFormat._varintSize(trackName!.length) + trackName!.length;
      len += MoQWireFormat._varintSize64(startLocation!.group);
      len += MoQWireFormat._varintSize64(startLocation!.object);
      len += MoQWireFormat._varintSize64(endLocation!.group);
      len += MoQWireFormat._varintSize64(endLocation!.object);
    } else {
      len += MoQWireFormat._varintSize64(joiningRequestId!);
      len += MoQWireFormat._varintSize64(joiningStart!);
    }

    if (MoQVersion.isDraft16OrLater(version)) {
      final kvpBytes = MoQWireFormat.encodeKeyValuePairs(parameters, useDelta: useDelta);
      len += kvpBytes.length;
    } else {
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

  @override
  Uint8List serialize({int version = MoQVersion.draft14}) {
    final payload = Uint8List(_payloadLength(version));
    final useDelta = MoQVersion.usesDeltaKvp(version);
    int offset = 0;

    offset += _writeVarint64(payload, offset, requestId);

    if (!MoQVersion.isDraft16OrLater(version)) {
      payload[offset++] = subscriberPriority;
      payload[offset++] = groupOrder.value;
    }

    offset += _writeVarint(payload, offset, fetchType.value);

    if (fetchType == FetchType.standalone) {
      offset += _writeTuple(payload, offset, trackNamespace!);
      offset += _writeVarint(payload, offset, trackName!.length);
      payload.setAll(offset, trackName!);
      offset += trackName!.length;
      offset += _writeVarint64(payload, offset, startLocation!.group);
      offset += _writeVarint64(payload, offset, startLocation!.object);
      offset += _writeVarint64(payload, offset, endLocation!.group);
      offset += _writeVarint64(payload, offset, endLocation!.object);
    } else {
      offset += _writeVarint64(payload, offset, joiningRequestId!);
      offset += _writeVarint64(payload, offset, joiningStart!);
    }

    if (MoQVersion.isDraft16OrLater(version)) {
      final kvpBytes = MoQWireFormat.encodeKeyValuePairs(parameters, useDelta: useDelta);
      payload.setAll(offset, kvpBytes);
      offset += kvpBytes.length;
    } else {
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

  static FetchMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
    int offset = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    int subscriberPriority = 128;
    GroupOrder groupOrder = GroupOrder.none;

    if (!MoQVersion.isDraft16OrLater(version)) {
      subscriberPriority = data[offset++];
      groupOrder = GroupOrder.fromValue(data[offset++]) ?? GroupOrder.none;
    }

    final (fetchTypeValue, len2) = MoQWireFormat.decodeVarint(data, offset);
    offset += len2;
    final fetchType = FetchType.fromValue(fetchTypeValue) ?? FetchType.standalone;

    List<Uint8List>? trackNamespace;
    Uint8List? trackName;
    Location? startLocation;
    Location? endLocation;
    Int64? joiningRequestId;
    Int64? joiningStart;

    if (fetchType == FetchType.standalone) {
      final (namespace, len3) = MoQWireFormat.decodeTuple(data, offset);
      offset += len3;
      trackNamespace = namespace;

      final (nameLen, len4) = MoQWireFormat.decodeVarint(data, offset);
      offset += len4;
      trackName = data.sublist(offset, offset + nameLen);
      offset += nameLen;

      final (startGroup, len5) = MoQWireFormat.decodeVarint64(data, offset);
      offset += len5;
      final (startObject, len6) = MoQWireFormat.decodeVarint64(data, offset);
      offset += len6;
      startLocation = Location(group: startGroup, object: startObject);

      final (endGroup, len7) = MoQWireFormat.decodeVarint64(data, offset);
      offset += len7;
      final (endObject, len8) = MoQWireFormat.decodeVarint64(data, offset);
      offset += len8;
      endLocation = Location(group: endGroup, object: endObject);
    } else {
      final (jReqId, len3) = MoQWireFormat.decodeVarint64(data, offset);
      offset += len3;
      joiningRequestId = jReqId;

      final (jStart, len4) = MoQWireFormat.decodeVarint64(data, offset);
      offset += len4;
      joiningStart = jStart;
    }

    final (numParams, numParamsLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += numParamsLen;

    List<KeyValuePair> params;
    if (MoQVersion.isDraft16OrLater(version)) {
      final (decodedParams, paramsRead) =
          MoQWireFormat.decodeKeyValuePairs(data, offset, numParams, useDelta: useDelta);
      offset += paramsRead;
      params = decodedParams;
    } else {
      params = <KeyValuePair>[];
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
    }

    return FetchMessage._(
      requestId: requestId,
      subscriberPriority: subscriberPriority,
      groupOrder: groupOrder,
      fetchType: fetchType,
      trackNamespace: trackNamespace,
      trackName: trackName,
      startLocation: startLocation,
      endLocation: endLocation,
      joiningRequestId: joiningRequestId,
      joiningStart: joiningStart,
      parameters: params,
    );
  }
}

/// FETCH_OK message (0x18) per draft-ietf-moq-transport-14 Section 9.17
///
/// Wire format:
/// FETCH_OK Message {
///   Type (i) = 0x18,
///   Length (16),
///   Request ID (i),
///   Group Order (8),
///   End Of Track (8),
///   End Location (Location),
///   Number of Parameters (i),
///   Parameters (..) ...
/// }
class FetchOkMessage extends MoQControlMessage {
  final Int64 requestId;
  final GroupOrder groupOrder;
  final int endOfTrack; // 1 if all objects published, 0 if not
  final Location endLocation;
  final List<KeyValuePair> parameters;
  /// Draft-16: track extensions appended after params
  final List<KeyValuePair> trackExtensions;

  FetchOkMessage({
    required this.requestId,
    required this.groupOrder,
    required this.endOfTrack,
    required this.endLocation,
    this.parameters = const [],
    this.trackExtensions = const [],
  });

  /// Whether this is the final object in the track
  bool get isEndOfTrack => endOfTrack == 1;

  @override
  MoQMessageType get type => MoQMessageType.fetchOk;

  @override
  int get payloadLength => _payloadLength(MoQVersion.draft14);

  int _payloadLength(int version) {
    int len = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    len += MoQWireFormat._varintSize64(requestId);

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: no GroupOrder inline; EndOfTrack + EndLocation remain
      len += 1; // End Of Track
      len += MoQWireFormat._varintSize64(endLocation.group);
      len += MoQWireFormat._varintSize64(endLocation.object);
      // Params as delta KVP
      final kvpBytes = MoQWireFormat.encodeKeyValuePairs(parameters, useDelta: useDelta);
      len += kvpBytes.length;
      // Track extensions
      final extBytes = MoQWireFormat.encodeKeyValuePairs(trackExtensions, useDelta: useDelta);
      len += extBytes.length;
    } else {
      // Draft-14: inline fields
      len += 1; // Group Order
      len += 1; // End Of Track
      len += MoQWireFormat._varintSize64(endLocation.group);
      len += MoQWireFormat._varintSize64(endLocation.object);
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

  @override
  Uint8List serialize({int version = MoQVersion.draft14}) {
    final payload = Uint8List(_payloadLength(version));
    int offset = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    offset += _writeVarint64(payload, offset, requestId);

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: no GroupOrder inline
      payload[offset++] = endOfTrack;
      offset += _writeLocation(payload, offset, endLocation);

      // Params as delta KVP
      final kvpBytes = MoQWireFormat.encodeKeyValuePairs(parameters, useDelta: useDelta);
      payload.setAll(offset, kvpBytes);
      offset += kvpBytes.length;

      // Track extensions
      final extBytes = MoQWireFormat.encodeKeyValuePairs(trackExtensions, useDelta: useDelta);
      payload.setAll(offset, extBytes);
      offset += extBytes.length;
    } else {
      // Draft-14: inline fields
      payload[offset++] = groupOrder.value;
      payload[offset++] = endOfTrack;
      offset += _writeLocation(payload, offset, endLocation);

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

  static FetchOkMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
    int offset = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: no GroupOrder inline
      final endOfTrack = data[offset++];

      final (endLocation, locLen) = MoQWireFormat.decodeLocation(data, offset);
      offset += locLen;

      // Params as delta KVP
      final (numParams, numParamsLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += numParamsLen;

      final (params, paramsRead) =
          MoQWireFormat.decodeKeyValuePairs(data, offset, numParams, useDelta: useDelta);
      offset += paramsRead;

      // Track extensions
      var trackExtensions = <KeyValuePair>[];
      if (offset < data.length) {
        final (numExt, numExtLen) = MoQWireFormat.decodeVarint(data, offset);
        offset += numExtLen;

        final (ext, extRead) =
            MoQWireFormat.decodeKeyValuePairs(data, offset, numExt, useDelta: useDelta);
        offset += extRead;
        trackExtensions = ext;
      }

      return FetchOkMessage(
        requestId: requestId,
        groupOrder: GroupOrder.ascending, // default; not on wire in draft-16
        endOfTrack: endOfTrack,
        endLocation: endLocation,
        parameters: params,
        trackExtensions: trackExtensions,
      );
    }

    // Draft-14: inline fields
    final groupOrder = GroupOrder.fromValue(data[offset++]) ?? GroupOrder.ascending;
    final endOfTrack = data[offset++];

    final (endLocation, locLen) = MoQWireFormat.decodeLocation(data, offset);
    offset += locLen;

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
      groupOrder: groupOrder,
      endOfTrack: endOfTrack,
      endLocation: endLocation,
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

  static FetchErrorMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
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

  static FetchCancelMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
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
  /// Draft-16: track extensions appended after params
  final List<KeyValuePair> trackExtensions;

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
    this.trackExtensions = const [],
  });

  @override
  MoQMessageType get type => MoQMessageType.publish;

  @override
  int get payloadLength => _payloadLength(MoQVersion.draft14);

  int _payloadLength(int version) {
    int len = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    len += MoQWireFormat._varintSize64(requestId);
    len += _tupleSize(trackNamespace);
    len += MoQWireFormat._varintSize(trackName.length) + trackName.length;
    len += MoQWireFormat._varintSize64(trackAlias);

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: no GroupOrder/ContentExists/LargestLocation/Forward inline
      // Params as delta KVP
      final kvpBytes = MoQWireFormat.encodeKeyValuePairs(parameters, useDelta: useDelta);
      len += kvpBytes.length;
      // Track extensions
      final extBytes = MoQWireFormat.encodeKeyValuePairs(trackExtensions, useDelta: useDelta);
      len += extBytes.length;
    } else {
      // Draft-14: inline fields
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
  Uint8List serialize({int version = MoQVersion.draft14}) {
    final payload = Uint8List(_payloadLength(version));
    int offset = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    offset += _writeVarint64(payload, offset, requestId);
    offset += _writeTuple(payload, offset, trackNamespace);
    offset += _writeVarint(payload, offset, trackName.length);
    payload.setAll(offset, trackName);
    offset += trackName.length;
    offset += _writeVarint64(payload, offset, trackAlias);

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: no GroupOrder/ContentExists/LargestLocation/Forward inline
      // Params as delta KVP
      final kvpBytes = MoQWireFormat.encodeKeyValuePairs(parameters, useDelta: useDelta);
      payload.setAll(offset, kvpBytes);
      offset += kvpBytes.length;

      // Track extensions
      final extBytes = MoQWireFormat.encodeKeyValuePairs(trackExtensions, useDelta: useDelta);
      payload.setAll(offset, extBytes);
      offset += extBytes.length;
    } else {
      // Draft-14: inline fields
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

  static PublishMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
    int offset = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

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

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: no GroupOrder/ContentExists/LargestLocation/Forward inline
      // Params as delta KVP
      final (numParams, numParamsLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += numParamsLen;

      final (params, paramsRead) =
          MoQWireFormat.decodeKeyValuePairs(data, offset, numParams, useDelta: useDelta);
      offset += paramsRead;

      // Track extensions
      var trackExtensions = <KeyValuePair>[];
      if (offset < data.length) {
        final (numExt, numExtLen) = MoQWireFormat.decodeVarint(data, offset);
        offset += numExtLen;

        final (ext, extRead) =
            MoQWireFormat.decodeKeyValuePairs(data, offset, numExt, useDelta: useDelta);
        offset += extRead;
        trackExtensions = ext;
      }

      return PublishMessage(
        requestId: requestId,
        trackNamespace: namespace,
        trackName: Uint8List.fromList(trackName),
        trackAlias: trackAlias,
        groupOrder: GroupOrder.ascending, // default; not on wire in draft-16
        contentExists: false, // default; not on wire in draft-16
        forward: 0, // default; not on wire in draft-16
        parameters: params,
        trackExtensions: trackExtensions,
      );
    }

    // Draft-14: inline fields
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
  int get payloadLength => _payloadLength(MoQVersion.draft14);

  int _payloadLength(int version) {
    int len = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    len += MoQWireFormat._varintSize64(requestId);

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: only RequestID + delta KVP params
      final kvpBytes = MoQWireFormat.encodeKeyValuePairs(parameters, useDelta: useDelta);
      len += kvpBytes.length;
    } else {
      // Draft-14: inline fields
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
    }
    return len;
  }

  @override
  Uint8List serialize({int version = MoQVersion.draft14}) {
    final payload = Uint8List(_payloadLength(version));
    int offset = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    offset += _writeVarint64(payload, offset, requestId);

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: only RequestID + delta KVP params
      final kvpBytes = MoQWireFormat.encodeKeyValuePairs(parameters, useDelta: useDelta);
      payload.setAll(offset, kvpBytes);
      offset += kvpBytes.length;
    } else {
      // Draft-14: inline fields
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

  static PublishOkMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
    int offset = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    final (requestId, reqLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += reqLen;

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: only RequestID + delta KVP params
      final (numParams, numParamsLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += numParamsLen;

      final (params, paramsRead) =
          MoQWireFormat.decodeKeyValuePairs(data, offset, numParams, useDelta: useDelta);
      offset += paramsRead;

      return PublishOkMessage(
        requestId: requestId,
        forward: 0, // default; not on wire in draft-16
        subscriberPriority: 0, // default; not on wire in draft-16
        groupOrder: GroupOrder.ascending, // default; not on wire in draft-16
        filterType: FilterType.largestObject, // default; not on wire in draft-16
        parameters: params,
      );
    }

    // Draft-14: inline fields
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

  static PublishErrorMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
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
  Uint8List serialize({int version = MoQVersion.draft14}) {
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

  static MaxRequestIdMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
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
  Uint8List serialize({int version = MoQVersion.draft14}) {
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

  static RequestsBlockedMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
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
///
/// Draft-14 wire format:
///   RequestID (i), TrackAlias (i), StatusInterval (i)
///
/// Draft-16 wire format (same structure as SUBSCRIBE):
///   RequestID (i), Namespace (tuple), NameLen (i), Name (..), NumParams (i), Params (..) ...
class TrackStatusMessage extends MoQControlMessage {
  final Int64 requestId;
  final Int64 trackAlias;
  final Int64 statusInterval;

  // Draft-16 fields
  final List<Uint8List>? trackNamespace;
  final Uint8List? trackName;
  final List<KeyValuePair> parameters;

  /// Draft-14 constructor
  TrackStatusMessage({
    required this.requestId,
    required this.trackAlias,
    required this.statusInterval,
    this.trackNamespace,
    this.trackName,
    this.parameters = const [],
  });

  /// Draft-16 constructor with namespace/name
  TrackStatusMessage.draft16({
    required this.requestId,
    required List<Uint8List> trackNamespace,
    required Uint8List trackName,
    this.parameters = const [],
  })  : trackNamespace = trackNamespace,
        trackName = trackName,
        trackAlias = Int64(0),
        statusInterval = Int64(0);

  @override
  MoQMessageType get type => MoQMessageType.trackStatus;

  @override
  int get payloadLength => _payloadLength(MoQVersion.draft14);

  int _payloadLength(int version) {
    int len = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    len += MoQWireFormat._varintSize64(requestId);

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: Namespace (tuple), NameLen (i), Name (..), delta KVP params
      len += MoQWireFormat._tupleSize(trackNamespace ?? []);
      final name = trackName ?? Uint8List(0);
      len += MoQWireFormat._varintSize(name.length) + name.length;
      final kvpBytes = MoQWireFormat.encodeKeyValuePairs(parameters, useDelta: useDelta);
      len += kvpBytes.length;
    } else {
      // Draft-14: TrackAlias (i), StatusInterval (i)
      len += MoQWireFormat._varintSize64(trackAlias);
      len += MoQWireFormat._varintSize64(statusInterval);
    }
    return len;
  }

  @override
  Uint8List serialize({int version = MoQVersion.draft14}) {
    final payload = Uint8List(_payloadLength(version));
    final useDelta = MoQVersion.usesDeltaKvp(version);
    int offset = 0;

    offset += _writeVarint64(payload, offset, requestId);

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: Namespace (tuple), NameLen, Name, delta KVP params
      offset += _writeTuple(payload, offset, trackNamespace ?? []);
      final name = trackName ?? Uint8List(0);
      offset += _writeVarint(payload, offset, name.length);
      payload.setAll(offset, name);
      offset += name.length;
      final kvpBytes = MoQWireFormat.encodeKeyValuePairs(parameters, useDelta: useDelta);
      payload.setAll(offset, kvpBytes);
      offset += kvpBytes.length;
    } else {
      // Draft-14: TrackAlias, StatusInterval
      offset += _writeVarint64(payload, offset, trackAlias);
      offset += _writeVarint64(payload, offset, statusInterval);
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

  static TrackStatusMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
    int offset = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: Namespace (tuple), NameLen, Name, delta KVP params
      final (namespace, tupleLen) = MoQWireFormat.decodeTuple(data, offset);
      offset += tupleLen;

      final (nameLen, nameLenLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += nameLenLen;
      final trackName = data.sublist(offset, offset + nameLen);
      offset += nameLen;

      final (numParams, numParamsLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += numParamsLen;

      final (params, _) =
          MoQWireFormat.decodeKeyValuePairs(data, offset, numParams, useDelta: useDelta);

      return TrackStatusMessage.draft16(
        requestId: requestId,
        trackNamespace: namespace,
        trackName: trackName,
        parameters: params,
      );
    }

    // Draft-14: TrackAlias, StatusInterval
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
  Uint8List serialize({int version = MoQVersion.draft14}) {
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

  static TrackStatusOkMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
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

  static TrackStatusErrorMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
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

/// SUBSCRIBE_NAMESPACE message (0x11) per draft-ietf-moq-transport-14/16
///
/// The subscriber sends SUBSCRIBE_NAMESPACE to request the current set of
/// matching published namespaces and established subscriptions, as well as
/// future updates to the set.
///
/// Draft-14 wire format:
///   RequestID (i), NamespacePrefix (tuple), NumParams (i), Params (..) ...
///
/// Draft-16 wire format:
///   RequestID (i), NamespacePrefix (tuple), SubscribeOptions (i), NumParams (i), Params (..) ...
class SubscribeNamespaceMessage extends MoQControlMessage {
  final Int64 requestId;
  final List<Uint8List> trackNamespacePrefix;
  final List<KeyValuePair> parameters;

  // Draft-16 field
  final SubscribeOptions? subscribeOptions;

  SubscribeNamespaceMessage({
    required this.requestId,
    required this.trackNamespacePrefix,
    this.parameters = const [],
    this.subscribeOptions,
  });

  @override
  MoQMessageType get type => MoQMessageType.subscribeNamespace;

  @override
  int get payloadLength => _payloadLength(MoQVersion.draft14);

  int _payloadLength(int version) {
    int len = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    len += MoQWireFormat._varintSize64(requestId);
    len += MoQWireFormat._tupleSize(trackNamespacePrefix);

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: SubscribeOptions (varint) + delta KVP params
      final opts = subscribeOptions ?? SubscribeOptions.both;
      len += MoQWireFormat._varintSize(opts.value);
      final kvpBytes = MoQWireFormat.encodeKeyValuePairs(parameters, useDelta: useDelta);
      len += kvpBytes.length;
    } else {
      // Draft-14: NumParams + inline params
      len += MoQWireFormat._varintSize(parameters.length);
      for (final param in parameters) {
        len += MoQWireFormat._varintSize(param.type);
        final valueLen = param.value?.length ?? 0;
        len += MoQWireFormat._varintSize(valueLen);
        len += valueLen;
      }
    }
    return len;
  }

  @override
  Uint8List serialize({int version = MoQVersion.draft14}) {
    final payload = Uint8List(_payloadLength(version));
    final useDelta = MoQVersion.usesDeltaKvp(version);
    int offset = 0;

    offset += _writeVarint64(payload, offset, requestId);
    offset += _writeTuple(payload, offset, trackNamespacePrefix);

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: SubscribeOptions + delta KVP params
      final opts = subscribeOptions ?? SubscribeOptions.both;
      offset += _writeVarint(payload, offset, opts.value);
      final kvpBytes = MoQWireFormat.encodeKeyValuePairs(parameters, useDelta: useDelta);
      payload.setAll(offset, kvpBytes);
      offset += kvpBytes.length;
    } else {
      // Draft-14: inline params
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

  static SubscribeNamespaceMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
    int offset = 0;
    final useDelta = MoQVersion.usesDeltaKvp(version);

    final (requestId, reqLen) = MoQWireFormat.decodeVarint64(data, offset);
    offset += reqLen;

    final (namespacePrefix, tupleLen) = MoQWireFormat.decodeTuple(data, offset);
    offset += tupleLen;

    SubscribeOptions? subscribeOptions;
    List<KeyValuePair> params;

    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16: SubscribeOptions + delta KVP params
      final (optsValue, optsLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += optsLen;
      subscribeOptions = SubscribeOptions.fromValue(optsValue) ?? SubscribeOptions.both;

      final (numParams, numParamsLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += numParamsLen;

      final (decodedParams, _) =
          MoQWireFormat.decodeKeyValuePairs(data, offset, numParams, useDelta: useDelta);
      params = decodedParams;
    } else {
      // Draft-14: inline params
      final (numParams, numParamsLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += numParamsLen;

      params = <KeyValuePair>[];
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
    }

    return SubscribeNamespaceMessage(
      requestId: requestId,
      trackNamespacePrefix: namespacePrefix,
      parameters: params,
      subscribeOptions: subscribeOptions,
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
  Uint8List serialize({int version = MoQVersion.draft14}) {
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

  static SubscribeNamespaceOkMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
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

  static SubscribeNamespaceErrorMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
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
  Uint8List serialize({int version = MoQVersion.draft14}) {
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

  static UnsubscribeNamespaceMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
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

// ============================================================
// Draft-16 new message types
// ============================================================

/// REQUEST_OK message (type 0x7 in draft-16)
///
/// Replaces PUBLISH_NAMESPACE_OK, SUBSCRIBE_NAMESPACE_OK, TRACK_STATUS_OK.
///
/// Wire format:
/// REQUEST_OK {
///   Type (i) = 0x7,
///   Length (16),
///   Request ID (i),
///   Number of Parameters (i),
///   Parameters (..) ...
/// }
class RequestOkMessage extends MoQControlMessage {
  final Int64 requestId;
  final List<KeyValuePair> parameters;

  RequestOkMessage({
    required this.requestId,
    this.parameters = const [],
  });

  @override
  MoQMessageType get type => MoQMessageType.requestOk;

  @override
  int get payloadLength {
    int len = MoQWireFormat._varintSize64(requestId);
    len += MoQWireFormat._varintSize(parameters.length);
    int lastType = 0;
    for (final param in parameters) {
      final delta = param.type - lastType;
      len += MoQWireFormat._varintSize(delta);
      if (param.isVarintType) {
        len += MoQWireFormat._varintSize(param.intValue ?? 0);
      } else if (param.value != null) {
        len += MoQWireFormat._varintSize(param.value!.length) + param.value!.length;
      } else {
        len += MoQWireFormat._varintSize(0);
      }
      lastType = param.type;
    }
    return len;
  }

  @override
  Uint8List serialize({int version = MoQVersion.draft14}) {
    final payload = Uint8List(payloadLength);
    int offset = 0;

    final reqIdBytes = MoQWireFormat.encodeVarint64(requestId);
    payload.setAll(offset, reqIdBytes);
    offset += reqIdBytes.length;

    // Always delta KVP (this is a draft-16 message)
    final kvpBytes = MoQWireFormat.encodeKeyValuePairs(parameters, useDelta: true);
    payload.setAll(offset, kvpBytes);

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

  static RequestOkMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
    int offset = 0;

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    final (numParams, numParamsLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += numParamsLen;

    final (params, _) =
        MoQWireFormat.decodeKeyValuePairs(data, offset, numParams, useDelta: true);

    return RequestOkMessage(requestId: requestId, parameters: params);
  }
}

/// REQUEST_ERROR message (type 0x5 in draft-16)
///
/// Replaces SUBSCRIBE_ERROR, PUBLISH_ERROR, FETCH_ERROR, TRACK_STATUS_ERROR,
/// SUBSCRIBE_NAMESPACE_ERROR, PUBLISH_NAMESPACE_ERROR.
///
/// Wire format:
/// REQUEST_ERROR {
///   Type (i) = 0x5,
///   Length (16),
///   Request ID (i),
///   Error Code (i),
///   Retry Interval (i),
///   Error Reason (Reason Phrase)
/// }
class RequestErrorMessage extends MoQControlMessage {
  final Int64 requestId;
  final int errorCode;
  final Int64 retryInterval;
  final ReasonPhrase errorReason;

  RequestErrorMessage({
    required this.requestId,
    required this.errorCode,
    required this.retryInterval,
    required this.errorReason,
  });

  @override
  MoQMessageType get type => MoQMessageType.requestError;

  @override
  int get payloadLength {
    int len = MoQWireFormat._varintSize64(requestId);
    len += MoQWireFormat._varintSize(errorCode);
    len += MoQWireFormat._varintSize64(retryInterval);
    final reasonBytes = const Utf8Encoder().convert(errorReason.reason);
    len += MoQWireFormat._varintSize(reasonBytes.length) + reasonBytes.length;
    return len;
  }

  @override
  Uint8List serialize({int version = MoQVersion.draft14}) {
    final reasonBytes = const Utf8Encoder().convert(errorReason.reason);
    final payload = Uint8List(payloadLength);
    int offset = 0;

    var bytes = MoQWireFormat.encodeVarint64(requestId);
    payload.setAll(offset, bytes);
    offset += bytes.length;

    bytes = MoQWireFormat.encodeVarint(errorCode);
    payload.setAll(offset, bytes);
    offset += bytes.length;

    bytes = MoQWireFormat.encodeVarint64(retryInterval);
    payload.setAll(offset, bytes);
    offset += bytes.length;

    bytes = MoQWireFormat.encodeVarint(reasonBytes.length);
    payload.setAll(offset, bytes);
    offset += bytes.length;
    payload.setAll(offset, reasonBytes);

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

  static RequestErrorMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
    int offset = 0;

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    final (errorCode, len2) = MoQWireFormat.decodeVarint(data, offset);
    offset += len2;

    final (retryInterval, len3) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len3;

    final (reasonLen, len4) = MoQWireFormat.decodeVarint(data, offset);
    offset += len4;

    final reasonBytes = data.sublist(offset, offset + reasonLen);
    final reason = const Utf8Decoder().convert(reasonBytes);

    return RequestErrorMessage(
      requestId: requestId,
      errorCode: errorCode,
      retryInterval: retryInterval,
      errorReason: ReasonPhrase(reason),
    );
  }
}

/// NAMESPACE message (type 0x8 in draft-16)
///
/// Sent on SUBSCRIBE_NAMESPACE response stream to announce a namespace.
///
/// Wire format:
/// NAMESPACE {
///   Type (i) = 0x8,
///   Length (16),
///   Track Namespace Suffix (tuple)
/// }
class NamespaceMessage extends MoQControlMessage {
  final List<Uint8List> trackNamespaceSuffix;

  NamespaceMessage({
    required this.trackNamespaceSuffix,
  });

  @override
  MoQMessageType get type => MoQMessageType.namespace_;

  @override
  int get payloadLength => MoQWireFormat._tupleSize(trackNamespaceSuffix);

  @override
  Uint8List serialize({int version = MoQVersion.draft14}) {
    final payload = Uint8List(payloadLength);
    final tupleBytes = MoQWireFormat.encodeTuple(trackNamespaceSuffix);
    payload.setAll(0, tupleBytes);
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

  static NamespaceMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
    final (suffix, _) = MoQWireFormat.decodeTuple(data, 0);
    return NamespaceMessage(trackNamespaceSuffix: suffix);
  }

  String get suffixPath {
    return trackNamespaceSuffix
        .map((e) => const Utf8Decoder().convert(e))
        .join('/');
  }
}

/// NAMESPACE_DONE message (type 0xE in draft-16)
///
/// Sent on SUBSCRIBE_NAMESPACE response stream to indicate namespace is done.
///
/// Wire format:
/// NAMESPACE_DONE {
///   Type (i) = 0xE,
///   Length (16),
///   Track Namespace Suffix (tuple)
/// }
class NamespaceDoneMessage extends MoQControlMessage {
  final List<Uint8List> trackNamespaceSuffix;

  NamespaceDoneMessage({
    required this.trackNamespaceSuffix,
  });

  @override
  MoQMessageType get type => MoQMessageType.namespaceDone;

  @override
  int get payloadLength => MoQWireFormat._tupleSize(trackNamespaceSuffix);

  @override
  Uint8List serialize({int version = MoQVersion.draft14}) {
    final payload = Uint8List(payloadLength);
    final tupleBytes = MoQWireFormat.encodeTuple(trackNamespaceSuffix);
    payload.setAll(0, tupleBytes);
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

  static NamespaceDoneMessage deserialize(Uint8List data, {int version = MoQVersion.draft14}) {
    final (suffix, _) = MoQWireFormat.decodeTuple(data, 0);
    return NamespaceDoneMessage(trackNamespaceSuffix: suffix);
  }

  String get suffixPath {
    return trackNamespaceSuffix
        .map((e) => const Utf8Decoder().convert(e))
        .join('/');
  }
}
