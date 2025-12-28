import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moq_flutter/moq/protocol/moq_messages.dart';

void main() {
  group('ObjectDatagram', () {
    test('serialize with required fields and payload', () {
      final datagram = ObjectDatagram(
        trackAlias: Int64(1),
        groupId: Int64(10),
        objectId: Int64(5),
        publisherPriority: 128,
        payload: Uint8List.fromList([1, 2, 3, 4]),
      );
      final serialized = datagram.serialize();

      // Type (0x00) + Track Alias + Group ID + Object ID + Priority + Num Headers (0) + Payload Length + Payload
      expect(serialized[0], equals(0x00)); // Type
      expect(serialized[1], equals(1)); // Track Alias
      expect(serialized[2], equals(10)); // Group ID
      expect(serialized[3], equals(5)); // Object ID
      expect(serialized[4], equals(128)); // Priority
      expect(serialized[5], equals(0)); // No extension headers
      expect(serialized[6], equals(4)); // Payload length
      expect(serialized.sublist(7), equals([1, 2, 3, 4])); // Payload
    });

    test('serialize without objectId', () {
      final datagram = ObjectDatagram(
        trackAlias: Int64(1),
        groupId: Int64(10),
        publisherPriority: 128,
        payload: Uint8List.fromList([1, 2, 3]),
      );
      final serialized = datagram.serialize();

      // Type + Track Alias + Group ID (no Object ID) + Priority + Num Headers + Payload Length + Payload
      expect(serialized[0], equals(0x00)); // Type
      expect(serialized[1], equals(1)); // Track Alias
      expect(serialized[2], equals(10)); // Group ID
      expect(serialized[3], equals(128)); // Priority (skipped objectId)
      expect(serialized[4], equals(0)); // No extension headers
      expect(serialized[5], equals(3)); // Payload length
    });

    test('serialize with extension headers', () {
      final datagram = ObjectDatagram(
        trackAlias: Int64(1),
        groupId: Int64(10),
        objectId: Int64(5),
        publisherPriority: 128,
        extensionHeaders: [
          KeyValuePair(type: 0x0001, value: Uint8List.fromList([10, 20])),
        ],
        payload: Uint8List.fromList([1, 2, 3]),
      );
      final serialized = datagram.serialize();

      expect(serialized[0], equals(0x00)); // Type
      expect(serialized[1], equals(1)); // Track Alias
      expect(serialized[2], equals(10)); // Group ID
      expect(serialized[3], equals(5)); // Object ID
      expect(serialized[4], equals(128)); // Priority
      expect(serialized[5], equals(1)); // 1 extension header
      expect(serialized[6], equals(0x01)); // Header type low byte
      expect(serialized[7], equals(0x00)); // Header type high byte
      expect(serialized[8], equals(2)); // Header value length
      expect(serialized.sublist(9, 11), equals([10, 20])); // Header value
      expect(serialized[11], equals(3)); // Payload length
    });

    test('serialize with status (doesNotExist)', () {
      final datagram = ObjectDatagram(
        trackAlias: Int64(1),
        groupId: Int64(10),
        objectId: Int64(5),
        publisherPriority: 128,
        status: ObjectStatus.doesNotExist,
      );
      final serialized = datagram.serialize();

      expect(serialized[0], equals(0x01)); // Type (doesNotExist = 0x01)
      expect(serialized[1], equals(1)); // Track Alias
      expect(serialized[2], equals(10)); // Group ID
      expect(serialized[3], equals(5)); // Object ID
      expect(serialized[4], equals(128)); // Priority
      expect(serialized[5], equals(0)); // No extension headers
      expect(serialized[6], equals(0x01)); // Status (doesNotExist)
    });

    test('serialize with status (endOfGroup)', () {
      final datagram = ObjectDatagram(
        trackAlias: Int64(1),
        groupId: Int64(10),
        objectId: Int64(5),
        publisherPriority: 128,
        status: ObjectStatus.endOfGroup,
      );
      final serialized = datagram.serialize();

      expect(serialized[0], equals(0x03)); // Type (endOfGroup = 0x03)
      expect(serialized[5], equals(0)); // No extension headers
      expect(serialized[6], equals(0x03)); // Status (endOfGroup)
    });

    test('serialize with status (endOfTrack)', () {
      final datagram = ObjectDatagram(
        trackAlias: Int64(1),
        groupId: Int64(10),
        objectId: Int64(5),
        publisherPriority: 128,
        status: ObjectStatus.endOfTrack,
      );
      final serialized = datagram.serialize();

      expect(serialized[0], equals(0x04)); // Type (endOfTrack = 0x04)
      expect(serialized[5], equals(0)); // No extension headers
      expect(serialized[6], equals(0x04)); // Status (endOfTrack)
    });

    test('deserialize with payload', () {
      final data = Uint8List.fromList([
        0x00, // Type
        1, // Track Alias
        10, // Group ID
        5, // Object ID
        128, // Priority
        0, // No extension headers
        4, // Payload length
        1, 2, 3, 4, // Payload
      ]);
      final datagram = ObjectDatagram.deserialize(data);

      expect(datagram.trackAlias, equals(Int64(1)));
      expect(datagram.groupId, equals(Int64(10)));
      expect(datagram.objectId, equals(Int64(5)));
      expect(datagram.publisherPriority, equals(128));
      expect(datagram.status, equals(ObjectStatus.normal));
      expect(datagram.payload, equals([1, 2, 3, 4]));
    });

    test('deserialize without objectId', () {
      final data = Uint8List.fromList([
        0x00, // Type
        1, // Track Alias
        10, // Group ID
        128, // Priority (next byte is not varint, so it's priority)
        0, // No extension headers
        3, // Payload length
        1, 2, 3, // Payload
      ]);
      final datagram = ObjectDatagram.deserialize(data);

      expect(datagram.trackAlias, equals(Int64(1)));
      expect(datagram.groupId, equals(Int64(10)));
      expect(datagram.objectId, isNull);
      expect(datagram.publisherPriority, equals(128));
      expect(datagram.payload, equals([1, 2, 3]));
    });

    test('deserialize with extension headers', () {
      final data = Uint8List.fromList([
        0x00, // Type
        1, // Track Alias
        10, // Group ID
        5, // Object ID
        128, // Priority
        1, // 1 extension header
        0x01, 0x00, // Header type
        2, // Header value length
        10, 20, // Header value
        3, // Payload length
        1, 2, 3, // Payload
      ]);
      final datagram = ObjectDatagram.deserialize(data);

      expect(datagram.trackAlias, equals(Int64(1)));
      expect(datagram.extensionHeaders.length, equals(1));
      expect(datagram.extensionHeaders[0].type, equals(0x0001));
      expect(datagram.extensionHeaders[0].value, equals([10, 20]));
      expect(datagram.payload, equals([1, 2, 3]));
    });

    test('deserialize with status (doesNotExist)', () {
      final data = Uint8List.fromList([
        0x00, // Type
        1, // Track Alias
        10, // Group ID
        5, // Object ID
        128, // Priority
        0, // No extension headers
        0x01, // Status (doesNotExist)
      ]);
      final datagram = ObjectDatagram.deserialize(data);

      expect(datagram.status, equals(ObjectStatus.doesNotExist));
      expect(datagram.exists, isFalse);
    });

    test('deserialize with status (endOfGroup)', () {
      final data = Uint8List.fromList([
        0x00, // Type
        1, // Track Alias
        10, // Group ID
        5, // Object ID
        128, // Priority
        0, // No extension headers
        0x03, // Status (endOfGroup)
      ]);
      final datagram = ObjectDatagram.deserialize(data);

      expect(datagram.status, equals(ObjectStatus.endOfGroup));
      expect(datagram.isEndOfGroup, isTrue);
    });

    test('deserialize with status (endOfTrack)', () {
      final data = Uint8List.fromList([
        0x00, // Type
        1, // Track Alias
        10, // Group ID
        5, // Object ID
        128, // Priority
        0, // No extension headers
        0x04, // Status (endOfTrack)
      ]);
      final datagram = ObjectDatagram.deserialize(data);

      expect(datagram.status, equals(ObjectStatus.endOfTrack));
      expect(datagram.isEndOfTrack, isTrue);
    });

    test('round-trip serialization with payload', () {
      final original = ObjectDatagram(
        trackAlias: Int64(10),
        groupId: Int64(100),
        objectId: Int64(50),
        publisherPriority: 200,
        extensionHeaders: [
          KeyValuePair(type: 0x0001, value: Uint8List.fromList([1, 2])),
          KeyValuePair(type: 0x0002, value: Uint8List(0)),
        ],
        payload: Uint8List.fromList([10, 20, 30, 40, 50]),
      );

      final serialized = original.serialize();
      final deserialized = ObjectDatagram.deserialize(serialized);

      expect(deserialized.trackAlias, equals(original.trackAlias));
      expect(deserialized.groupId, equals(original.groupId));
      expect(deserialized.objectId, equals(original.objectId));
      expect(deserialized.publisherPriority, equals(original.publisherPriority));
      expect(deserialized.extensionHeaders.length, equals(original.extensionHeaders.length));
      expect(deserialized.extensionHeaders[0].type, equals(original.extensionHeaders[0].type));
      expect(deserialized.extensionHeaders[0].value, equals(original.extensionHeaders[0].value));
      expect(deserialized.payload, equals(original.payload));
    });

    test('round-trip serialization with status', () {
      final original = ObjectDatagram(
        trackAlias: Int64(5),
        groupId: Int64(50),
        objectId: Int64(25),
        publisherPriority: 150,
        status: ObjectStatus.endOfGroup,
      );

      final serialized = original.serialize();
      final deserialized = ObjectDatagram.deserialize(serialized);

      expect(deserialized.trackAlias, equals(original.trackAlias));
      expect(deserialized.groupId, equals(original.groupId));
      expect(deserialized.objectId, equals(original.objectId));
      expect(deserialized.publisherPriority, equals(original.publisherPriority));
      expect(deserialized.status, equals(original.status));
      expect(deserialized.isEndOfGroup, isTrue);
    });

    test('messageType getter returns correct type', () {
      final normal = ObjectDatagram(
        trackAlias: Int64(1),
        groupId: Int64(10),
        objectId: Int64(5),
        publisherPriority: 128,
        status: ObjectStatus.normal,
      );
      expect(normal.messageType, equals(0x00));

      final doesNotExist = ObjectDatagram(
        trackAlias: Int64(1),
        groupId: Int64(10),
        objectId: Int64(5),
        publisherPriority: 128,
        status: ObjectStatus.doesNotExist,
      );
      expect(doesNotExist.messageType, equals(0x01));

      final endOfGroup = ObjectDatagram(
        trackAlias: Int64(1),
        groupId: Int64(10),
        objectId: Int64(5),
        publisherPriority: 128,
        status: ObjectStatus.endOfGroup,
      );
      expect(endOfGroup.messageType, equals(0x03));

      final endOfTrack = ObjectDatagram(
        trackAlias: Int64(1),
        groupId: Int64(10),
        objectId: Int64(5),
        publisherPriority: 128,
        status: ObjectStatus.endOfTrack,
      );
      expect(endOfTrack.messageType, equals(0x04));
    });

    test('convenience getters', () {
      final normal = ObjectDatagram(
        trackAlias: Int64(1),
        groupId: Int64(10),
        objectId: Int64(5),
        publisherPriority: 128,
        status: ObjectStatus.normal,
        payload: Uint8List.fromList([1, 2, 3]),
      );
      expect(normal.isNormal, isTrue);
      expect(normal.exists, isTrue);
      expect(normal.isEndOfGroup, isFalse);
      expect(normal.isEndOfTrack, isFalse);

      final notExist = ObjectDatagram(
        trackAlias: Int64(1),
        groupId: Int64(10),
        objectId: Int64(5),
        publisherPriority: 128,
        status: ObjectStatus.doesNotExist,
      );
      expect(notExist.isNormal, isFalse);
      expect(notExist.exists, isFalse);

      final endGroup = ObjectDatagram(
        trackAlias: Int64(1),
        groupId: Int64(10),
        objectId: Int64(5),
        publisherPriority: 128,
        status: ObjectStatus.endOfGroup,
      );
      expect(endGroup.isEndOfGroup, isTrue);

      final endTrack = ObjectDatagram(
        trackAlias: Int64(1),
        groupId: Int64(10),
        objectId: Int64(5),
        publisherPriority: 128,
        status: ObjectStatus.endOfTrack,
      );
      expect(endTrack.isEndOfTrack, isTrue);
    });
  });

  group('SubgroupHeader', () {
    test('serialize with required fields', () {
      final header = SubgroupHeader(
        trackAlias: Int64(1),
        groupId: Int64(10),
        subgroupId: Int64(5),
        publisherPriority: 128,
      );
      final serialized = header.serialize();

      // Type (0x10) + Track Alias + Group ID + Subgroup ID + Priority + Num Headers
      expect(serialized[0], equals(0x10)); // Type
      expect(serialized[1], equals(1)); // Track Alias
      expect(serialized[2], equals(10)); // Group ID
      expect(serialized[3], equals(5)); // Subgroup ID
      expect(serialized[4], equals(128)); // Priority
      expect(serialized[5], equals(0)); // No extension headers
    });

    test('serialize with firstObjectId', () {
      final header = SubgroupHeader(
        trackAlias: Int64(1),
        groupId: Int64(10),
        subgroupId: Int64(5),
        firstObjectId: Int64(20),
        publisherPriority: 128,
      );
      final serialized = header.serialize();

      expect(serialized[0], equals(0x10)); // Type
      expect(serialized[1], equals(1)); // Track Alias
      expect(serialized[2], equals(10)); // Group ID
      expect(serialized[3], equals(5)); // Subgroup ID
      expect(serialized[4], equals(20)); // First Object ID
      expect(serialized[5], equals(128)); // Priority
    });

    test('serialize with extension headers', () {
      final header = SubgroupHeader(
        trackAlias: Int64(1),
        groupId: Int64(10),
        subgroupId: Int64(5),
        publisherPriority: 128,
        extensionHeaders: [
          KeyValuePair(type: 0x0001, value: Uint8List.fromList([1])),
        ],
      );
      final serialized = header.serialize();

      expect(serialized[4], equals(128)); // Priority
      expect(serialized[5], equals(1)); // 1 extension header
      expect(serialized[6], equals(0x01)); // Header type
    });

    test('deserialize with required fields', () {
      final data = Uint8List.fromList([
        0x10, // Type
        1, // Track Alias
        10, // Group ID
        5, // Subgroup ID
        128, // Priority
        0, // No extension headers
      ]);
      final header = SubgroupHeader.deserialize(data);

      expect(header.trackAlias, equals(Int64(1)));
      expect(header.groupId, equals(Int64(10)));
      expect(header.subgroupId, equals(Int64(5)));
      expect(header.publisherPriority, equals(128));
      expect(header.firstObjectId, isNull);
    });

    test('deserialize with firstObjectId', () {
      final data = Uint8List.fromList([
        0x10, // Type
        1, // Track Alias
        10, // Group ID
        5, // Subgroup ID
        20, // First Object ID
        128, // Priority
        0, // No extension headers
      ]);
      final header = SubgroupHeader.deserialize(data);

      expect(header.trackAlias, equals(Int64(1)));
      expect(header.groupId, equals(Int64(10)));
      expect(header.subgroupId, equals(Int64(5)));
      expect(header.firstObjectId, equals(Int64(20)));
      expect(header.publisherPriority, equals(128));
    });

    test('deserialize with extension headers', () {
      final data = Uint8List.fromList([
        0x10, // Type
        1, // Track Alias
        10, // Group ID
        5, // Subgroup ID
        128, // Priority
        1, // 1 extension header
        0x01, 0x00, // Header type
        1, // Header value length
        10, // Header value
      ]);
      final header = SubgroupHeader.deserialize(data);

      expect(header.publisherPriority, equals(128));
      expect(header.extensionHeaders.length, equals(1));
      expect(header.extensionHeaders[0].type, equals(0x0001));
      expect(header.extensionHeaders[0].value, equals([10]));
    });

    test('round-trip serialization', () {
      final original = SubgroupHeader(
        trackAlias: Int64(10),
        groupId: Int64(100),
        subgroupId: Int64(50),
        firstObjectId: Int64(25),
        publisherPriority: 200,
        extensionHeaders: [
          KeyValuePair(type: 0x0001, value: Uint8List.fromList([1, 2])),
        ],
      );

      final serialized = original.serialize();
      final deserialized = SubgroupHeader.deserialize(serialized);

      expect(deserialized.trackAlias, equals(original.trackAlias));
      expect(deserialized.groupId, equals(original.groupId));
      expect(deserialized.subgroupId, equals(original.subgroupId));
      expect(deserialized.firstObjectId, equals(original.firstObjectId));
      expect(deserialized.publisherPriority, equals(original.publisherPriority));
      expect(deserialized.extensionHeaders.length, equals(original.extensionHeaders.length));
    });
  });

  group('SubgroupObject', () {
    test('serialize with payload', () {
      final obj = SubgroupObject(
        objectId: Int64(5),
        publisherPriority: 128,
        payload: Uint8List.fromList([1, 2, 3]),
      );
      final serialized = obj.serialize();

      // Object ID + Priority + Num Headers + Payload Length + Payload
      expect(serialized[0], equals(5)); // Object ID
      expect(serialized[1], equals(128)); // Priority
      expect(serialized[2], equals(0)); // No extension headers
      expect(serialized[3], equals(3)); // Payload length
      expect(serialized.sublist(4), equals([1, 2, 3])); // Payload
    });

    test('serialize without objectId', () {
      final obj = SubgroupObject(
        publisherPriority: 128,
        payload: Uint8List.fromList([1, 2]),
      );
      final serialized = obj.serialize();

      // Priority + Num Headers + Payload Length + Payload
      expect(serialized[0], equals(128)); // Priority
      expect(serialized[1], equals(0)); // No extension headers
      expect(serialized[2], equals(2)); // Payload length
    });

    test('serialize with extension headers', () {
      final obj = SubgroupObject(
        objectId: Int64(5),
        publisherPriority: 128,
        extensionHeaders: [
          KeyValuePair(type: 0x0001, value: Uint8List.fromList([1])),
        ],
        payload: Uint8List.fromList([1, 2, 3]),
      );
      final serialized = obj.serialize();

      expect(serialized[0], equals(5)); // Object ID
      expect(serialized[1], equals(128)); // Priority
      expect(serialized[2], equals(1)); // 1 extension header
      expect(serialized[3], equals(0x01)); // Header type
    });

    test('serialize with status', () {
      final obj = SubgroupObject(
        objectId: Int64(5),
        publisherPriority: 128,
        status: ObjectStatus.endOfGroup,
      );
      final serialized = obj.serialize();

      expect(serialized[0], equals(5)); // Object ID
      expect(serialized[1], equals(128)); // Priority
      expect(serialized[2], equals(0)); // No extension headers
      expect(serialized[3], equals(0x03)); // Status (endOfGroup)
    });

    test('deserialize with payload', () {
      final data = Uint8List.fromList([
        5, // Object ID
        128, // Priority
        0, // No extension headers
        3, // Payload length
        1, 2, 3, // Payload
      ]);
      final obj = SubgroupObject.deserialize(data);

      expect(obj.objectId, equals(Int64(5)));
      expect(obj.publisherPriority, equals(128));
      expect(obj.status, equals(ObjectStatus.normal));
      expect(obj.payload, equals([1, 2, 3]));
    });

    test('deserialize without objectId', () {
      final data = Uint8List.fromList([
        128, // Priority
        0, // No extension headers
        2, // Payload length
        1, 2, // Payload
      ]);
      final obj = SubgroupObject.deserialize(data, hasObjectId: false);

      expect(obj.objectId, isNull);
      expect(obj.publisherPriority, equals(128));
      expect(obj.payload, equals([1, 2]));
    });

    test('deserialize with status', () {
      final data = Uint8List.fromList([
        5, // Object ID
        128, // Priority
        0, // No extension headers
        0x03, // Status (endOfGroup)
      ]);
      final obj = SubgroupObject.deserialize(data);

      expect(obj.objectId, equals(Int64(5)));
      expect(obj.publisherPriority, equals(128));
      expect(obj.status, equals(ObjectStatus.endOfGroup));
      expect(obj.isEndOfGroup, isTrue);
    });

    test('deserialize with extension headers', () {
      final data = Uint8List.fromList([
        5, // Object ID
        128, // Priority
        1, // 1 extension header
        0x01, 0x00, // Header type
        1, // Header value length
        10, // Header value
        3, // Payload length
        1, 2, 3, // Payload
      ]);
      final obj = SubgroupObject.deserialize(data);

      expect(obj.objectId, equals(Int64(5)));
      expect(obj.publisherPriority, equals(128));
      expect(obj.extensionHeaders.length, equals(1));
      expect(obj.extensionHeaders[0].type, equals(0x0001));
      expect(obj.extensionHeaders[0].value, equals([10]));
    });

    test('round-trip serialization with payload', () {
      final original = SubgroupObject(
        objectId: Int64(10),
        publisherPriority: 200,
        extensionHeaders: [
          KeyValuePair(type: 0x0001, value: Uint8List.fromList([1])),
        ],
        payload: Uint8List.fromList([1, 2, 3, 4]),
      );

      final serialized = original.serialize();
      final deserialized = SubgroupObject.deserialize(serialized);

      expect(deserialized.objectId, equals(original.objectId));
      expect(deserialized.publisherPriority, equals(original.publisherPriority));
      expect(deserialized.extensionHeaders.length, equals(original.extensionHeaders.length));
      expect(deserialized.payload, equals(original.payload));
    });

    test('round-trip serialization with status', () {
      final original = SubgroupObject(
        objectId: Int64(5),
        publisherPriority: 150,
        status: ObjectStatus.doesNotExist,
      );

      final serialized = original.serialize();
      final deserialized = SubgroupObject.deserialize(serialized);

      expect(deserialized.objectId, equals(original.objectId));
      expect(deserialized.publisherPriority, equals(original.publisherPriority));
      expect(deserialized.status, equals(original.status));
      expect(deserialized.exists, isFalse);
    });

    test('convenience getters', () {
      final normal = SubgroupObject(
        objectId: Int64(5),
        publisherPriority: 128,
        status: ObjectStatus.normal,
        payload: Uint8List.fromList([1, 2, 3]),
      );
      expect(normal.isNormal, isTrue);
      expect(normal.exists, isTrue);
      expect(normal.isEndOfGroup, isFalse);
      expect(normal.isEndOfTrack, isFalse);

      final notExist = SubgroupObject(
        objectId: Int64(5),
        publisherPriority: 128,
        status: ObjectStatus.doesNotExist,
      );
      expect(notExist.exists, isFalse);

      final endGroup = SubgroupObject(
        objectId: Int64(5),
        publisherPriority: 128,
        status: ObjectStatus.endOfGroup,
      );
      expect(endGroup.isEndOfGroup, isTrue);

      final endTrack = SubgroupObject(
        objectId: Int64(5),
        publisherPriority: 128,
        status: ObjectStatus.endOfTrack,
      );
      expect(endTrack.isEndOfTrack, isTrue);
    });
  });

  group('MoQObject', () {
    test('location getter', () {
      final obj = MoQObject(
        trackNamespace: [Uint8List.fromList([116, 101, 115, 116])],
        trackName: Uint8List.fromList([116, 114, 107]),
        groupId: Int64(10),
        objectId: Int64(5),
        publisherPriority: 128,
        forwardingPreference: ObjectForwardingPreference.datagram,
        status: ObjectStatus.normal,
        payload: Uint8List.fromList([1, 2, 3]),
      );

      expect(obj.location.group, equals(Int64(10)));
      expect(obj.location.object, equals(Int64(5)));
    });

    test('toObjectDatagram', () {
      final obj = MoQObject(
        trackNamespace: [Uint8List.fromList([116, 101, 115, 116])],
        trackName: Uint8List.fromList([116, 114, 107]),
        groupId: Int64(10),
        objectId: Int64(5),
        publisherPriority: 128,
        forwardingPreference: ObjectForwardingPreference.datagram,
        status: ObjectStatus.normal,
        payload: Uint8List.fromList([1, 2, 3]),
      );

      final datagram = obj.toObjectDatagram(Int64(100));
      expect(datagram.trackAlias, equals(Int64(100)));
      expect(datagram.groupId, equals(obj.groupId));
      expect(datagram.objectId, equals(obj.objectId));
      expect(datagram.publisherPriority, equals(obj.publisherPriority));
      expect(datagram.status, equals(obj.status));
      expect(datagram.payload, equals(obj.payload));
    });

    test('toSubgroupObject', () {
      final obj = MoQObject(
        trackNamespace: [Uint8List.fromList([116, 101, 115, 116])],
        trackName: Uint8List.fromList([116, 114, 107]),
        groupId: Int64(10),
        objectId: Int64(5),
        publisherPriority: 128,
        forwardingPreference: ObjectForwardingPreference.subgroup,
        status: ObjectStatus.normal,
        payload: Uint8List.fromList([1, 2, 3]),
      );

      final subgroupObj = obj.toSubgroupObject();
      expect(subgroupObj.objectId, equals(obj.objectId));
      expect(subgroupObj.publisherPriority, equals(obj.publisherPriority));
      expect(subgroupObj.status, equals(obj.status));
      expect(subgroupObj.payload, equals(obj.payload));
    });

    test('convenience getters', () {
      final normal = MoQObject(
        trackNamespace: [Uint8List.fromList([116, 101, 115, 116])],
        trackName: Uint8List.fromList([116, 114, 107]),
        groupId: Int64(10),
        objectId: Int64(5),
        publisherPriority: 128,
        forwardingPreference: ObjectForwardingPreference.datagram,
        status: ObjectStatus.normal,
        payload: Uint8List.fromList([1, 2, 3]),
      );
      expect(normal.isNormal, isTrue);
      expect(normal.exists, isTrue);

      final notExist = MoQObject(
        trackNamespace: [Uint8List.fromList([116, 101, 115, 116])],
        trackName: Uint8List.fromList([116, 114, 107]),
        groupId: Int64(10),
        objectId: Int64(5),
        publisherPriority: 128,
        forwardingPreference: ObjectForwardingPreference.datagram,
        status: ObjectStatus.doesNotExist,
      );
      expect(notExist.exists, isFalse);

      final endGroup = MoQObject(
        trackNamespace: [Uint8List.fromList([116, 101, 115, 116])],
        trackName: Uint8List.fromList([116, 114, 107]),
        groupId: Int64(10),
        objectId: Int64(5),
        publisherPriority: 128,
        forwardingPreference: ObjectForwardingPreference.datagram,
        status: ObjectStatus.endOfGroup,
      );
      expect(endGroup.isEndOfGroup, isTrue);

      final endTrack = MoQObject(
        trackNamespace: [Uint8List.fromList([116, 101, 115, 116])],
        trackName: Uint8List.fromList([116, 114, 107]),
        groupId: Int64(10),
        objectId: Int64(5),
        publisherPriority: 128,
        forwardingPreference: ObjectForwardingPreference.datagram,
        status: ObjectStatus.endOfTrack,
      );
      expect(endTrack.isEndOfTrack, isTrue);
    });
  });

  group('ObjectForwardingPreference', () {
    test('enum values exist', () {
      expect(ObjectForwardingPreference.subgroup, isNotNull);
      expect(ObjectForwardingPreference.datagram, isNotNull);
    });
  });

  group('Location', () {
    test('zero factory', () {
      final location = Location.zero();
      expect(location.group, equals(Int64(0)));
      expect(location.object, equals(Int64(0)));
    });

    test('constructor with values', () {
      final location = Location(group: Int64(10), object: Int64(5));
      expect(location.group, equals(Int64(10)));
      expect(location.object, equals(Int64(5)));
    });
  });

  group('KeyValuePair', () {
    test('constructor with value', () {
      final pair = KeyValuePair(
        type: 0x0001,
        value: Uint8List.fromList([1, 2, 3]),
      );
      expect(pair.type, equals(0x0001));
      expect(pair.value, equals([1, 2, 3]));
    });

    test('constructor without value', () {
      final pair = KeyValuePair(type: 0x0002);
      expect(pair.type, equals(0x0002));
      expect(pair.value, isNull);
    });
  });
}
