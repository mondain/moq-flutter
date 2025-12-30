import 'dart:async';
import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moq_flutter/moq/client/moq_client.dart';
import 'package:moq_flutter/moq/protocol/moq_messages.dart';
import 'mock_transport.dart';

void main() {
  late MockMoQTransport transport;
  late MoQClient client;

  setUp(() {
    transport = MockMoQTransport();
    client = MoQClient(transport: transport);
  });

  tearDown(() {
    client.dispose();
    transport.dispose();
  });

  group('Connection Flow', () {
    test('connect sends CLIENT_SETUP and waits for SERVER_SETUP', () async {
      // Set up auto-response for SERVER_SETUP
      transport.onControlMessageSent = (data) {
        // Check if it's a CLIENT_SETUP (type 0x20)
        if (data.isNotEmpty && data[0] == 0x20) {
          // Send SERVER_SETUP response
          final serverSetup = ServerSetupMessage(selectedVersion: 0xff00000e);
          // Schedule to send after current microtask
          Future.microtask(() {
            transport.simulateIncomingControlData(serverSetup.serialize());
          });
        }
      };

      await client.connect('localhost', 4443);

      expect(client.isConnected, isTrue);
      expect(client.selectedVersion, equals(0xff00000e));
      expect(transport.sentControlMessages.length, equals(1));

      // Verify CLIENT_SETUP was sent
      final sentData = transport.sentControlMessages.first;
      expect(sentData[0], equals(0x20)); // CLIENT_SETUP type
    });

    test('connect times out without SERVER_SETUP', () async {
      // Don't send SERVER_SETUP response
      expect(
        () => client.connect('localhost', 4443),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('disconnect clears state', () async {
      // Connect first
      transport.onControlMessageSent = (data) {
        if (data.isNotEmpty && data[0] == 0x20) {
          Future.microtask(() {
            transport.simulateIncomingControlData(
              ServerSetupMessage(selectedVersion: 0xff00000e).serialize(),
            );
          });
        }
      };

      await client.connect('localhost', 4443);
      expect(client.isConnected, isTrue);

      await client.disconnect();
      expect(client.isConnected, isFalse);
    });

    test('server setup parameters are processed', () async {
      transport.onControlMessageSent = (data) {
        if (data.isNotEmpty && data[0] == 0x20) {
          Future.microtask(() {
            // Send SERVER_SETUP with parameters
            final maxSubId = MoQWireFormat.encodeVarint(100);
            final maxTrackAlias = MoQWireFormat.encodeVarint(50);

            final serverSetup = ServerSetupMessage(
              selectedVersion: 0xff00000e,
              parameters: [
                KeyValuePair(type: 0x0001, value: maxSubId), // max_subscribe_id
                KeyValuePair(type: 0x0002, value: maxTrackAlias), // max_track_alias
              ],
            );
            transport.simulateIncomingControlData(serverSetup.serialize());
          });
        }
      };

      await client.connect('localhost', 4443);

      expect(client.maxSubscriptionId, equals(100));
      expect(client.maxTrackAlias, equals(50));
    });
  });

  group('Subscription Flow', () {
    setUp(() async {
      // Auto-connect for subscription tests
      transport.onControlMessageSent = (data) {
        if (data.isNotEmpty && data[0] == 0x20) {
          Future.microtask(() {
            transport.simulateIncomingControlData(
              ServerSetupMessage(selectedVersion: 0xff00000e).serialize(),
            );
          });
        }
      };
      await client.connect('localhost', 4443);
      transport.clearSentMessages();
    });

    test('subscribe sends SUBSCRIBE and receives SUBSCRIBE_OK', () async {
      final namespace = [Uint8List.fromList('test'.codeUnits)];
      final trackName = Uint8List.fromList('track1'.codeUnits);

      // Set up SUBSCRIBE_OK response
      transport.onControlMessageSent = (data) {
        if (data.isNotEmpty && data[0] == 0x03) {
          // SUBSCRIBE type
          Future.microtask(() {
            final subscribeOk = SubscribeOkMessage(
              requestId: Int64(0), // First request ID
              trackAlias: Int64(1),
              expires: Int64(60000),
              groupOrder: GroupOrder.ascending,
              contentExists: 1,
              largestLocation: Location(group: Int64(10), object: Int64(5)),
            );
            transport.simulateIncomingControlData(subscribeOk.serialize());
          });
        }
      };

      final result = await client.subscribe(namespace, trackName);

      expect(result.trackAlias, equals(Int64(1)));
      expect(result.expires, equals(Int64(60000)));
      expect(result.groupOrder, equals(GroupOrder.ascending));
      expect(result.contentExists, isTrue);
      expect(result.largestLocation?.group, equals(Int64(10)));
      expect(result.largestLocation?.object, equals(Int64(5)));

      // Verify SUBSCRIBE was sent
      expect(transport.sentControlMessages.length, equals(1));
      expect(transport.sentControlMessages.first[0], equals(0x03));
    });

    test('subscribe handles SUBSCRIBE_ERROR', () async {
      final namespace = [Uint8List.fromList('test'.codeUnits)];
      final trackName = Uint8List.fromList('track1'.codeUnits);

      transport.onControlMessageSent = (data) {
        if (data.isNotEmpty && data[0] == 0x03) {
          Future.microtask(() {
            final subscribeError = SubscribeErrorMessage(
              requestId: Int64(0),
              errorCode: 0x04, // TRACK_DOES_NOT_EXIST
              errorReason: ReasonPhrase('Track not found'),
            );
            transport.simulateIncomingControlData(subscribeError.serialize());
          });
        }
      };

      expect(
        () => client.subscribe(namespace, trackName),
        throwsA(isA<MoQException>().having(
          (e) => e.errorCode,
          'errorCode',
          equals(0x04),
        )),
      );
    });

    test('unsubscribe sends UNSUBSCRIBE message', () async {
      final namespace = [Uint8List.fromList('test'.codeUnits)];
      final trackName = Uint8List.fromList('track1'.codeUnits);

      // First subscribe
      transport.onControlMessageSent = (data) {
        if (data.isNotEmpty && data[0] == 0x03) {
          Future.microtask(() {
            transport.simulateIncomingControlData(
              SubscribeOkMessage(
                requestId: Int64(0),
                trackAlias: Int64(1),
                expires: Int64(0),
                groupOrder: GroupOrder.ascending,
                contentExists: 0,
              ).serialize(),
            );
          });
        }
      };

      await client.subscribe(namespace, trackName);
      transport.clearSentMessages();

      // Unsubscribe
      await client.unsubscribe(Int64(0));

      expect(transport.sentControlMessages.length, equals(1));
      expect(transport.sentControlMessages.first[0], equals(0x0A)); // UNSUBSCRIBE
    });
  });

  group('FETCH Flow', () {
    setUp(() async {
      transport.onControlMessageSent = (data) {
        if (data.isNotEmpty && data[0] == 0x20) {
          Future.microtask(() {
            transport.simulateIncomingControlData(
              ServerSetupMessage(selectedVersion: 0xff00000e).serialize(),
            );
          });
        }
      };
      await client.connect('localhost', 4443);
      transport.clearSentMessages();
    });

    test('standalone fetch sends FETCH and receives FETCH_OK', () async {
      final namespace = [Uint8List.fromList('test'.codeUnits)];
      final trackName = Uint8List.fromList('track1'.codeUnits);
      final startLocation = Location(group: Int64(0), object: Int64(0));
      final endLocation = Location(group: Int64(10), object: Int64(0));

      transport.onControlMessageSent = (data) {
        if (data.isNotEmpty && data[0] == 0x16) {
          // FETCH type
          Future.microtask(() {
            final fetchOk = FetchOkMessage(
              requestId: Int64(0),
              groupOrder: GroupOrder.ascending,
              endOfTrack: 0,
              endLocation: Location(group: Int64(10), object: Int64(5)),
            );
            transport.simulateIncomingControlData(fetchOk.serialize());
          });
        }
      };

      final result = await client.fetch(
        namespace,
        trackName,
        startLocation: startLocation,
        endLocation: endLocation,
      );

      expect(result.groupOrder, equals(GroupOrder.ascending));
      expect(result.endOfTrack, isFalse);
      expect(result.endLocation.group, equals(Int64(10)));
      expect(result.endLocation.object, equals(Int64(5)));

      // Verify FETCH was sent
      expect(transport.sentControlMessages.length, equals(1));
      expect(transport.sentControlMessages.first[0], equals(0x16));
    });

    test('fetch handles FETCH_ERROR', () async {
      final namespace = [Uint8List.fromList('test'.codeUnits)];
      final trackName = Uint8List.fromList('track1'.codeUnits);

      transport.onControlMessageSent = (data) {
        if (data.isNotEmpty && data[0] == 0x16) {
          Future.microtask(() {
            final fetchError = FetchErrorMessage(
              requestId: Int64(0),
              errorCode: 0x05, // INVALID_RANGE
              errorReason: ReasonPhrase('Invalid range'),
            );
            transport.simulateIncomingControlData(fetchError.serialize());
          });
        }
      };

      expect(
        () => client.fetch(
          namespace,
          trackName,
          startLocation: Location(group: Int64(100), object: Int64(0)),
          endLocation: Location(group: Int64(50), object: Int64(0)),
        ),
        throwsA(isA<MoQException>().having(
          (e) => e.errorCode,
          'errorCode',
          equals(0x05),
        )),
      );
    });

    test('cancelFetch sends FETCH_CANCEL', () async {
      final namespace = [Uint8List.fromList('test'.codeUnits)];
      final trackName = Uint8List.fromList('track1'.codeUnits);

      // Start fetch but don't respond yet
      bool fetchStarted = false;
      transport.onControlMessageSent = (data) {
        if (data.isNotEmpty && data[0] == 0x16) {
          fetchStarted = true;
          // Don't respond - leave fetch pending
        }
      };

      // Start fetch without awaiting
      final fetchFuture = client.fetch(
        namespace,
        trackName,
        startLocation: Location(group: Int64(0), object: Int64(0)),
        endLocation: Location(group: Int64(10), object: Int64(0)),
      );

      // Wait for fetch to be sent
      await Future.delayed(Duration(milliseconds: 10));
      expect(fetchStarted, isTrue);

      transport.clearSentMessages();

      // Cancel the fetch
      await client.cancelFetch(Int64(0));

      expect(transport.sentControlMessages.length, equals(1));
      expect(transport.sentControlMessages.first[0], equals(0x17)); // FETCH_CANCEL

      // The fetch future should fail (we cancelled it)
      expect(fetchFuture, throwsA(anything));
    });
  });

  group('Namespace Operations', () {
    setUp(() async {
      transport.onControlMessageSent = (data) {
        if (data.isNotEmpty && data[0] == 0x20) {
          Future.microtask(() {
            transport.simulateIncomingControlData(
              ServerSetupMessage(selectedVersion: 0xff00000e).serialize(),
            );
          });
        }
      };
      await client.connect('localhost', 4443);
      transport.clearSentMessages();
    });

    test('announceNamespace sends message and receives OK', () async {
      final namespace = [Uint8List.fromList('live'.codeUnits)];

      transport.onControlMessageSent = (data) {
        if (data.isNotEmpty && data[0] == 0x06) {
          // PUBLISH_NAMESPACE
          Future.microtask(() {
            transport.simulateIncomingControlData(
              PublishNamespaceOkMessage(requestId: Int64(0)).serialize(),
            );
          });
        }
      };

      await client.announceNamespace(namespace);

      expect(transport.sentControlMessages.length, equals(1));
      expect(transport.sentControlMessages.first[0], equals(0x06));
    });

    test('announceNamespace handles error', () async {
      final namespace = [Uint8List.fromList('unauthorized'.codeUnits)];

      transport.onControlMessageSent = (data) {
        if (data.isNotEmpty && data[0] == 0x06) {
          Future.microtask(() {
            transport.simulateIncomingControlData(
              PublishNamespaceErrorMessage(
                requestId: Int64(0),
                errorCode: 0x01, // UNAUTHORIZED
                errorReason: ReasonPhrase('Not authorized'),
              ).serialize(),
            );
          });
        }
      };

      expect(
        () => client.announceNamespace(namespace),
        throwsA(isA<MoQException>().having(
          (e) => e.errorCode,
          'errorCode',
          equals(0x01),
        )),
      );
    });

    test('subscribeNamespace sends message and receives OK', () async {
      final prefix = [Uint8List.fromList('live'.codeUnits)];

      transport.onControlMessageSent = (data) {
        if (data.isNotEmpty && data[0] == 0x11) {
          // SUBSCRIBE_NAMESPACE
          Future.microtask(() {
            transport.simulateIncomingControlData(
              SubscribeNamespaceOkMessage(requestId: Int64(0)).serialize(),
            );
          });
        }
      };

      final subscription = await client.subscribeNamespace(prefix);

      expect(subscription.namespacePrefixPath, equals('live'));
      expect(transport.sentControlMessages.length, equals(1));
      expect(transport.sentControlMessages.first[0], equals(0x11));
    });

    test('unsubscribeNamespace sends message', () async {
      final prefix = [Uint8List.fromList('live'.codeUnits)];

      // First subscribe
      transport.onControlMessageSent = (data) {
        if (data.isNotEmpty && data[0] == 0x11) {
          Future.microtask(() {
            transport.simulateIncomingControlData(
              SubscribeNamespaceOkMessage(requestId: Int64(0)).serialize(),
            );
          });
        }
      };

      await client.subscribeNamespace(prefix);
      transport.clearSentMessages();

      // Unsubscribe
      await client.unsubscribeNamespace(prefix);

      expect(transport.sentControlMessages.length, equals(1));
      expect(transport.sentControlMessages.first[0], equals(0x14)); // UNSUBSCRIBE_NAMESPACE
    });
  });

  group('GOAWAY Handling', () {
    setUp(() async {
      transport.onControlMessageSent = (data) {
        if (data.isNotEmpty && data[0] == 0x20) {
          Future.microtask(() {
            transport.simulateIncomingControlData(
              ServerSetupMessage(selectedVersion: 0xff00000e).serialize(),
            );
          });
        }
      };
      await client.connect('localhost', 4443);
      transport.clearSentMessages();
    });

    test('GOAWAY event is emitted', () async {
      final goawayFuture = client.goawayEvents.first;

      // Simulate GOAWAY from server
      // Note: Include lastRequestId to avoid deserialize ambiguity with short URIs
      final goaway = GoawayMessage(
        lastRequestId: Int64(0),
        newUri: 'https://newserver.example.com',
      );
      transport.simulateIncomingControlData(goaway.serialize());

      final event = await goawayFuture.timeout(Duration(seconds: 1));

      expect(event.newUri, equals('https://newserver.example.com'));
      expect(event.hasMigrationUri, isTrue);
    });

    test('GOAWAY without URI', () async {
      final goawayFuture = client.goawayEvents.first;

      // Simulate GOAWAY without new URI
      final goaway = GoawayMessage();
      transport.simulateIncomingControlData(goaway.serialize());

      final event = await goawayFuture.timeout(Duration(seconds: 1));

      expect(event.newUri, isNull);
      expect(event.hasMigrationUri, isFalse);
    });
  });

  group('Publisher Mode (Server-side handling)', () {
    setUp(() async {
      transport.onControlMessageSent = (data) {
        if (data.isNotEmpty && data[0] == 0x20) {
          Future.microtask(() {
            transport.simulateIncomingControlData(
              ServerSetupMessage(selectedVersion: 0xff00000e).serialize(),
            );
          });
        }
      };
      await client.connect('localhost', 4443);
      transport.clearSentMessages();
    });

    test('incoming SUBSCRIBE request is surfaced', () async {
      final requestFuture = client.incomingSubscribeRequests.first;

      // Simulate incoming SUBSCRIBE from relay
      final subscribe = SubscribeMessage(
        requestId: Int64(1), // Odd = from server
        trackNamespace: [Uint8List.fromList('test'.codeUnits)],
        trackName: Uint8List.fromList('track1'.codeUnits),
        subscriberPriority: 128,
        groupOrder: GroupOrder.ascending,
        forward: 1,
        filterType: FilterType.largestObject,
      );
      transport.simulateIncomingControlData(subscribe.serialize());

      final request = await requestFuture.timeout(Duration(seconds: 1));

      expect(request.namespacePath, equals('test'));
      expect(request.trackNameString, equals('track1'));
      expect(request.subscriberPriority, equals(128));
    });

    test('acceptSubscribe sends SUBSCRIBE_OK', () async {
      // First receive a SUBSCRIBE
      final subscribe = SubscribeMessage(
        requestId: Int64(1),
        trackNamespace: [Uint8List.fromList('test'.codeUnits)],
        trackName: Uint8List.fromList('track1'.codeUnits),
        subscriberPriority: 128,
        groupOrder: GroupOrder.ascending,
        forward: 1,
        filterType: FilterType.largestObject,
      );
      transport.simulateIncomingControlData(subscribe.serialize());

      // Wait for request to be processed
      await Future.delayed(Duration(milliseconds: 10));

      await client.acceptSubscribe(
        Int64(1),
        trackAlias: Int64(100),
        expires: Int64(60000),
        groupOrder: GroupOrder.ascending,
        contentExists: true,
        largestLocation: Location(group: Int64(5), object: Int64(2)),
      );

      expect(transport.sentControlMessages.length, equals(1));
      expect(transport.sentControlMessages.first[0], equals(0x04)); // SUBSCRIBE_OK
    });

    test('rejectSubscribe sends SUBSCRIBE_ERROR', () async {
      final subscribe = SubscribeMessage(
        requestId: Int64(1),
        trackNamespace: [Uint8List.fromList('test'.codeUnits)],
        trackName: Uint8List.fromList('track1'.codeUnits),
        subscriberPriority: 128,
        groupOrder: GroupOrder.ascending,
        forward: 1,
        filterType: FilterType.largestObject,
      );
      transport.simulateIncomingControlData(subscribe.serialize());

      await Future.delayed(Duration(milliseconds: 10));

      await client.rejectSubscribe(
        Int64(1),
        errorCode: 0x04,
        reason: 'Track not available',
      );

      expect(transport.sentControlMessages.length, equals(1));
      expect(transport.sentControlMessages.first[0], equals(0x05)); // SUBSCRIBE_ERROR
    });

    test('sendPublishDone sends PUBLISH_DONE', () async {
      // First accept a subscription
      final subscribe = SubscribeMessage(
        requestId: Int64(1),
        trackNamespace: [Uint8List.fromList('test'.codeUnits)],
        trackName: Uint8List.fromList('track1'.codeUnits),
        subscriberPriority: 128,
        groupOrder: GroupOrder.ascending,
        forward: 1,
        filterType: FilterType.largestObject,
      );
      transport.simulateIncomingControlData(subscribe.serialize());

      await Future.delayed(Duration(milliseconds: 10));

      await client.acceptSubscribe(
        Int64(1),
        trackAlias: Int64(100),
        expires: Int64(0),
        groupOrder: GroupOrder.ascending,
        contentExists: false,
      );

      transport.clearSentMessages();

      // Send PUBLISH_DONE
      await client.sendPublishDone(
        Int64(1),
        statusCode: 0x03, // TRACK_ENDED
        streamCount: Int64(5),
        reason: 'Stream complete',
      );

      expect(transport.sentControlMessages.length, equals(1));
      expect(transport.sentControlMessages.first[0], equals(0x0B)); // PUBLISH_DONE
    });
  });

  group('Data Stream Handling', () {
    setUp(() async {
      transport.onControlMessageSent = (data) {
        if (data.isNotEmpty && data[0] == 0x20) {
          Future.microtask(() {
            transport.simulateIncomingControlData(
              ServerSetupMessage(selectedVersion: 0xff00000e).serialize(),
            );
          });
        }
      };
      await client.connect('localhost', 4443);
      transport.clearSentMessages();
    });

    test('openDataStream returns stream ID', () async {
      final streamId = await client.openDataStream();
      expect(streamId, isPositive);
    });

    test('writeSubgroupHeader writes header to stream', () async {
      final streamId = await client.openDataStream();

      await client.writeSubgroupHeader(
        streamId,
        trackAlias: Int64(1),
        groupId: Int64(10),
        subgroupId: Int64(0),
        publisherPriority: 128,
      );

      expect(transport.sentStreamData[streamId], isNotNull);
      expect(transport.sentStreamData[streamId]!.length, equals(1));

      // Check header starts with type 0x10
      final headerData = transport.sentStreamData[streamId]!.first;
      expect(headerData[0], equals(0x10));
    });
  });
}
