import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moq_flutter/moq/protocol/moq_messages.dart';
import 'package:moq_flutter/moq/protocol/moq_data_parser.dart';

void main() {
  group('MoQDataStreamParser', () {
    late MoQDataStreamParser parser;

    setUp(() {
      parser = MoQDataStreamParser();
    });

    test('parse basic SUBGROUP_HEADER (type 0x10)', () {
      // Build a SUBGROUP_HEADER message:
      // Type 0x10: Track Alias + Group ID + Priority (NO Subgroup ID field - always 0)
      final data = Uint8List.fromList([
        0x10, // Type 0x10: no extensions, no end of group, subgroup ID is 0
        0x01, // Track Alias = 1
        0x0A, // Group ID = 10
        0x80, // Publisher Priority = 128
      ]);

      final objects = parser.parseChunk(data);

      expect(parser.hasHeader, isTrue);
      expect(parser.header!.trackAlias, equals(Int64(1)));
      expect(parser.header!.groupId, equals(Int64(10)));
      expect(parser.header!.subgroupId, equals(Int64(0))); // Always 0 for type 0x10
      expect(parser.header!.publisherPriority, equals(128));
      expect(objects, isEmpty); // No objects yet
    });

    test('parse SUBGROUP_HEADER with extensions flag (type 0x11)', () {
      // Type 0x11: extensions present, no subgroup ID field
      final data = Uint8List.fromList([
        0x11, // Type 0x11: has extensions, no end of group, no subgroup ID
        0x02, // Track Alias = 2
        0x14, // Group ID = 20
        0x40, // Publisher Priority = 64
      ]);

      parser.parseChunk(data);

      expect(parser.hasHeader, isTrue);
      expect(parser.header!.trackAlias, equals(Int64(2)));
      expect(parser.header!.groupId, equals(Int64(20)));
      expect(parser.header!.publisherPriority, equals(64));
    });

    test('parse header and single object', () {
      // Header + object with 3-byte payload
      // Type 0x10: no subgroup ID field
      final data = Uint8List.fromList([
        // SUBGROUP_HEADER (type 0x10)
        0x10, // Type
        0x01, // Track Alias = 1
        0x01, // Group ID = 1
        0x80, // Publisher Priority = 128
        // Object: objectIdDelta=0, payloadLen=3, payload
        0x00, // Object ID Delta = 0 (first object, so Object ID = 0)
        0x03, // Payload Length = 3
        0x41, 0x42, 0x43, // Payload = "ABC"
      ]);

      final objects = parser.parseChunk(data);

      expect(parser.hasHeader, isTrue);
      expect(objects.length, equals(1));
      expect(objects[0].objectId, equals(Int64(0)));
      expect(objects[0].payload, equals(Uint8List.fromList([0x41, 0x42, 0x43])));
      expect(objects[0].status, equals(ObjectStatus.normal));
    });

    test('parse multiple objects with delta encoding', () {
      // Header + two objects
      // Type 0x10: no subgroup ID field
      final data = Uint8List.fromList([
        // SUBGROUP_HEADER (type 0x10: Track Alias, Group ID, Priority)
        0x10, 0x01, 0x01, 0x80,
        // Object 1: delta=5 (Object ID = 5)
        0x05, // Object ID Delta = 5
        0x02, // Payload Length = 2
        0x01, 0x02, // Payload
        // Object 2: delta=0 (Object ID = 5 + 0 + 1 = 6)
        0x00, // Object ID Delta = 0
        0x02, // Payload Length = 2
        0x03, 0x04, // Payload
      ]);

      final objects = parser.parseChunk(data);

      expect(objects.length, equals(2));
      expect(objects[0].objectId, equals(Int64(5)));
      expect(objects[1].objectId, equals(Int64(6)));
    });

    test('parse object with status (zero-length payload)', () {
      // Type 0x10: no subgroup ID field
      final data = Uint8List.fromList([
        // SUBGROUP_HEADER (type 0x10: Track Alias, Group ID, Priority)
        0x10, 0x01, 0x01, 0x80,
        // Object with status
        0x00, // Object ID Delta = 0
        0x00, // Payload Length = 0 (indicates status follows)
        0x03, // Status = endOfGroup (0x03 per ObjectStatus enum)
      ]);

      final objects = parser.parseChunk(data);

      expect(objects.length, equals(1));
      expect(objects[0].objectId, equals(Int64(0)));
      expect(objects[0].payload, isNull);
      expect(objects[0].status, equals(ObjectStatus.endOfGroup));
    });

    test('parse chunked data (header in first chunk, object in second)', () {
      // First chunk: header only (type 0x10: no subgroup ID field)
      final chunk1 = Uint8List.fromList([
        0x10, 0x01, 0x01, 0x80,
      ]);

      final objects1 = parser.parseChunk(chunk1);
      expect(parser.hasHeader, isTrue);
      expect(objects1, isEmpty);

      // Second chunk: object
      final chunk2 = Uint8List.fromList([
        0x00, // Object ID Delta
        0x04, // Payload Length
        0x01, 0x02, 0x03, 0x04, // Payload
      ]);

      final objects2 = parser.parseChunk(chunk2);
      expect(objects2.length, equals(1));
      expect(objects2[0].payload!.length, equals(4));
    });

    test('incomplete header waits for more data', () {
      // Partial header (missing priority byte for type 0x10)
      final data = Uint8List.fromList([
        0x10, 0x01, 0x01, // Missing priority byte
      ]);

      final objects = parser.parseChunk(data);

      expect(parser.hasHeader, isFalse);
      expect(objects, isEmpty);
      expect(parser.bufferedBytes, equals(3));
    });

    test('incomplete object waits for more data', () {
      // Complete header + partial object (type 0x10: no subgroup ID)
      final data = Uint8List.fromList([
        // SUBGROUP_HEADER (type 0x10: Track Alias, Group ID, Priority)
        0x10, 0x01, 0x01, 0x80,
        // Partial object (payload length says 10, but only 3 bytes provided)
        0x00, // Object ID Delta
        0x0A, // Payload Length = 10
        0x01, 0x02, 0x03, // Only 3 bytes of payload
      ]);

      final objects = parser.parseChunk(data);

      expect(parser.hasHeader, isTrue);
      expect(objects, isEmpty); // Object not complete yet
      expect(parser.bufferedBytes, greaterThan(0));
    });

    test('reset clears parser state', () {
      // Parse some data first (type 0x10: no subgroup ID)
      final data = Uint8List.fromList([
        0x10, 0x01, 0x01, 0x80,
      ]);
      parser.parseChunk(data);
      expect(parser.hasHeader, isTrue);

      // Reset
      parser.reset();

      expect(parser.hasHeader, isFalse);
      expect(parser.bufferedBytes, equals(0));
    });

    test('parse with extensions present (type 0x11) - header only', () {
      // SUBGROUP_HEADER with extensions flag
      // Type 0x11: extensions present, no subgroup ID field
      // Note: Extension parsing in objects is complex; test just header here
      final data = Uint8List.fromList([
        // SUBGROUP_HEADER (type 0x11 = extensions present, no subgroup ID)
        0x11, 0x01, 0x01, 0x80,
      ]);

      parser.parseChunk(data);

      expect(parser.hasHeader, isTrue);
      expect(parser.header!.trackAlias, equals(Int64(1)));
      expect(parser.header!.groupId, equals(Int64(1)));
    });

    test('parse object with no extensions (type 0x10)', () {
      // Type 0x10: no extensions, so extension headers length should be 0
      final data = Uint8List.fromList([
        // SUBGROUP_HEADER (type 0x10)
        0x10, 0x01, 0x01, 0x80,
        // Object with no extension headers (since type 0x10 has no extensions)
        0x00, // Object ID Delta
        0x02, // Payload Length = 2
        0x01, 0x02, // Payload
      ]);

      final objects = parser.parseChunk(data);

      expect(objects.length, equals(1));
      expect(objects[0].extensionHeaders, isEmpty);
      expect(objects[0].payload, equals(Uint8List.fromList([0x01, 0x02])));
    });

    test('parse large varint values', () {
      // Using 2-byte varints for larger values
      // MoQ uses QUIC varints: 2-byte form is 0x40nn where nn is lower bits
      // For value 300 = 0x12C, 2-byte form is 0x41 0x2C
      // Type 0x10: no subgroup ID field
      final data = Uint8List.fromList([
        0x10, // Type
        0x41, 0x2C, // Track Alias = 300 (2-byte varint)
        0x01, // Group ID = 1
        0x80, // Priority
      ]);

      parser.parseChunk(data);

      expect(parser.hasHeader, isTrue);
      expect(parser.header!.trackAlias, equals(Int64(300)));
    });

    test('parse SUBGROUP_HEADER with explicit subgroup ID (type 0x14)', () {
      // Type 0x14: has explicit subgroup ID field, no extensions
      final data = Uint8List.fromList([
        0x14, // Type 0x14: has subgroup ID
        0x01, // Track Alias = 1
        0x0A, // Group ID = 10
        0x05, // Subgroup ID = 5
        0x80, // Publisher Priority = 128
      ]);

      parser.parseChunk(data);

      expect(parser.hasHeader, isTrue);
      expect(parser.header!.trackAlias, equals(Int64(1)));
      expect(parser.header!.groupId, equals(Int64(10)));
      expect(parser.header!.subgroupId, equals(Int64(5)));
      expect(parser.header!.publisherPriority, equals(128));
    });
  });
}
