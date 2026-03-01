import 'dart:convert';
import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';

part 'moq_wire_format.dart';
part 'moq_messages_control.dart';
part 'moq_messages_control_extra.dart';
part 'moq_messages_data.dart';
part 'moq_messages_publish.dart';

/// Message Types defined in draft-ietf-moq-transport-14/16
enum MoQMessageType {
  // Control Messages (shared between draft-14 and draft-16)
  clientSetup(0x20),
  serverSetup(0x21),
  goaway(0x10),
  maxRequestId(0x15),
  requestsBlocked(0x1A),
  subscribe(0x3),
  subscribeOk(0x4),
  subscribeUpdate(0x2),
  unsubscribe(0xA),
  publishDone(0xB),
  publish(0x1D),
  publishOk(0x1E),
  fetch(0x16),
  fetchOk(0x18),
  fetchCancel(0x17),
  trackStatus(0xD),
  publishNamespace(0x6),
  publishNamespaceDone(0x9),
  publishNamespaceCancel(0xC),
  subscribeNamespace(0x11),

  // Draft-14 only messages (type codes reused in draft-16)
  subscribeError(0x5),       // draft-14: SUBSCRIBE_ERROR
  publishError(0x1F),        // draft-14: PUBLISH_ERROR
  fetchError(0x19),          // draft-14: FETCH_ERROR
  trackStatusOk(0xE),        // draft-14: TRACK_STATUS_OK
  trackStatusError(0xF),     // draft-14: TRACK_STATUS_ERROR
  publishNamespaceOk(0x7),   // draft-14: PUBLISH_NAMESPACE_OK
  publishNamespaceError(0x8),// draft-14: PUBLISH_NAMESPACE_ERROR
  subscribeNamespaceOk(0x12),  // draft-14: SUBSCRIBE_NAMESPACE_OK
  subscribeNamespaceError(0x13), // draft-14: SUBSCRIBE_NAMESPACE_ERROR
  unsubscribeNamespace(0x14),  // draft-14: UNSUBSCRIBE_NAMESPACE

  // Draft-16 new messages (type codes collide with draft-14 messages above)
  requestError(0x5),         // draft-16: replaces SUBSCRIBE_ERROR et al
  requestOk(0x7),            // draft-16: replaces PUBLISH_NAMESPACE_OK et al
  namespace_(0x8),           // draft-16: replaces PUBLISH_NAMESPACE_ERROR
  namespaceDone(0x0E),       // draft-16: replaces TRACK_STATUS_OK

  // Stream Types
  subgroupHeader(0x10),
  fetchHeader(0x05),

  // Datagram Types
  objectDatagram(0x00);

  final int value;
  const MoQMessageType(this.value);

  /// Version-aware type lookup.
  ///
  /// For type codes that differ between draft versions (0x5, 0x7, 0x8, 0xE),
  /// returns the appropriate enum entry based on the negotiated version.
  /// Returns null for type codes removed in the specified version.
  static MoQMessageType? fromValue(int value, {int version = MoQVersion.draft14}) {
    if (MoQVersion.isDraft16OrLater(version)) {
      // Draft-16 type resolution for colliding codes
      switch (value) {
        case 0x05: return requestError;
        case 0x07: return requestOk;
        case 0x08: return namespace_;
        case 0x0E: return namespaceDone;
        // Removed in draft-16
        case 0x0F: return null; // TRACK_STATUS_ERROR
        case 0x12: return null; // SUBSCRIBE_NAMESPACE_OK
        case 0x13: return null; // SUBSCRIBE_NAMESPACE_ERROR
        case 0x14: return null; // UNSUBSCRIBE_NAMESPACE
        case 0x19: return null; // FETCH_ERROR
        case 0x1F: return null; // PUBLISH_ERROR
      }
    }
    // Draft-14 or non-colliding types: use first match
    for (final type in values) {
      if (type.value == value) return type;
    }
    return objectDatagram; // Fallback for object datagram range
  }
}

/// Group Order values
enum GroupOrder {
  none(0x0),
  ascending(0x1),
  descending(0x2);

  final int value;
  const GroupOrder(this.value);

  static GroupOrder? fromValue(int value) {
    return GroupOrder.values.firstWhere(
      (order) => order.value == value,
      orElse: () => none,
    );
  }
}

/// Filter Types for SUBSCRIBE
enum FilterType {
  largestObject(0x2),
  nextGroupStart(0x1),
  absoluteStart(0x3),
  absoluteRange(0x4);

  final int value;
  const FilterType(this.value);

  static FilterType? fromValue(int value) {
    return FilterType.values.firstWhere(
      (type) => type.value == value,
      orElse: () => largestObject,
    );
  }
}

/// Object Status values
enum ObjectStatus {
  normal(0x0),
  doesNotExist(0x1),
  endOfGroup(0x3),
  endOfTrack(0x4),
  endOfSubgroup(0x5);

  final int value;
  const ObjectStatus(this.value);

  static ObjectStatus? fromValue(int value) {
    return ObjectStatus.values.firstWhere(
      (status) => status.value == value,
      orElse: () => normal,
    );
  }
}

/// Location structure - identifies a particular Object in a Group within a Track
class Location {
  final Int64 group;
  final Int64 object;

  const Location({
    required this.group,
    required this.object,
  });

  factory Location.zero() => Location(
        group: Int64(0),
        object: Int64(0),
      );

  /// Compare two locations
  bool isBefore(Location other) {
    if (group < other.group) return true;
    if (group > other.group) return false;
    return object < other.object;
  }

  bool isAfter(Location other) {
    if (group > other.group) return true;
    if (group < other.group) return false;
    return object > other.object;
  }

  @override
  String toString() => 'Location(group: $group, object: $object)';
}

/// Key-Value-Pair structure for MoQ parameters
///
/// Per draft-ietf-moq-transport-14 section 9.2.1:
/// - Even parameter types: value is encoded as a direct varint (use intValue)
/// - Odd parameter types: value is encoded as length-prefixed bytes (use value)
class KeyValuePair {
  final int type;
  final Uint8List? value;
  final int? intValue; // For even-type parameters (direct varint value)

  KeyValuePair({
    required this.type,
    this.value,
    this.intValue,
  });

  /// Returns true if this parameter type uses varint encoding (even types)
  bool get isVarintType => type % 2 == 0;

  /// Create a KeyValuePair for a varint parameter (even type)
  factory KeyValuePair.varint(int type, int value) {
    assert(type % 2 == 0, 'Varint parameters must have even type');
    return KeyValuePair(type: type, intValue: value);
  }

  /// Create a KeyValuePair for a buffer parameter (odd type)
  factory KeyValuePair.buffer(int type, Uint8List value) {
    assert(type % 2 == 1, 'Buffer parameters must have odd type');
    return KeyValuePair(type: type, value: value);
  }
}

/// Setup parameter types per draft-ietf-moq-transport-14 section 9.3.1
class SetupParameterType {
  /// PATH parameter (type 0x1, odd = buffer) - WebTransport path
  static const int path = 0x1;
  /// MAX_REQUEST_ID parameter (type 0x2, even = varint)
  static const int maxRequestId = 0x2;
  /// MAX_AUTH_TOKEN_CACHE_SIZE parameter (type 0x4, even = varint)
  static const int maxAuthTokenCacheSize = 0x4;
}

/// Reason Phrase structure
class ReasonPhrase {
  final String reason;

  const ReasonPhrase(this.reason);
}

/// MoQ Transport protocol version constants
class MoQVersion {
  static const int draft14 = 0xff00000e;
  static const int draft16 = 0xff000010;

  /// Draft-15+ uses delta-encoded Key-Value-Pairs
  static bool usesDeltaKvp(int version) => version >= 0xff00000f;

  /// Draft-16+ changes: ALPN negotiation, REQUEST_ERROR/OK, NAMESPACE messages,
  /// inline fields moved to params, SUBSCRIBE_NAMESPACE on bidi streams
  static bool isDraft16OrLater(int version) => version >= draft16;
}

/// Error codes defined in draft-ietf-moq-transport-14
class MoQErrorCode {
  static const int INTERNAL_ERROR = 0x0;
  static const int UNAUTHORIZED = 0x1;
  static const int PROTOCOL_VIOLATION = 0x2;
  static const int INVALID_MESSAGE = 0x3;
  static const int ID_RESERVED = 0x4;
  static const int INVALID_RANGE = 0x5;
  static const int VERSION_NOT_SUPPORTED = 0x6;
  static const int ROLE_MISMATCH = 0x7;
  static const int VERSION_FINAL_DIFFERS = 0x8;
  static const int TRACK_LIMIT_EXCEEDED = 0x9;
  static const int TOO_MANY_SUBSCRIPTIONS = 0xA;
  static const int TRACK_NOT_FOUND = 0xB;
  static const int TRACK_EXISTS = 0xC;
  static const int TRACK_PRIORITY_TOO_LOW = 0xD;
  static const int PENDING = 0xE;
  static const int TIMEOUT = 0xF;
  static const int IN_PROGRESS = 0x10;
  static const int SERVER_SHUTDOWN = 0x11;
  static const int TRANSPORT_ERROR = 0x12;
  static const int FLOW_CONTROL_ERROR = 0x13;
  static const int NO_SPACE = 0x14;
  static const int OBJECT_TOO_LARGE = 0x15;
  static const int KEY_UPDATE_NOT_SUPPORTED = 0x16;
  static const int KEY_UPDATE_PENDING = 0x17;
  static const int KEY_UPDATE_ERROR = 0x18;
  static const int ALREADY_CLOSED = 0x19;
  static const int INVALID_ENCODING = 0x1A;
  static const int REQUIRED_PARAMETER_MISSING = 0x1B;
  static const int PARAMETER_OUT_OF_RANGE = 0x1C;
  static const int CODE_UNAVAILABLE = 0x1D;
  static const int UNKNOWN_ROLE = 0x1E;

  static String? getName(int code) {
    const codes = {
      INTERNAL_ERROR: 'INTERNAL_ERROR',
      UNAUTHORIZED: 'UNAUTHORIZED',
      PROTOCOL_VIOLATION: 'PROTOCOL_VIOLATION',
      INVALID_MESSAGE: 'INVALID_MESSAGE',
      ID_RESERVED: 'ID_RESERVED',
      INVALID_RANGE: 'INVALID_RANGE',
      VERSION_NOT_SUPPORTED: 'VERSION_NOT_SUPPORTED',
      ROLE_MISMATCH: 'ROLE_MISMATCH',
      VERSION_FINAL_DIFFERS: 'VERSION_FINAL_DIFFERS',
      TRACK_LIMIT_EXCEEDED: 'TRACK_LIMIT_EXCEEDED',
      TOO_MANY_SUBSCRIPTIONS: 'TOO_MANY_SUBSCRIPTIONS',
      TRACK_NOT_FOUND: 'TRACK_NOT_FOUND',
      TRACK_EXISTS: 'TRACK_EXISTS',
      TRACK_PRIORITY_TOO_LOW: 'TRACK_PRIORITY_TOO_LOW',
      PENDING: 'PENDING',
      TIMEOUT: 'TIMEOUT',
      IN_PROGRESS: 'IN_PROGRESS',
      SERVER_SHUTDOWN: 'SERVER_SHUTDOWN',
      TRANSPORT_ERROR: 'TRANSPORT_ERROR',
      FLOW_CONTROL_ERROR: 'FLOW_CONTROL_ERROR',
      NO_SPACE: 'NO_SPACE',
      OBJECT_TOO_LARGE: 'OBJECT_TOO_LARGE',
      KEY_UPDATE_NOT_SUPPORTED: 'KEY_UPDATE_NOT_SUPPORTED',
      KEY_UPDATE_PENDING: 'KEY_UPDATE_PENDING',
      KEY_UPDATE_ERROR: 'KEY_UPDATE_ERROR',
      ALREADY_CLOSED: 'ALREADY_CLOSED',
      INVALID_ENCODING: 'INVALID_ENCODING',
      REQUIRED_PARAMETER_MISSING: 'REQUIRED_PARAMETER_MISSING',
      PARAMETER_OUT_OF_RANGE: 'PARAMETER_OUT_OF_RANGE',
      CODE_UNAVAILABLE: 'CODE_UNAVAILABLE',
      UNKNOWN_ROLE: 'UNKNOWN_ROLE',
    };
    return codes[code];
  }

  // Draft-16 additional session termination codes
  static const int DUPLICATE_TRACK_ALIAS = 0x5;
  static const int KEY_VALUE_FORMATTING_ERROR = 0x6;
  static const int TOO_MANY_REQUESTS = 0x7;
}

/// Request error codes for draft-16 REQUEST_ERROR message
class MoQRequestErrorCode {
  static const int DOES_NOT_EXIST = 0x10;
  static const int INVALID_RANGE = 0x11;
  static const int MALFORMED_TRACK = 0x12;
  static const int DUPLICATE_SUBSCRIPTION = 0x19;
  static const int UNINTERESTED = 0x20;
  static const int PREFIX_OVERLAP = 0x30;
  static const int RETRY = 0x0;
  static const int INTERNAL_ERROR = 0x1;
}

/// Subscribe parameter types for draft-16 (inline fields moved to params)
class SubscribeParameterType {
  static const int forward = 0x10;
  static const int subscriberPriority = 0x20;
  static const int subscriptionFilter = 0x21;
  static const int groupOrder = 0x22;
  static const int newGroupRequest = 0x32;
}

/// Track property types for draft-16
class TrackPropertyType {
  static const int expires = 0x8;
  static const int largestObject = 0x9;
}

/// Subscribe options for SUBSCRIBE_NAMESPACE in draft-16
enum SubscribeOptions {
  publishOnly(0x0),
  namespaceOnly(0x1),
  both(0x2);

  final int value;
  const SubscribeOptions(this.value);

  static SubscribeOptions? fromValue(int value) {
    for (final option in values) {
      if (option.value == value) return option;
    }
    return null;
  }
}
