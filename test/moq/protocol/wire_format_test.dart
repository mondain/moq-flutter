import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moq_flutter/moq/protocol/moq_messages.dart';

void main() {
  group('MoQWireFormat - Varint Encoding/Decoding', () {
    // QUIC prefix varint encoding (RFC 9000 Section 16):
    // 0x00-0x3F: 1 byte  (6 bits of data, prefix 00)
    // 0x40-0x7F: 2 bytes (14 bits of data, prefix 01)
    // 0x80-0xBF: 4 bytes (30 bits of data, prefix 10)
    // 0xC0-0xFF: 8 bytes (54 bits of data, prefix 11)

    test('encodeVarint - single byte values (0-63)', () {
      expect(MoQWireFormat.encodeVarint(0), equals([0x00]));
      expect(MoQWireFormat.encodeVarint(1), equals([0x01]));
      expect(MoQWireFormat.encodeVarint(63), equals([0x3F]));
    });

    test('encodeVarint - two byte values (64-16383)', () {
      // 64 = 0x0040 -> prefix 01: 0x40, 0x40
      expect(MoQWireFormat.encodeVarint(64), equals([0x40, 0x40]));
      // 127 = 0x007F -> prefix 01: 0x40, 0x7F
      expect(MoQWireFormat.encodeVarint(127), equals([0x40, 0x7F]));
      // 128 = 0x0080 -> prefix 01: 0x40, 0x80
      expect(MoQWireFormat.encodeVarint(128), equals([0x40, 0x80]));
      // 300 = 0x012C -> prefix 01: 0x41, 0x2C
      expect(MoQWireFormat.encodeVarint(300), equals([0x41, 0x2C]));
      // 16383 = 0x3FFF -> prefix 01: 0x7F, 0xFF
      expect(MoQWireFormat.encodeVarint(16383), equals([0x7F, 0xFF]));
    });

    test('encodeVarint - four byte values (16384-1073741823)', () {
      // 16384 = 0x00004000 -> prefix 10: 0x80, 0x00, 0x40, 0x00
      expect(MoQWireFormat.encodeVarint(16384), equals([0x80, 0x00, 0x40, 0x00]));
      // 0x3FFFFFFF -> prefix 10: 0xBF, 0xFF, 0xFF, 0xFF
      expect(MoQWireFormat.encodeVarint(0x3FFFFFFF), equals([0xBF, 0xFF, 0xFF, 0xFF]));
    });

    test('encodeVarint - eight byte values', () {
      // 0x40000000 -> prefix 11: 0xC0, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00
      expect(
        MoQWireFormat.encodeVarint(0x40000000),
        equals([0xC0, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00]),
      );
      // 0xFFFFFFFF -> prefix 11: 0xC0, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF
      expect(
        MoQWireFormat.encodeVarint(0xFFFFFFFF),
        equals([0xC0, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF]),
      );
    });

    test('decodeVarint - single byte values', () {
      final (value, bytesRead) = MoQWireFormat.decodeVarint(Uint8List.fromList([0x00]), 0);
      expect(value, equals(0));
      expect(bytesRead, equals(1));

      final (value2, bytesRead2) = MoQWireFormat.decodeVarint(Uint8List.fromList([0x01]), 0);
      expect(value2, equals(1));
      expect(bytesRead2, equals(1));

      final (value3, bytesRead3) = MoQWireFormat.decodeVarint(Uint8List.fromList([0x3F]), 0);
      expect(value3, equals(63));
      expect(bytesRead3, equals(1));
    });

    test('decodeVarint - two byte values', () {
      final (value, bytesRead) = MoQWireFormat.decodeVarint(
        Uint8List.fromList([0x40, 0x80]),
        0,
      );
      expect(value, equals(128));
      expect(bytesRead, equals(2));

      final (value2, bytesRead2) = MoQWireFormat.decodeVarint(
        Uint8List.fromList([0x41, 0x2C]),
        0,
      );
      expect(value2, equals(300));
      expect(bytesRead2, equals(2));
    });

    test('decodeVarint - four byte values', () {
      final (value, bytesRead) = MoQWireFormat.decodeVarint(
        Uint8List.fromList([0x80, 0x00, 0x40, 0x00]),
        0,
      );
      expect(value, equals(16384));
      expect(bytesRead, equals(4));
    });

    test('decodeVarint - eight byte values', () {
      final (value, bytesRead) = MoQWireFormat.decodeVarint(
        Uint8List.fromList([0xC0, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF]),
        0,
      );
      expect(value, equals(0xFFFFFFFF));
      expect(bytesRead, equals(8));
    });

    test('decodeVarint - with offset', () {
      // Prefix byte at offset 1: 0x40 means 2-byte varint
      final data = Uint8List.fromList([0xFF, 0x40, 0x80, 0xAA]);
      final (value, bytesRead) = MoQWireFormat.decodeVarint(data, 1);
      expect(value, equals(128));
      expect(bytesRead, equals(2));
    });

    test('decodeVarint - throws on incomplete 2-byte', () {
      // 0x40 prefix means 2 bytes needed, but only 1 available
      expect(
        () => MoQWireFormat.decodeVarint(Uint8List.fromList([0x40]), 0),
        throwsA(isA<FormatException>()),
      );
    });

    test('decodeVarint - throws on incomplete 4-byte', () {
      // 0x80 prefix means 4 bytes needed, but only 2 available
      expect(
        () => MoQWireFormat.decodeVarint(Uint8List.fromList([0x80, 0x00]), 0),
        throwsA(isA<FormatException>()),
      );
    });

    test('decodeVarint - throws on incomplete 8-byte', () {
      // 0xC0 prefix means 8 bytes needed, but only 4 available
      expect(
        () => MoQWireFormat.decodeVarint(
          Uint8List.fromList([0xC0, 0x00, 0x00, 0x00]),
          0,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('varint round-trip', () {
      final testValues = [
        0, 1, 63, 64, 127, 128, 255, 256, 16383, 16384, 65535, 65536,
        0x3FFFFFFF,
      ];

      for (final value in testValues) {
        final encoded = MoQWireFormat.encodeVarint(value);
        final (decoded, _) = MoQWireFormat.decodeVarint(encoded, 0);
        expect(decoded, equals(value), reason: 'Failed for value: $value');
      }
    });

    test('encodeVarint64 - single byte values (0-63)', () {
      expect(MoQWireFormat.encodeVarint64(Int64(0)), equals([0x00]));
      expect(MoQWireFormat.encodeVarint64(Int64(1)), equals([0x01]));
      expect(MoQWireFormat.encodeVarint64(Int64(63)), equals([0x3F]));
    });

    test('encodeVarint64 - two byte values', () {
      // 128 = 0x0080 -> prefix 01: 0x40, 0x80
      expect(
        MoQWireFormat.encodeVarint64(Int64(128)),
        equals([0x40, 0x80]),
      );
      // 300 = 0x012C -> prefix 01: 0x41, 0x2C
      expect(
        MoQWireFormat.encodeVarint64(Int64(300)),
        equals([0x41, 0x2C]),
      );
    });

    test('encodeVarint64 - four byte values', () {
      // 16384 = 0x00004000 -> prefix 10: 0x80, 0x00, 0x40, 0x00
      expect(
        MoQWireFormat.encodeVarint64(Int64(16384)),
        equals([0x80, 0x00, 0x40, 0x00]),
      );
    });

    test('decodeVarint64 - single byte values', () {
      final (value, bytesRead) = MoQWireFormat.decodeVarint64(
        Uint8List.fromList([0x00]),
        0,
      );
      expect(value, equals(Int64(0)));
      expect(bytesRead, equals(1));

      final (value2, bytesRead2) = MoQWireFormat.decodeVarint64(
        Uint8List.fromList([0x3F]),
        0,
      );
      expect(value2, equals(Int64(63)));
      expect(bytesRead2, equals(1));
    });

    test('decodeVarint64 - two byte values', () {
      final (value, bytesRead) = MoQWireFormat.decodeVarint64(
        Uint8List.fromList([0x40, 0x80]),
        0,
      );
      expect(value, equals(Int64(128)));
      expect(bytesRead, equals(2));
    });

    test('decodeVarint64 - throws on incomplete', () {
      expect(
        () => MoQWireFormat.decodeVarint64(Uint8List.fromList([0x40]), 0),
        throwsA(isA<FormatException>()),
      );
    });

    test('varint64 round-trip', () {
      final testValues = [
        Int64(0),
        Int64(1),
        Int64(63),
        Int64(64),
        Int64(128),
        Int64(255),
        Int64(256),
        Int64(16383),
        Int64(16384),
        Int64(0x3FFFFFFF),
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
      // Count (1) + Length (3) + Data (1,2,3) - all values <= 63 so 1-byte varints
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

    test('encodeLocation - two byte values', () {
      // 300 = prefix 01: 0x41, 0x2C; 128 = prefix 01: 0x40, 0x80
      final location = Location(group: Int64(300), object: Int64(128));
      final encoded = MoQWireFormat.encodeLocation(location);
      expect(encoded, equals([0x41, 0x2C, 0x40, 0x80]));
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

    test('decodeLocation - two byte values', () {
      final (location, bytesRead) = MoQWireFormat.decodeLocation(
        Uint8List.fromList([0x41, 0x2C, 0x40, 0x80]),
        0,
      );
      expect(location.group, equals(Int64(300)));
      expect(location.object, equals(Int64(128)));
      expect(bytesRead, equals(4));
    });

    test('decodeLocation - with offset', () {
      final data = Uint8List.fromList([0xFF, 0x41, 0x2C, 0x40, 0x80, 0xAA]);
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
      // Type (0x20) = 1-byte varint + Length (0, 3) + num_versions (1) + version (14) + num_params (0)
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
      // Type 0x3F (max single-byte prefix varint = 63) + Length (0, 0)
      final data = Uint8List.fromList([0x3F, 0x00, 0x00]);
      final (message, bytesRead) = MoQControlMessageParser.parse(data);

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
