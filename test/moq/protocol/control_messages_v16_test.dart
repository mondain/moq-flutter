import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moq_flutter/moq/protocol/moq_messages.dart';

void main() {
  // ============================================================
  // Stage 4: New draft-16 message types
  // ============================================================

  group('RequestOkMessage', () {
    test('serialize and deserialize round-trip', () {
      final msg = RequestOkMessage(
        requestId: Int64(42),
        parameters: [
          KeyValuePair.varint(0x02, 100),
        ],
      );

      final bytes = msg.serialize(version: MoQVersion.draft16);
      // Parse through the control message parser
      final (parsed, _) =
          MoQControlMessageParser.parse(bytes, version: MoQVersion.draft16);

      expect(parsed, isA<RequestOkMessage>());
      final result = parsed as RequestOkMessage;
      expect(result.requestId, equals(Int64(42)));
      expect(result.parameters.length, equals(1));
      expect(result.parameters[0].type, equals(0x02));
      expect(result.parameters[0].intValue, equals(100));
    });

    test('serialize with no parameters', () {
      final msg = RequestOkMessage(requestId: Int64(0));
      final bytes = msg.serialize(version: MoQVersion.draft16);

      final (parsed, _) =
          MoQControlMessageParser.parse(bytes, version: MoQVersion.draft16);

      expect(parsed, isA<RequestOkMessage>());
      final result = parsed as RequestOkMessage;
      expect(result.requestId, equals(Int64(0)));
      expect(result.parameters, isEmpty);
    });

    test('delta KVP encoding with multiple params', () {
      final msg = RequestOkMessage(
        requestId: Int64(10),
        parameters: [
          KeyValuePair.varint(0x02, 1),
          KeyValuePair.varint(0x08, 300),
        ],
      );

      final bytes = msg.serialize(version: MoQVersion.draft16);
      final (parsed, _) =
          MoQControlMessageParser.parse(bytes, version: MoQVersion.draft16);

      final result = parsed as RequestOkMessage;
      expect(result.parameters.length, equals(2));
      expect(result.parameters[0].type, equals(0x02));
      expect(result.parameters[0].intValue, equals(1));
      expect(result.parameters[1].type, equals(0x08));
      expect(result.parameters[1].intValue, equals(300));
    });

    test('out-of-order parameters are sorted and round-trip correctly', () {
      // Parameters passed in descending type order; encodeKeyValuePairs sorts
      // them ascending before delta-encoding, so payloadLength must agree.
      final msg = RequestOkMessage(
        requestId: Int64(5),
        parameters: [
          KeyValuePair.varint(0x08, 200),
          KeyValuePair.varint(0x02, 50),
        ],
      );

      final bytes = msg.serialize(version: MoQVersion.draft16);
      final (parsed, _) =
          MoQControlMessageParser.parse(bytes, version: MoQVersion.draft16);

      final result = parsed as RequestOkMessage;
      expect(result.requestId, equals(Int64(5)));
      expect(result.parameters.length, equals(2));
      // After sort-by-type the lower type comes first
      final types = result.parameters.map((p) => p.type).toList();
      expect(types, containsAll([0x02, 0x08]));
      final byType = {for (final p in result.parameters) p.type: p.intValue};
      expect(byType[0x02], equals(50));
      expect(byType[0x08], equals(200));
    });
  });

  group('RequestErrorMessage', () {
    test('serialize and deserialize round-trip', () {
      final msg = RequestErrorMessage(
        requestId: Int64(7),
        errorCode: MoQRequestErrorCode.DOES_NOT_EXIST,
        retryInterval: Int64(5000),
        errorReason: ReasonPhrase('Track not found'),
      );

      final bytes = msg.serialize(version: MoQVersion.draft16);
      final (parsed, _) =
          MoQControlMessageParser.parse(bytes, version: MoQVersion.draft16);

      expect(parsed, isA<RequestErrorMessage>());
      final result = parsed as RequestErrorMessage;
      expect(result.requestId, equals(Int64(7)));
      expect(result.errorCode, equals(MoQRequestErrorCode.DOES_NOT_EXIST));
      expect(result.retryInterval, equals(Int64(5000)));
      expect(result.errorReason.reason, equals('Track not found'));
    });

    test('serialize with zero retry interval', () {
      final msg = RequestErrorMessage(
        requestId: Int64(0),
        errorCode: MoQRequestErrorCode.INTERNAL_ERROR,
        retryInterval: Int64(0),
        errorReason: ReasonPhrase(''),
      );

      final bytes = msg.serialize(version: MoQVersion.draft16);
      final (parsed, _) =
          MoQControlMessageParser.parse(bytes, version: MoQVersion.draft16);

      final result = parsed as RequestErrorMessage;
      expect(result.requestId, equals(Int64(0)));
      expect(result.errorCode, equals(MoQRequestErrorCode.INTERNAL_ERROR));
      expect(result.retryInterval, equals(Int64(0)));
      expect(result.errorReason.reason, equals(''));
    });
  });

  group('NamespaceMessage', () {
    test('serialize and deserialize round-trip', () {
      final msg = NamespaceMessage(
        trackNamespaceSuffix: [
          Uint8List.fromList('live'.codeUnits),
          Uint8List.fromList('video'.codeUnits),
        ],
      );

      final bytes = msg.serialize(version: MoQVersion.draft16);
      final (parsed, _) =
          MoQControlMessageParser.parse(bytes, version: MoQVersion.draft16);

      expect(parsed, isA<NamespaceMessage>());
      final result = parsed as NamespaceMessage;
      expect(result.trackNamespaceSuffix.length, equals(2));
      expect(String.fromCharCodes(result.trackNamespaceSuffix[0]), equals('live'));
      expect(String.fromCharCodes(result.trackNamespaceSuffix[1]), equals('video'));
      expect(result.suffixPath, equals('live/video'));
    });

    test('serialize with single element suffix', () {
      final msg = NamespaceMessage(
        trackNamespaceSuffix: [
          Uint8List.fromList('audio'.codeUnits),
        ],
      );

      final bytes = msg.serialize(version: MoQVersion.draft16);
      final (parsed, _) =
          MoQControlMessageParser.parse(bytes, version: MoQVersion.draft16);

      final result = parsed as NamespaceMessage;
      expect(result.suffixPath, equals('audio'));
    });
  });

  group('NamespaceDoneMessage', () {
    test('serialize and deserialize round-trip', () {
      final msg = NamespaceDoneMessage(
        trackNamespaceSuffix: [
          Uint8List.fromList('stream1'.codeUnits),
        ],
      );

      final bytes = msg.serialize(version: MoQVersion.draft16);
      final (parsed, _) =
          MoQControlMessageParser.parse(bytes, version: MoQVersion.draft16);

      expect(parsed, isA<NamespaceDoneMessage>());
      final result = parsed as NamespaceDoneMessage;
      expect(result.suffixPath, equals('stream1'));
    });
  });

  // ============================================================
  // KVP delta encoding tests
  // ============================================================

  group('KVP Delta Encoding', () {
    test('round-trip single varint param', () {
      final params = [KeyValuePair.varint(0x04, 42)];
      final encoded =
          MoQWireFormat.encodeKeyValuePairs(params, useDelta: true);
      final (count, countBytes) = MoQWireFormat.decodeVarint(encoded, 0);
      final (decoded, _) = MoQWireFormat.decodeKeyValuePairs(
          encoded, countBytes, count,
          useDelta: true);
      expect(decoded.length, equals(1));
      expect(decoded[0].type, equals(0x04));
      expect(decoded[0].intValue, equals(42));
    });

    test('round-trip multiple params with delta encoding', () {
      final params = [
        KeyValuePair.varint(0x02, 10),
        KeyValuePair.varint(0x08, 20),
        KeyValuePair.varint(0x20, 30),
      ];
      final encoded =
          MoQWireFormat.encodeKeyValuePairs(params, useDelta: true);
      final (count, countBytes) = MoQWireFormat.decodeVarint(encoded, 0);
      final (decoded, _) = MoQWireFormat.decodeKeyValuePairs(
          encoded, countBytes, count,
          useDelta: true);
      expect(decoded.length, equals(3));
      expect(decoded[0].type, equals(0x02));
      expect(decoded[0].intValue, equals(10));
      expect(decoded[1].type, equals(0x08));
      expect(decoded[1].intValue, equals(20));
      expect(decoded[2].type, equals(0x20));
      expect(decoded[2].intValue, equals(30));
    });

    test('round-trip with buffer params', () {
      final params = [
        KeyValuePair.buffer(0x01, Uint8List.fromList([0xDE, 0xAD])),
        KeyValuePair.buffer(0x03, Uint8List.fromList([0xBE, 0xEF])),
      ];
      final encoded =
          MoQWireFormat.encodeKeyValuePairs(params, useDelta: true);
      final (count, countBytes) = MoQWireFormat.decodeVarint(encoded, 0);
      final (decoded, _) = MoQWireFormat.decodeKeyValuePairs(
          encoded, countBytes, count,
          useDelta: true);
      expect(decoded.length, equals(2));
      expect(decoded[0].type, equals(0x01));
      expect(decoded[0].value, equals(Uint8List.fromList([0xDE, 0xAD])));
      expect(decoded[1].type, equals(0x03));
      expect(decoded[1].value, equals(Uint8List.fromList([0xBE, 0xEF])));
    });

    test('absolute mode (draft-14) round-trip', () {
      final params = [
        KeyValuePair.varint(0x02, 100),
        KeyValuePair.varint(0x04, 200),
      ];
      final encoded =
          MoQWireFormat.encodeKeyValuePairs(params, useDelta: false);
      final (count, countBytes) = MoQWireFormat.decodeVarint(encoded, 0);
      final (decoded, _) = MoQWireFormat.decodeKeyValuePairs(
          encoded, countBytes, count,
          useDelta: false);
      expect(decoded.length, equals(2));
      expect(decoded[0].type, equals(0x02));
      expect(decoded[0].intValue, equals(100));
      expect(decoded[1].type, equals(0x04));
      expect(decoded[1].intValue, equals(200));
    });

    test('delta encoding sorts params by type', () {
      // Provide out-of-order params; delta encoder should sort them
      final params = [
        KeyValuePair.varint(0x20, 30),
        KeyValuePair.varint(0x02, 10),
      ];
      final encoded =
          MoQWireFormat.encodeKeyValuePairs(params, useDelta: true);
      final (count, countBytes) = MoQWireFormat.decodeVarint(encoded, 0);
      final (decoded, _) = MoQWireFormat.decodeKeyValuePairs(
          encoded, countBytes, count,
          useDelta: true);
      // Should come back sorted
      expect(decoded[0].type, equals(0x02));
      expect(decoded[1].type, equals(0x20));
    });

    test('throws FormatException when buffer length exceeds remaining data', () {
      // Odd type (0x01), advertises 5 bytes but only 2 are present.
      // Layout: count=1 (1 byte), type=0x01 (1 byte), length=5 (1 byte), 2 data bytes.
      final truncated =
          Uint8List.fromList([0x01, 0x01, 0x05, 0xAA, 0xBB]);
      final (count, countBytes) = MoQWireFormat.decodeVarint(truncated, 0);
      expect(
        () => MoQWireFormat.decodeKeyValuePairs(
            truncated, countBytes, count),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // ============================================================
  // Version-aware message type dispatch
  // ============================================================

  group('MoQMessageType.fromValue version dispatch', () {
    test('draft-14: 0x05 returns subscribeError', () {
      final result = MoQMessageType.fromValue(0x05,
          version: MoQVersion.draft14);
      expect(result, equals(MoQMessageType.subscribeError));
    });

    test('draft-16: 0x05 returns requestError', () {
      final result = MoQMessageType.fromValue(0x05,
          version: MoQVersion.draft16);
      expect(result, equals(MoQMessageType.requestError));
    });

    test('draft-14: 0x07 returns publishNamespaceOk', () {
      final result = MoQMessageType.fromValue(0x07,
          version: MoQVersion.draft14);
      expect(result, equals(MoQMessageType.publishNamespaceOk));
    });

    test('draft-16: 0x07 returns requestOk', () {
      final result = MoQMessageType.fromValue(0x07,
          version: MoQVersion.draft16);
      expect(result, equals(MoQMessageType.requestOk));
    });

    test('draft-14: 0x08 returns publishNamespaceError', () {
      final result = MoQMessageType.fromValue(0x08,
          version: MoQVersion.draft14);
      expect(result, equals(MoQMessageType.publishNamespaceError));
    });

    test('draft-16: 0x08 returns namespace_', () {
      final result = MoQMessageType.fromValue(0x08,
          version: MoQVersion.draft16);
      expect(result, equals(MoQMessageType.namespace_));
    });

    test('draft-14: 0x0E returns trackStatusOk', () {
      final result = MoQMessageType.fromValue(0x0E,
          version: MoQVersion.draft14);
      expect(result, equals(MoQMessageType.trackStatusOk));
    });

    test('draft-16: 0x0E returns namespaceDone', () {
      final result = MoQMessageType.fromValue(0x0E,
          version: MoQVersion.draft16);
      expect(result, equals(MoQMessageType.namespaceDone));
    });

    test('draft-16: removed types return null', () {
      expect(MoQMessageType.fromValue(0x0F, version: MoQVersion.draft16),
          isNull); // TRACK_STATUS_ERROR
      expect(MoQMessageType.fromValue(0x12, version: MoQVersion.draft16),
          isNull); // SUBSCRIBE_NAMESPACE_OK
      expect(MoQMessageType.fromValue(0x13, version: MoQVersion.draft16),
          isNull); // SUBSCRIBE_NAMESPACE_ERROR
      expect(MoQMessageType.fromValue(0x14, version: MoQVersion.draft16),
          isNull); // UNSUBSCRIBE_NAMESPACE
      expect(MoQMessageType.fromValue(0x19, version: MoQVersion.draft16),
          isNull); // FETCH_ERROR
      expect(MoQMessageType.fromValue(0x1F, version: MoQVersion.draft16),
          isNull); // PUBLISH_ERROR
    });

    test('shared types resolve the same in both versions', () {
      expect(MoQMessageType.fromValue(0x03, version: MoQVersion.draft14),
          equals(MoQMessageType.subscribe));
      expect(MoQMessageType.fromValue(0x03, version: MoQVersion.draft16),
          equals(MoQMessageType.subscribe));
      expect(MoQMessageType.fromValue(0x20, version: MoQVersion.draft14),
          equals(MoQMessageType.clientSetup));
      expect(MoQMessageType.fromValue(0x20, version: MoQVersion.draft16),
          equals(MoQMessageType.clientSetup));
    });
  });

  // ============================================================
  // Setup message draft-16 tests
  // ============================================================

  group('ClientSetupMessage draft-16', () {
    test('draft-16 serializes without version list', () {
      final msg = ClientSetupMessage(
        supportedVersions: [MoQVersion.draft16], // ignored in draft-16
        parameters: [
          KeyValuePair.varint(SetupParameterType.maxRequestId, 100),
        ],
      );

      final bytes = msg.serialize(version: MoQVersion.draft16);
      final (parsed, _) =
          MoQControlMessageParser.parse(bytes, version: MoQVersion.draft16);

      expect(parsed, isA<ClientSetupMessage>());
      final result = parsed as ClientSetupMessage;
      // Draft-16: no versions in wire format
      expect(result.supportedVersions, isEmpty);
      expect(result.parameters.length, equals(1));
      expect(result.parameters[0].intValue, equals(100));
    });

    test('draft-14 serializes with version list (regression)', () {
      final msg = ClientSetupMessage(
        supportedVersions: [MoQVersion.draft14],
        parameters: [],
      );

      final bytes = msg.serialize(version: MoQVersion.draft14);
      final (parsed, _) =
          MoQControlMessageParser.parse(bytes, version: MoQVersion.draft14);

      expect(parsed, isA<ClientSetupMessage>());
      final result = parsed as ClientSetupMessage;
      expect(result.supportedVersions, equals([MoQVersion.draft14]));
    });
  });

  group('ServerSetupMessage draft-16', () {
    test('draft-16 serializes without selected version', () {
      final msg = ServerSetupMessage(
        selectedVersion: MoQVersion.draft16,
        parameters: [
          KeyValuePair.varint(SetupParameterType.maxRequestId, 50),
        ],
      );

      final bytes = msg.serialize(version: MoQVersion.draft16);
      final (parsed, _) =
          MoQControlMessageParser.parse(bytes, version: MoQVersion.draft16);

      expect(parsed, isA<ServerSetupMessage>());
      final result = parsed as ServerSetupMessage;
      // In draft-16, selectedVersion comes from the version param (ALPN)
      expect(result.selectedVersion, equals(MoQVersion.draft16));
      expect(result.parameters.length, equals(1));
      expect(result.parameters[0].intValue, equals(50));
    });
  });
}
