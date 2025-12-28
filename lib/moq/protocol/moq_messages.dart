import 'dart:convert';
import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';

part 'moq_wire_format.dart';
part 'moq_messages_control.dart';
part 'moq_messages_control_extra.dart';
part 'moq_messages_data.dart';

/// Message Types defined in draft-ietf-moq-transport-14
enum MoQMessageType {
  // Control Messages
  clientSetup(0x20),
  serverSetup(0x21),
  goaway(0x10),
  maxRequestId(0x15),
  requestsBlocked(0x1A),
  subscribe(0x3),
  subscribeOk(0x4),
  subscribeError(0x5),
  subscribeUpdate(0x2),
  unsubscribe(0xA),
  publishDone(0xB),
  publish(0x1D),
  publishOk(0x1E),
  publishError(0x1F),
  fetch(0x16),
  fetchOk(0x18),
  fetchError(0x19),
  fetchCancel(0x17),
  trackStatus(0xD),
  trackStatusOk(0xE),
  trackStatusError(0xF),
  publishNamespace(0x6),
  publishNamespaceOk(0x7),
  publishNamespaceError(0x8),
  publishNamespaceDone(0x9),
  publishNamespaceCancel(0xC),
  subscribeNamespace(0x11),
  subscribeNamespaceOk(0x12),
  subscribeNamespaceError(0x13),
  unsubscribeNamespace(0x14),

  // Stream Types
  subgroupHeader(0x10),
  fetchHeader(0x05),

  // Datagram Types
  objectDatagram(0x00);

  final int value;
  const MoQMessageType(this.value);

  static MoQMessageType? fromValue(int value) {
    return MoQMessageType.values.firstWhere(
      (type) => type.value == value,
      orElse: () => objectDatagram, // Fallback for object datagram range
    );
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
  endOfTrack(0x4);

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

/// Key-Value-Pair structure
class KeyValuePair {
  final int type;
  final Uint8List? value;

  KeyValuePair({
    required this.type,
    this.value,
  });
}

/// Reason Phrase structure
class ReasonPhrase {
  final String reason;

  const ReasonPhrase(this.reason);
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
}
