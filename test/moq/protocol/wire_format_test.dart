import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moq_flutter/moq/protocol/moq_messages.dart';

void main() {
  group('MoQWireFormat - Varint Encoding/Decoding', () {
    test('encodeVarint - single byte values', () {
      expect(MoQWireFormat.encodeVarint(0), equals([0]));
      expect(MoQWireFormat.encodeVarint(1), equals([1]));
      expect(MoQWireFormat.encodeVarint(127), equals([0x7F]));
    });

    test('encodeVarint - multi byte values', () {
      expect(MoQWireFormat.encodeVarint(128), equals([0x80, 0x01]));
      expect(MoQWireFormat.encodeVarint(300), equals([0xAC, 0x02]));
      expect(MoQWireFormat.encodeVarint(16384), equals([0x80, 0x80, 0x01]));
    });

    test('encodeVarint - large values', () {
      expect(
        MoQWireFormat.encodeVarint(0xFFFFFFFF),
        equals([0xFF, 0xFF, 0xFF, 0xFF, 0x0F]),
      );
      expect(
        MoQWireFormat.encodeVarint(0x7FFFFFFF),
        equals([0xFF, 0xFF, 0xFF, 0xFF, 0x07]),
      );
    });

    test('decodeVarint - single byte values', () {
      final (value, bytesRead) = MoQWireFormat.decodeVarint(Uint8List.fromList([0]), 0);
      expect(value, equals(0));
      expect(bytesRead, equals(1));

      final (value2, bytesRead2) = MoQWireFormat.decodeVarint(Uint8List.fromList([1]), 0);
      expect(value2, equals(1));
      expect(bytesRead2, equals(1));

      final (value3, bytesRead3) = MoQWireFormat.decodeVarint(Uint8List.fromList([0x7F]), 0);
      expect(value3, equals(127));
      expect(bytesRead3, equals(1));
    });

    test('decodeVarint - multi byte values', () {
      final (value, bytesRead) = MoQWireFormat.decodeVarint(
        Uint8List.fromList([0x80, 0x01]),
        0,
      );
      expect(value, equals(128));
      expect(bytesRead, equals(2));

      final (value2, bytesRead2) = MoQWireFormat.decodeVarint(
        Uint8List.fromList([0xAC, 0x02]),
        0,
      );
      expect(value2, equals(300));
      expect(bytesRead2, equals(2));
    });

    test('decodeVarint - large values', () {
      final (value, bytesRead) = MoQWireFormat.decodeVarint(
        Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0x0F]),
        0,
      );
      expect(value, equals(0xFFFFFFFF));
      expect(bytesRead, equals(5));
    });

    test('decodeVarint - with offset', () {
      final data = Uint8List.fromList([0xFF, 0x80, 0x01, 0xAA]);
      final (value, bytesRead) = MoQWireFormat.decodeVarint(data, 1);
      expect(value, equals(128));
      expect(bytesRead, equals(2));
    });

    test('decodeVarint - throws on unexpected end', () {
      expect(
        () => MoQWireFormat.decodeVarint(Uint8List.fromList([0x80]), 0),
        throwsA(isA<FormatException>()),
      );
    });

    test('decodeVarint - throws on too long', () {
      expect(
        () => MoQWireFormat.decodeVarint(
          Uint8List.fromList([
            0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80,
            0x01,
          ]),
          0,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('varint round-trip', () {
      final testValues = [
        0, 1, 127, 128, 255, 256, 16383, 16384, 65535, 65536, 2097151,
        2097152, 0x7FFFFFFF,
      ];

      for (final value in testValues) {
        final encoded = MoQWireFormat.encodeVarint(value);
        final (decoded, _) = MoQWireFormat.decodeVarint(encoded, 0);
        expect(decoded, equals(value), reason: 'Failed for value: $value');
      }
    });

    test('encodeVarint64 - single byte values', () {
      expect(MoQWireFormat.encodeVarint64(Int64(0)), equals([0]));
      expect(MoQWireFormat.encodeVarint64(Int64(1)), equals([1]));
      expect(MoQWireFormat.encodeVarint64(Int64(127)), equals([0x7F]));
    });

    test('encodeVarint64 - multi byte values', () {
      expect(
        MoQWireFormat.encodeVarint64(Int64(128)),
        equals([0x80, 0x01]),
      );
      expect(
        MoQWireFormat.encodeVarint64(Int64(300)),
        equals([0xAC, 0x02]),
      );
    });

    test('encodeVarint64 - large 64-bit values', () {
      // Test encoding a value that requires 4 bytes (21-27 bits)
      // Value: 2097151 = 0x1FFFFF
      // Encoded as: 0xFF, 0xFF, 0x7F
      expect(
        MoQWireFormat.encodeVarint64(Int64(2097151)),
        equals([0xFF, 0xFF, 0x7F]),
      );
    });

    test('decodeVarint64 - single byte values', () {
      final (value, bytesRead) = MoQWireFormat.decodeVarint64(
        Uint8List.fromList([0]),
        0,
      );
      expect(value, equals(Int64(0)));
      expect(bytesRead, equals(1));

      final (value2, bytesRead2) = MoQWireFormat.decodeVarint64(
        Uint8List.fromList([127]),
        0,
      );
      expect(value2, equals(Int64(127)));
      expect(bytesRead2, equals(1));
    });

    test('decodeVarint64 - large values', () {
      // Test decoding a 3-byte varint
      // Value: 2097151 = 0x1FFFFF
      final (value, bytesRead) = MoQWireFormat.decodeVarint64(
        Uint8List.fromList([0xFF, 0xFF, 0x7F]),
        0,
      );
      expect(value, equals(Int64(2097151)));
      expect(bytesRead, equals(3));
    });

    test('decodeVarint64 - throws on unexpected end', () {
      expect(
        () => MoQWireFormat.decodeVarint64(Uint8List.fromList([0x80]), 0),
        throwsA(isA<FormatException>()),
      );
    });

    test('varint64 round-trip', () {
      final testValues = [
        Int64(0),
        Int64(1),
        Int64(127),
        Int64(128),
        Int64(255),
        Int64(256),
        Int64(16383),
        Int64(16384),
        Int64(2097151),
        Int64(2097152),
      ];

      for (final value in testValues) {
        final encoded = MoQWireFormat.encodeVarint64(value);
        final (decoded, _) = MoQWireFormat.decodeVarint64(encoded, 0);
        expect(decoded, equals(value), reason: 'Failed for value: $value');
      }
    });
  });

  group('MoQWireFormat - Tuple Encoding/Decoding', () {
    test('encodeTuple - empty tuple', () {
      final tuple = <Uint8List>[];
      final encoded = MoQWireFormat.encodeTuple(tuple);
      expect(encoded, equals([0]));
    });

    test('encodeTuple - single element', () {
      final tuple = [Uint8List.fromList([1, 2, 3])];
      final encoded = MoQWireFormat.encodeTuple(tuple);
      // Count (1) + Length (3) + Data (1,2,3)
      expect(encoded, equals([1, 3, 1, 2, 3]));
    });

    test('encodeTuple - multiple elements', () {
      final tuple = [
        Uint8List.fromList([1, 2, 3]),
        Uint8List.fromList([4, 5]),
        Uint8List.fromList([6]),
      ];
      final encoded = MoQWireFormat.encodeTuple(tuple);
      // Count (3) + len1(3) + data1(1,2,3) + len2(2) + data2(4,5) + len3(1) + data3(6)
      expect(encoded, equals([3, 3, 1, 2, 3, 2, 4, 5, 1, 6]));
    });

    test('encodeTuple - empty elements', () {
      final tuple = [
        Uint8List.fromList([1, 2]),
        Uint8List(0),
        Uint8List.fromList([3]),
      ];
      final encoded = MoQWireFormat.encodeTuple(tuple);
      // Count (3) + len1(2) + data1(1,2) + len2(0) + len3(1) + data3(3)
      expect(encoded, equals([3, 2, 1, 2, 0, 1, 3]));
    });

    test('decodeTuple - empty tuple', () {
      final (tuple, bytesRead) = MoQWireFormat.decodeTuple(
        Uint8List.fromList([0]),
        0,
      );
      expect(tuple, isEmpty);
      expect(bytesRead, equals(1));
    });

    test('decodeTuple - single element', () {
      final (tuple, bytesRead) = MoQWireFormat.decodeTuple(
        Uint8List.fromList([1, 3, 1, 2, 3]),
        0,
      );
      expect(tuple.length, equals(1));
      expect(tuple[0], equals([1, 2, 3]));
      expect(bytesRead, equals(5));
    });

    test('decodeTuple - multiple elements', () {
      final (tuple, bytesRead) = MoQWireFormat.decodeTuple(
        Uint8List.fromList([3, 3, 1, 2, 3, 2, 4, 5, 1, 6]),
        0,
      );
      expect(tuple.length, equals(3));
      expect(tuple[0], equals([1, 2, 3]));
      expect(tuple[1], equals([4, 5]));
      expect(tuple[2], equals([6]));
      expect(bytesRead, equals(10));
    });

    test('decodeTuple - with empty elements', () {
      final (tuple, bytesRead) = MoQWireFormat.decodeTuple(
        Uint8List.fromList([3, 2, 1, 2, 0, 1, 3]),
        0,
      );
      expect(tuple.length, equals(3));
      expect(tuple[0], equals([1, 2]));
      expect(tuple[1], isEmpty);
      expect(tuple[2], equals([3]));
      expect(bytesRead, equals(7));
    });

    test('decodeTuple - throws on unexpected end', () {
      expect(
        () => MoQWireFormat.decodeTuple(Uint8List.fromList([2, 3, 1, 2]), 0),
        throwsA(isA<FormatException>()),
      );
    });

    test('tuple round-trip', () {
      final testTuples = [
        <Uint8List>[],
        [Uint8List.fromList([1, 2, 3])],
        [
          Uint8List.fromList([1, 2, 3]),
          Uint8List.fromList([4, 5]),
          Uint8List.fromList([6]),
        ],
        [
          Uint8List.fromList([1, 2]),
          Uint8List(0),
          Uint8List.fromList([3, 4, 5, 6]),
        ],
      ];

      for (final tuple in testTuples) {
        final encoded = MoQWireFormat.encodeTuple(tuple);
        final (decoded, _) = MoQWireFormat.decodeTuple(encoded, 0);
        expect(decoded.length, equals(tuple.length));
        for (int i = 0; i < tuple.length; i++) {
          expect(decoded[i], equals(tuple[i]));
        }
      }
    });
  });

  group('MoQWireFormat - Location Encoding/Decoding', () {
    test('encodeLocation - zero location', () {
      final location = Location.zero();
      final encoded = MoQWireFormat.encodeLocation(location);
      expect(encoded, equals([0, 0]));
    });

    test('encodeLocation - single byte values', () {
      final location = Location(group: Int64(5), object: Int64(10));
      final encoded = MoQWireFormat.encodeLocation(location);
      expect(encoded, equals([5, 10]));
    });

    test('encodeLocation - multi byte values', () {
      final location = Location(group: Int64(300), object: Int64(128));
      final encoded = MoQWireFormat.encodeLocation(location);
      // 300 = 0xAC, 0x02
      // 128 = 0x80, 0x01
      expect(encoded, equals([0xAC, 0x02, 0x80, 0x01]));
    });

    test('encodeLocation - large values', () {
      final location = Location(
        group: Int64(0x7FFFFFFFFFFFFFFF),
        object: Int64(0x7FFFFFFFFFFFFFFF),
      );
      final encoded = MoQWireFormat.encodeLocation(location);
      expect(
        encoded,
        equals([
          0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F,
          0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F,
        ]),
      );
    });

    test('decodeLocation - zero location', () {
      final (location, bytesRead) = MoQWireFormat.decodeLocation(
        Uint8List.fromList([0, 0]),
        0,
      );
      expect(location.group, equals(Int64(0)));
      expect(location.object, equals(Int64(0)));
      expect(bytesRead, equals(2));
    });

    test('decodeLocation - single byte values', () {
      final (location, bytesRead) = MoQWireFormat.decodeLocation(
        Uint8List.fromList([5, 10]),
        0,
      );
      expect(location.group, equals(Int64(5)));
      expect(location.object, equals(Int64(10)));
      expect(bytesRead, equals(2));
    });

    test('decodeLocation - multi byte values', () {
      final (location, bytesRead) = MoQWireFormat.decodeLocation(
        Uint8List.fromList([0xAC, 0x02, 0x80, 0x01]),
        0,
      );
      expect(location.group, equals(Int64(300)));
      expect(location.object, equals(Int64(128)));
      expect(bytesRead, equals(4));
    });

    test('decodeLocation - large values', () {
      final data = Uint8List.fromList([
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F,
      ]);
      final (location, bytesRead) = MoQWireFormat.decodeLocation(data, 0);
      expect(location.group, equals(Int64(0x7FFFFFFFFFFFFFFF)));
      expect(location.object, equals(Int64(0x7FFFFFFFFFFFFFFF)));
      expect(bytesRead, equals(18));
    });

    test('decodeLocation - with offset', () {
      final data = Uint8List.fromList([0xFF, 0xAC, 0x02, 0x80, 0x01, 0xAA]);
      final (location, bytesRead) = MoQWireFormat.decodeLocation(data, 1);
      expect(location.group, equals(Int64(300)));
      expect(location.object, equals(Int64(128)));
      expect(bytesRead, equals(4));
    });

    test('location round-trip', () {
      final testLocations = [
        Location.zero(),
        Location(group: Int64(0), object: Int64(1)),
        Location(group: Int64(1), object: Int64(0)),
        Location(group: Int64(5), object: Int64(10)),
        Location(group: Int64(300), object: Int64(128)),
      ];

      for (final location in testLocations) {
        final encoded = MoQWireFormat.encodeLocation(location);
        final (decoded, _) = MoQWireFormat.decodeLocation(encoded, 0);
        expect(decoded.group, equals(location.group));
        expect(decoded.object, equals(location.object));
      }
    });
  });

  group('MoQControlMessageParser', () {
    test('parse - empty data', () {
      final (message, bytesRead) = MoQControlMessageParser.parse(
        Uint8List(0),
      );
      expect(message, isNull);
      expect(bytesRead, equals(0));
    });

    test('parse - CLIENT_SETUP message', () {
      // Type (0x20) + Length (0, 3) + num_versions (1) + version (14) + num_params (0)
      final data = Uint8List.fromList([0x20, 0x00, 0x03, 1, 14, 0]);
      final (message, bytesRead) = MoQControlMessageParser.parse(data);

      expect(message, isA<ClientSetupMessage>());
      final clientSetup = message as ClientSetupMessage;
      expect(clientSetup.supportedVersions, equals([14]));
      expect(clientSetup.parameters, isEmpty);
      expect(bytesRead, equals(6));
    });

    test('parse - SERVER_SETUP message', () {
      // Type (0x21) + Length (0, 2) + version (14) + num_params (0)
      final data = Uint8List.fromList([0x21, 0x00, 0x02, 14, 0]);
      final (message, bytesRead) = MoQControlMessageParser.parse(data);

      expect(message, isA<ServerSetupMessage>());
      final serverSetup = message as ServerSetupMessage;
      expect(serverSetup.selectedVersion, equals(14));
      expect(serverSetup.parameters, isEmpty);
      expect(bytesRead, equals(5));
    });

    test('parse - SUBSCRIBE message', () {
      // Type (0x3) + Length + request_id + namespace + track_name + priority + group_order + forward + filter_type + params
      // Payload = 1 + 1 + 1 + 4 + 1 + 3 + 1 + 1 + 1 + 1 + 1 = 16 bytes
      final data = Uint8List.fromList([
        0x03, // Type
        0x00, 0x10, // Length (16)
        1, // Request ID
        1, // Namespace count
        4, 116, 101, 115, 116, // Namespace element: 'test'
        3, 116, 114, 107, // Track name: 'trk'
        128, // Priority
        0, // Group Order
        1, // Forward
        0, // Filter Type (largest object)
        0, // No parameters
      ]);
      final (message, bytesRead) = MoQControlMessageParser.parse(data);

      expect(message, isA<SubscribeMessage>());
      final subscribe = message as SubscribeMessage;
      expect(subscribe.requestId, equals(Int64(1)));
      expect(subscribe.trackNamespace.length, equals(1));
      expect(subscribe.trackNamespace[0], equals([116, 101, 115, 116])); // 'test'
      expect(subscribe.trackName, equals([116, 114, 107])); // 'trk'
      expect(bytesRead, equals(19));
    });

    test('parse - unknown message type', () {
      // Type (0x7F = single byte varint) + Length (0, 0)
      final data = Uint8List.fromList([0x7F, 0x00, 0x00]);
      final (message, bytesRead) = MoQControlMessageParser.parse(data);

      // The parser should handle the format correctly even for unknown types
      // Type (varint) + Length (16-bit) = 3 bytes total
      expect(message, isNull);
      expect(bytesRead, equals(3));
    });

    test('parse - throws on incomplete message length', () {
      // Type (0x20) + only one length byte
      final data = Uint8List.fromList([0x20, 0x00]);

      expect(
        () => MoQControlMessageParser.parse(data),
        throwsA(isA<FormatException>()),
      );
    });

    test('parse - throws on incomplete message data', () {
      // Type (0x20) + Length (0, 5) + but no data
      final data = Uint8List.fromList([0x20, 0x00, 0x05]);

      expect(
        () => MoQControlMessageParser.parse(data),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
