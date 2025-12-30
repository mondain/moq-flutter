part of 'moq_messages.dart';

// PUBLISH_NAMESPACE related messages for MoQ draft-14
// These messages are used by publishers to announce namespaces to relays

/// PUBLISH_NAMESPACE message (0x6)
///
/// Sent by a publisher to announce the availability of a namespace.
/// The relay responds with PUBLISH_NAMESPACE_OK or PUBLISH_NAMESPACE_ERROR.
///
/// Wire format:
/// PUBLISH_NAMESPACE {
///   Type (i) = 0x6,
///   Length (16),
///   Request ID (i),
///   Track Namespace (tuple),
///   Number of Parameters (i),
///   Parameters (..) ...
/// }
class PublishNamespaceMessage extends MoQControlMessage {
  final Int64 requestId;
  final List<Uint8List> trackNamespace;
  final List<KeyValuePair> parameters;

  PublishNamespaceMessage({
    required this.requestId,
    required this.trackNamespace,
    this.parameters = const [],
  });

  @override
  MoQMessageType get type => MoQMessageType.publishNamespace;

  @override
  int get payloadLength {
    int len = 0;
    len += MoQWireFormat._varintSize64(requestId);
    len += _tupleSize(trackNamespace);
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

  static PublishNamespaceMessage deserialize(Uint8List data) {
    int offset = 0;

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    final (namespace, len2) = MoQWireFormat.decodeTuple(data, offset);
    offset += len2;

    final (numParams, numParamsLen) = MoQWireFormat.decodeVarint(data, offset);
    offset += numParamsLen;

    final params = <KeyValuePair>[];
    for (int i = 0; i < numParams; i++) {
      final (paramType, typeLen) = MoQWireFormat.decodeVarint(data, offset);
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
      params.add(KeyValuePair(type: paramType, value: value));
    }

    return PublishNamespaceMessage(
      requestId: requestId,
      trackNamespace: namespace,
      parameters: params,
    );
  }

  /// Get namespace as a string path (e.g., "demo/video")
  String get namespacePath {
    return trackNamespace
        .map((e) => const Utf8Decoder().convert(e))
        .join('/');
  }
}

/// PUBLISH_NAMESPACE_OK message (0x7)
///
/// Sent by relay in response to successful PUBLISH_NAMESPACE.
/// Per draft-ietf-moq-transport-14 Section 9.24, this message contains only
/// the Request ID - no parameters field.
class PublishNamespaceOkMessage extends MoQControlMessage {
  final Int64 requestId;

  PublishNamespaceOkMessage({
    required this.requestId,
  });

  @override
  MoQMessageType get type => MoQMessageType.publishNamespaceOk;

  @override
  int get payloadLength => MoQWireFormat._varintSize64(requestId);

  @override
  Uint8List serialize() {
    final payload = Uint8List(payloadLength);
    final bytes = MoQWireFormat.encodeVarint64(requestId);
    payload.setAll(0, bytes);
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

  static PublishNamespaceOkMessage deserialize(Uint8List data) {
    final (requestId, _) = MoQWireFormat.decodeVarint64(data, 0);
    return PublishNamespaceOkMessage(requestId: requestId);
  }
}

/// PUBLISH_NAMESPACE_ERROR message (0x8)
///
/// Sent by relay when PUBLISH_NAMESPACE fails.
class PublishNamespaceErrorMessage extends MoQControlMessage {
  final Int64 requestId;
  final int errorCode;
  final ReasonPhrase errorReason;

  PublishNamespaceErrorMessage({
    required this.requestId,
    required this.errorCode,
    required this.errorReason,
  });

  @override
  MoQMessageType get type => MoQMessageType.publishNamespaceError;

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

  static PublishNamespaceErrorMessage deserialize(Uint8List data) {
    int offset = 0;

    final (requestId, len1) = MoQWireFormat.decodeVarint64(data, offset);
    offset += len1;

    final (errorCode, len2) = MoQWireFormat.decodeVarint(data, offset);
    offset += len2;

    final (reasonLen, len3) = MoQWireFormat.decodeVarint(data, offset);
    offset += len3;

    final reasonBytes = data.sublist(offset, offset + reasonLen);
    final reason = const Utf8Decoder().convert(reasonBytes);

    return PublishNamespaceErrorMessage(
      requestId: requestId,
      errorCode: errorCode,
      errorReason: ReasonPhrase(reason),
    );
  }
}

/// PUBLISH_NAMESPACE_DONE message (0x9)
///
/// Sent by publisher to indicate it will no longer publish to a namespace.
class PublishNamespaceDoneMessage extends MoQControlMessage {
  final List<Uint8List> trackNamespace;
  final int statusCode;
  final ReasonPhrase reason;

  PublishNamespaceDoneMessage({
    required this.trackNamespace,
    required this.statusCode,
    required this.reason,
  });

  @override
  MoQMessageType get type => MoQMessageType.publishNamespaceDone;

  @override
  int get payloadLength {
    int len = 0;
    len += _tupleSize(trackNamespace);
    len += MoQWireFormat._varintSize(statusCode);
    final reasonBytes = const Utf8Encoder().convert(reason.reason);
    len += MoQWireFormat._varintSize(reasonBytes.length) + reasonBytes.length;
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
    final reasonBytes = const Utf8Encoder().convert(reason.reason);
    final payload = Uint8List(payloadLength);
    int offset = 0;

    offset += _writeTuple(payload, offset, trackNamespace);
    offset += _writeVarint(payload, offset, statusCode);
    offset += _writeVarint(payload, offset, reasonBytes.length);
    payload.setAll(offset, reasonBytes);

    return _wrapMessage(payload);
  }

  int _writeVarint(Uint8List buffer, int offset, int value) {
    final bytes = MoQWireFormat.encodeVarint(value);
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

  static PublishNamespaceDoneMessage deserialize(Uint8List data) {
    int offset = 0;

    final (namespace, len1) = MoQWireFormat.decodeTuple(data, offset);
    offset += len1;

    final (statusCode, len2) = MoQWireFormat.decodeVarint(data, offset);
    offset += len2;

    final (reasonLen, len3) = MoQWireFormat.decodeVarint(data, offset);
    offset += len3;

    final reasonBytes = data.sublist(offset, offset + reasonLen);
    final reason = const Utf8Decoder().convert(reasonBytes);

    return PublishNamespaceDoneMessage(
      trackNamespace: namespace,
      statusCode: statusCode,
      reason: ReasonPhrase(reason),
    );
  }
}

/// PUBLISH_NAMESPACE_CANCEL message (0xC)
///
/// Sent by relay to cancel a previously accepted PUBLISH_NAMESPACE.
class PublishNamespaceCancelMessage extends MoQControlMessage {
  final List<Uint8List> trackNamespace;

  PublishNamespaceCancelMessage({
    required this.trackNamespace,
  });

  @override
  MoQMessageType get type => MoQMessageType.publishNamespaceCancel;

  @override
  int get payloadLength => _tupleSize(trackNamespace);

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
    offset += _writeTuple(payload, offset, trackNamespace);

    return _wrapMessage(payload);
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

  static PublishNamespaceCancelMessage deserialize(Uint8List data) {
    final (namespace, _) = MoQWireFormat.decodeTuple(data, 0);
    return PublishNamespaceCancelMessage(trackNamespace: namespace);
  }
}

// Note: PublishDoneMessage is defined in moq_messages_control.dart
