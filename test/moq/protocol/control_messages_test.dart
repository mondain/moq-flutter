import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moq_flutter/moq/protocol/moq_messages.dart';

void main() {
  group('ClientSetupMessage', () {
    test('serialize with versions only', () {
      final message = ClientSetupMessage(supportedVersions: [14, 15]);
      final serialized = message.serialize();

      // Type (0x20 = 32) + Length (16-bit) + num_versions (1) + versions + num_params (0)
      expect(serialized[0], equals(0x20));
      expect(serialized[1], equals(0x00)); // Length high byte
      expect(serialized[2], equals(0x04)); // Length low byte (4 bytes payload)
      expect(serialized[3], equals(2)); // 2 versions
      expect(serialized[4], equals(14)); // version 14
      expect(serialized[5], equals(15)); // version 15
      expect(serialized[6], equals(0)); // 0 parameters
    });

    test('serialize with parameters', () {
      final message = ClientSetupMessage(
        supportedVersions: [14],
        parameters: [
          KeyValuePair(type: 0x0001, value: Uint8List.fromList([1, 2, 3])),
        ],
      );
      final serialized = message.serialize();

      expect(serialized[0], equals(0x20));
      expect(serialized[3], equals(1)); // 1 version
      expect(serialized[4], equals(14)); // version 14
      expect(serialized[5], equals(1)); // 1 parameter
      expect(serialized[6], equals(0x01)); // param type low byte
      expect(serialized[7], equals(0x00)); // param type high byte
      expect(serialized[8], equals(3)); // value length
      expect(serialized.sublist(9, 12), equals([1, 2, 3])); // value
    });

    test('deserialize with versions only', () {
      // num_versions (2) + versions (14, 15) + num_params (0)
      final data = Uint8List.fromList([2, 14, 15, 0]);
      final message = ClientSetupMessage.deserialize(data);

      expect(message.supportedVersions, equals([14, 15]));
      expect(message.parameters, isEmpty);
      expect(message.type, equals(MoQMessageType.clientSetup));
    });

    test('deserialize with parameters', () {
      // num_versions (1) + version (14) + num_params (1) + param type (0x0001) + len (3) + value
      final data = Uint8List.fromList([
        1, 14, // versions
        1, // num params
        0x01, 0x00, 3, 1, 2, 3, // parameter
      ]);
      final message = ClientSetupMessage.deserialize(data);

      expect(message.supportedVersions, equals([14]));
      expect(message.parameters.length, equals(1));
      expect(message.parameters[0].type, equals(0x0001));
      expect(message.parameters[0].value, equals([1, 2, 3]));
    });

    test('round-trip serialization', () {
      final original = ClientSetupMessage(
        supportedVersions: [14, 15],
        parameters: [
          KeyValuePair(type: 0x0001, value: Uint8List.fromList([1, 2])),
          KeyValuePair(type: 0x0002, value: Uint8List(0)),
        ],
      );

      final serialized = original.serialize();
      // Skip type and length for deserialize
      final payload = serialized.sublist(3);
      final deserialized = ClientSetupMessage.deserialize(payload);

      expect(deserialized.supportedVersions, equals(original.supportedVersions));
      expect(deserialized.parameters.length, equals(original.parameters.length));
      expect(deserialized.parameters[0].type, equals(original.parameters[0].type));
      expect(deserialized.parameters[0].value, equals(original.parameters[0].value));
      expect(deserialized.parameters[1].type, equals(original.parameters[1].type));
      expect(deserialized.parameters[1].value, equals(original.parameters[1].value));
    });
  });

  group('ServerSetupMessage', () {
    test('serialize with version only', () {
      final message = ServerSetupMessage(selectedVersion: 14);
      final serialized = message.serialize();

      expect(serialized[0], equals(0x21));
      expect(serialized[1], equals(0x00)); // Length high byte
      expect(serialized[2], equals(0x02)); // Length low byte
      expect(serialized[3], equals(14)); // selected version
      expect(serialized[4], equals(0)); // 0 parameters
    });

    test('serialize with parameters', () {
      final message = ServerSetupMessage(
        selectedVersion: 14,
        parameters: [
          KeyValuePair(type: 0x0001, value: Uint8List.fromList([1, 2, 3])),
        ],
      );
      final serialized = message.serialize();

      expect(serialized[0], equals(0x21));
      expect(serialized[3], equals(14)); // selected version
      expect(serialized[4], equals(1)); // 1 parameter
      expect(serialized[5], equals(0x01)); // param type low byte
      expect(serialized[6], equals(0x00)); // param type high byte
      expect(serialized[7], equals(3)); // value length
      expect(serialized.sublist(8, 11), equals([1, 2, 3])); // value
    });

    test('deserialize with version only', () {
      final data = Uint8List.fromList([14, 0]);
      final message = ServerSetupMessage.deserialize(data);

      expect(message.selectedVersion, equals(14));
      expect(message.parameters, isEmpty);
      expect(message.type, equals(MoQMessageType.serverSetup));
    });

    test('deserialize with parameters', () {
      // version (14) + num_params (1) + param type (0x0001) + len (3) + value
      final data = Uint8List.fromList([14, 1, 0x01, 0x00, 3, 1, 2, 3]);
      final message = ServerSetupMessage.deserialize(data);

      expect(message.selectedVersion, equals(14));
      expect(message.parameters.length, equals(1));
      expect(message.parameters[0].type, equals(0x0001));
      expect(message.parameters[0].value, equals([1, 2, 3]));
    });

    test('round-trip serialization', () {
      final original = ServerSetupMessage(
        selectedVersion: 15,
        parameters: [
          KeyValuePair(type: 0x0002, value: Uint8List.fromList([4, 5])),
        ],
      );

      final serialized = original.serialize();
      final payload = serialized.sublist(3);
      final deserialized = ServerSetupMessage.deserialize(payload);

      expect(deserialized.selectedVersion, equals(original.selectedVersion));
      expect(deserialized.parameters.length, equals(original.parameters.length));
      expect(deserialized.parameters[0].type, equals(original.parameters[0].type));
      expect(deserialized.parameters[0].value, equals(original.parameters[0].value));
    });
  });

  group('SubscribeMessage', () {
    test('serialize with required fields only', () {
      final message = SubscribeMessage(
        requestId: Int64(1),
        trackNamespace: [Uint8List.fromList([116, 101, 115, 116])],
        trackName: Uint8List.fromList([116, 114, 107]),
        subscriberPriority: 128,
        groupOrder: GroupOrder.none,
        forward: 1,
        filterType: FilterType.largestObject,
      );
      final serialized = message.serialize();

      expect(serialized[0], equals(0x03)); // Type
      expect(serialized[3], equals(1)); // Request ID
      expect(serialized[4], equals(1)); // Namespace count
      expect(serialized[5], equals(4)); // Namespace element length
      expect(serialized.sublist(6, 10), equals([116, 101, 115, 116])); // 'test'
      expect(serialized[10], equals(3)); // Track name length
      expect(serialized.sublist(11, 14), equals([116, 114, 107])); // 'trk'
      expect(serialized[14], equals(128)); // Priority
      expect(serialized[15], equals(0)); // Group Order
      expect(serialized[16], equals(1)); // Forward
      expect(serialized[17], equals(0)); // Filter Type
    });

    test('serialize with start location', () {
      final message = SubscribeMessage(
        requestId: Int64(1),
        trackNamespace: [Uint8List.fromList([116, 101, 115, 116])],
        trackName: Uint8List.fromList([116, 114, 107]),
        subscriberPriority: 128,
        groupOrder: GroupOrder.none,
        forward: 1,
        filterType: FilterType.absoluteStart,
        startLocation: Location(group: Int64(10), object: Int64(5)),
      );
      final serialized = message.serialize();

      expect(serialized[17], equals(2)); // Filter Type (absoluteStart)
      expect(serialized[18], equals(10)); // Group
      expect(serialized[19], equals(5)); // Object
    });

    test('deserialize with required fields only', () {
      final data = Uint8List.fromList([
        1, // Request ID
        1, // Namespace count
        4, 116, 101, 115, 116, // Namespace: 'test'
        3, 116, 114, 107, // Track name: 'trk'
        128, // Priority
        0, // Group Order
        1, // Forward
        0, // Filter Type
        0, // No parameters
      ]);
      final message = SubscribeMessage.deserialize(data);

      expect(message.requestId, equals(Int64(1)));
      expect(message.trackNamespace.length, equals(1));
      expect(message.trackNamespace[0], equals([116, 101, 115, 116]));
      expect(message.trackName, equals([116, 114, 107]));
      expect(message.subscriberPriority, equals(128));
      expect(message.groupOrder, equals(GroupOrder.none));
      expect(message.forward, equals(1));
      expect(message.filterType, equals(FilterType.largestObject));
      expect(message.startLocation, isNull);
    });

    test('deserialize with start location', () {
      final data = Uint8List.fromList([
        1, // Request ID
        1, // Namespace count
        4, 116, 101, 115, 116, // Namespace: 'test'
        3, 116, 114, 107, // Track name: 'trk'
        128, // Priority
        0, // Group Order
        1, // Forward
        2, // Filter Type (absoluteStart)
        10, 5, // Start Location (group=10, object=5)
        0, // No parameters
      ]);
      final message = SubscribeMessage.deserialize(data);

      expect(message.filterType, equals(FilterType.absoluteStart));
      expect(message.startLocation, isNotNull);
      expect(message.startLocation!.group, equals(Int64(10)));
      expect(message.startLocation!.object, equals(Int64(5)));
    });

    test('round-trip serialization', () {
      final original = SubscribeMessage(
        requestId: Int64(5),
        trackNamespace: [
          Uint8List.fromList([109, 111, 113]), // 'moq'
          Uint8List.fromList([101, 120, 97, 109, 112, 108, 101]), // 'example'
        ],
        trackName: Uint8List.fromList([118, 105, 100, 101, 111]), // 'video'
        subscriberPriority: 200,
        groupOrder: GroupOrder.ascending,
        forward: 0,
        filterType: FilterType.absoluteRange,
        startLocation: Location(group: Int64(100), object: Int64(50)),
        endGroup: Int64(200),
        parameters: [
          KeyValuePair(type: 0x0001, value: Uint8List.fromList([10])),
        ],
      );

      final serialized = original.serialize();
      final payload = serialized.sublist(3);
      final deserialized = SubscribeMessage.deserialize(payload);

      expect(deserialized.requestId, equals(original.requestId));
      expect(deserialized.trackNamespace.length, equals(original.trackNamespace.length));
      expect(deserialized.trackName, equals(original.trackName));
      expect(deserialized.subscriberPriority, equals(original.subscriberPriority));
      expect(deserialized.groupOrder, equals(original.groupOrder));
      expect(deserialized.forward, equals(original.forward));
      expect(deserialized.filterType, equals(original.filterType));
      expect(deserialized.startLocation!.group, equals(original.startLocation!.group));
      expect(deserialized.startLocation!.object, equals(original.startLocation!.object));
      expect(deserialized.endGroup, equals(original.endGroup));
      expect(deserialized.parameters.length, equals(original.parameters.length));
    });
  });

  group('SubscribeOkMessage', () {
    test('serialize with required fields', () {
      final message = SubscribeOkMessage(
        requestId: Int64(1),
        trackAlias: Int64(10),
        expires: Int64(60),
        groupOrder: GroupOrder.ascending,
        contentExists: 1,
      );
      final serialized = message.serialize();

      expect(serialized[0], equals(0x04)); // Type
      expect(serialized[3], equals(1)); // Request ID
      expect(serialized[4], equals(10)); // Track Alias
      expect(serialized[5], equals(60)); // Expires
      expect(serialized[6], equals(1)); // Group Order
      expect(serialized[7], equals(1)); // Content Exists
    });

    test('deserialize with required fields', () {
      final data = Uint8List.fromList([
        1, // Request ID
        10, // Track Alias
        60, // Expires
        1, // Group Order
        1, // Content Exists
        0, // No parameters
      ]);
      final message = SubscribeOkMessage.deserialize(data);

      expect(message.requestId, equals(Int64(1)));
      expect(message.trackAlias, equals(Int64(10)));
      expect(message.expires, equals(Int64(60)));
      expect(message.groupOrder, equals(GroupOrder.ascending));
      expect(message.contentExists, equals(1));
    });

    test('serialize with largest location', () {
      final message = SubscribeOkMessage(
        requestId: Int64(1),
        trackAlias: Int64(10),
        expires: Int64(60),
        groupOrder: GroupOrder.ascending,
        contentExists: 1,
        largestLocation: Location(group: Int64(100), object: Int64(50)),
      );
      final serialized = message.serialize();

      expect(serialized[7], equals(1)); // Content Exists
      expect(serialized[8], equals(100)); // Group
      expect(serialized[9], equals(50)); // Object
    });

    test('round-trip serialization', () {
      final original = SubscribeOkMessage(
        requestId: Int64(5),
        trackAlias: Int64(20),
        expires: Int64(120),
        groupOrder: GroupOrder.descending,
        contentExists: 1,
        largestLocation: Location(group: Int64(500), object: Int64(250)),
        parameters: [
          KeyValuePair(type: 0x0001, value: Uint8List.fromList([1])),
        ],
      );

      final serialized = original.serialize();
      final payload = serialized.sublist(3);
      final deserialized = SubscribeOkMessage.deserialize(payload);

      expect(deserialized.requestId, equals(original.requestId));
      expect(deserialized.trackAlias, equals(original.trackAlias));
      expect(deserialized.expires, equals(original.expires));
      expect(deserialized.groupOrder, equals(original.groupOrder));
      expect(deserialized.contentExists, equals(original.contentExists));
      expect(deserialized.largestLocation!.group, equals(original.largestLocation!.group));
      expect(deserialized.largestLocation!.object, equals(original.largestLocation!.object));
      expect(deserialized.parameters.length, equals(original.parameters.length));
    });
  });

  group('SubscribeErrorMessage', () {
    test('serialize', () {
      final message = SubscribeErrorMessage(
        requestId: Int64(1),
        errorCode: 404,
        errorReason: const ReasonPhrase('Not Found'),
      );
      final serialized = message.serialize();

      expect(serialized[0], equals(0x05)); // Type
      expect(serialized[3], equals(1)); // Request ID
      expect(serialized[4], equals(404)); // Error Code
      expect(serialized[5], equals(9)); // Reason length
      expect(serialized.sublist(6), equals([78, 111, 116, 32, 70, 111, 117, 110, 100])); // 'Not Found'
    });

    test('deserialize', () {
      final data = Uint8List.fromList([
        1, // Request ID
        404 >> 8, 404 & 0xFF, // Error Code (404)
        9, // Reason length
        78, 111, 116, 32, 70, 111, 117, 110, 100, // 'Not Found'
      ]);
      final message = SubscribeErrorMessage.deserialize(data);

      expect(message.requestId, equals(Int64(1)));
      expect(message.errorCode, equals(404));
      expect(message.errorReason.reason, equals('Not Found'));
    });

    test('round-trip serialization', () {
      final original = SubscribeErrorMessage(
        requestId: Int64(10),
        errorCode: 500,
        errorReason: const ReasonPhrase('Internal Server Error'),
      );

      final serialized = original.serialize();
      final payload = serialized.sublist(3);
      final deserialized = SubscribeErrorMessage.deserialize(payload);

      expect(deserialized.requestId, equals(original.requestId));
      expect(deserialized.errorCode, equals(original.errorCode));
      expect(deserialized.errorReason.reason, equals(original.errorReason.reason));
    });
  });

  group('UnsubscribeMessage', () {
    test('serialize', () {
      final message = UnsubscribeMessage(requestId: Int64(5));
      final serialized = message.serialize();

      expect(serialized[0], equals(0x0A)); // Type
      expect(serialized[3], equals(5)); // Request ID
    });

    test('deserialize', () {
      final data = Uint8List.fromList([5]);
      final message = UnsubscribeMessage.deserialize(data);

      expect(message.requestId, equals(Int64(5)));
      expect(message.type, equals(MoQMessageType.unsubscribe));
    });

    test('round-trip serialization', () {
      final original = UnsubscribeMessage(requestId: Int64(100));
      final serialized = original.serialize();
      final payload = serialized.sublist(3);
      final deserialized = UnsubscribeMessage.deserialize(payload);

      expect(deserialized.requestId, equals(original.requestId));
    });
  });

  group('GoawayMessage', () {
    test('serialize with last request id only', () {
      final message = GoawayMessage(lastRequestId: Int64(10));
      final serialized = message.serialize();

      expect(serialized[0], equals(0x10)); // Type
      expect(serialized[3], equals(10)); // Last Request ID
    });

    test('serialize with new URI', () {
      final message = GoawayMessage(
        lastRequestId: Int64(10),
        newUri: 'https://example.com/moq',
      );
      final serialized = message.serialize();

      expect(serialized[3], equals(10)); // Last Request ID
      expect(serialized[4], equals(20)); // URI length
      expect(
        serialized.sublist(5),
        equals([104, 116, 116, 112, 115, 58, 47, 47, 101, 120, 97, 109, 112, 108, 101, 46, 99, 111, 109, 47, 109, 111, 113]),
      );
    });

    test('deserialize with last request id only', () {
      final data = Uint8List.fromList([10]);
      final message = GoawayMessage.deserialize(data);

      expect(message.lastRequestId, equals(Int64(10)));
      expect(message.newUri, isNull);
      expect(message.type, equals(MoQMessageType.goaway));
    });

    test('round-trip serialization', () {
      final original = GoawayMessage(
        lastRequestId: Int64(100),
        newUri: 'https://new-server.example',
      );

      final serialized = original.serialize();
      final payload = serialized.sublist(3);
      final deserialized = GoawayMessage.deserialize(payload);

      expect(deserialized.lastRequestId, equals(original.lastRequestId));
      expect(deserialized.newUri, equals(original.newUri));
    });
  });

  group('PublishDoneMessage', () {
    test('serialize without error reason', () {
      final message = PublishDoneMessage(
        requestId: Int64(1),
        statusCode: 200,
        streamCount: Int64(5),
      );
      final serialized = message.serialize();

      expect(serialized[0], equals(0x0B)); // Type
      expect(serialized[3], equals(1)); // Request ID
      expect(serialized[4], equals(200)); // Status Code
      expect(serialized[5], equals(5)); // Stream Count
    });

    test('serialize with error reason', () {
      final message = PublishDoneMessage(
        requestId: Int64(1),
        statusCode: 500,
        streamCount: Int64(0),
        errorReason: const ReasonPhrase('Internal Error'),
      );
      final serialized = message.serialize();

      expect(serialized[3], equals(1)); // Request ID
      expect(serialized[4], equals(500)); // Status Code
      expect(serialized[5], equals(0)); // Stream Count
      expect(serialized[6], equals(14)); // Reason length
      expect(
        serialized.sublist(7),
        equals([73, 110, 116, 101, 114, 110, 97, 108, 32, 69, 114, 114, 111, 114]),
      );
    });

    test('deserialize without error reason', () {
      final data = Uint8List.fromList([
        1, // Request ID
        200, // Status Code
        5, // Stream Count
      ]);
      final message = PublishDoneMessage.deserialize(data);

      expect(message.requestId, equals(Int64(1)));
      expect(message.statusCode, equals(200));
      expect(message.streamCount, equals(Int64(5)));
      expect(message.errorReason, isNull);
    });

    test('deserialize with error reason', () {
      final data = Uint8List.fromList([
        1, // Request ID
        500, // Status Code
        0, // Stream Count
        14, // Reason length
        73, 110, 116, 101, 114, 110, 97, 108, 32, 69, 114, 114, 111, 114, // 'Internal Error'
      ]);
      final message = PublishDoneMessage.deserialize(data);

      expect(message.requestId, equals(Int64(1)));
      expect(message.statusCode, equals(500));
      expect(message.streamCount, equals(Int64(0)));
      expect(message.errorReason!.reason, equals('Internal Error'));
    });

    test('round-trip serialization', () {
      final original = PublishDoneMessage(
        requestId: Int64(10),
        statusCode: 200,
        streamCount: Int64(15),
        errorReason: const ReasonPhrase('OK'),
      );

      final serialized = original.serialize();
      final payload = serialized.sublist(3);
      final deserialized = PublishDoneMessage.deserialize(payload);

      expect(deserialized.requestId, equals(original.requestId));
      expect(deserialized.statusCode, equals(original.statusCode));
      expect(deserialized.streamCount, equals(original.streamCount));
      expect(deserialized.errorReason!.reason, equals(original.errorReason!.reason));
    });
  });

  group('SubscribeUpdateMessage', () {
    test('serialize', () {
      final message = SubscribeUpdateMessage(
        requestId: Int64(1),
        subscriptionRequestId: Int64(2),
        startLocation: Location(group: Int64(10), object: Int64(5)),
        endGroup: Int64(100),
        subscriberPriority: 128,
        forward: 1,
      );
      final serialized = message.serialize();

      expect(serialized[0], equals(0x02)); // Type
      expect(serialized[3], equals(1)); // Request ID
      expect(serialized[4], equals(2)); // Subscription Request ID
      expect(serialized[5], equals(10)); // Start Location group
      expect(serialized[6], equals(5)); // Start Location object
      expect(serialized[7], equals(100)); // End Group
      expect(serialized[8], equals(128)); // Subscriber Priority
      expect(serialized[9], equals(1)); // Forward
    });

    test('deserialize', () {
      final data = Uint8List.fromList([
        1, // Request ID
        2, // Subscription Request ID
        10, 5, // Start Location
        100, // End Group
        128, // Subscriber Priority
        1, // Forward
        0, // No parameters
      ]);
      final message = SubscribeUpdateMessage.deserialize(data);

      expect(message.requestId, equals(Int64(1)));
      expect(message.subscriptionRequestId, equals(Int64(2)));
      expect(message.startLocation.group, equals(Int64(10)));
      expect(message.startLocation.object, equals(Int64(5)));
      expect(message.endGroup, equals(Int64(100)));
      expect(message.subscriberPriority, equals(128));
      expect(message.forward, equals(1));
    });

    test('round-trip serialization', () {
      final original = SubscribeUpdateMessage(
        requestId: Int64(5),
        subscriptionRequestId: Int64(10),
        startLocation: Location(group: Int64(50), object: Int64(25)),
        endGroup: Int64(200),
        subscriberPriority: 150,
        forward: 0,
        parameters: [
          KeyValuePair(type: 0x0001, value: Uint8List.fromList([1])),
        ],
      );

      final serialized = original.serialize();
      final payload = serialized.sublist(3);
      final deserialized = SubscribeUpdateMessage.deserialize(payload);

      expect(deserialized.requestId, equals(original.requestId));
      expect(deserialized.subscriptionRequestId, equals(original.subscriptionRequestId));
      expect(deserialized.startLocation.group, equals(original.startLocation.group));
      expect(deserialized.startLocation.object, equals(original.startLocation.object));
      expect(deserialized.endGroup, equals(original.endGroup));
      expect(deserialized.subscriberPriority, equals(original.subscriberPriority));
      expect(deserialized.forward, equals(original.forward));
      expect(deserialized.parameters.length, equals(original.parameters.length));
    });
  });
}
