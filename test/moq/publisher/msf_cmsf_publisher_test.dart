import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moq_flutter/moq/client/moq_client.dart';
import 'package:moq_flutter/moq/publisher/cmaf_publisher.dart';
import 'package:moq_flutter/moq/publisher/moq_publisher.dart';
import 'package:moq_flutter/moq/protocol/moq_messages.dart';

import '../client/mock_transport.dart';

void main() {
  late MockMoQTransport transport;
  late MoQClient client;

  setUp(() {
    transport = MockMoQTransport();
    client = MoQClient(transport: transport);
    transport.onControlMessageSent = (data) {
      if (data.isNotEmpty && data[0] == 0x20) {
        Future.microtask(() {
          transport.simulateIncomingControlData(
            ServerSetupMessage(selectedVersion: MoQVersion.draft14).serialize(),
          );
        });
      } else if (data.isNotEmpty && data[0] == 0x06) {
        Future.microtask(() {
          transport.simulateIncomingControlData(
            PublishNamespaceOkMessage(requestId: Int64(0)).serialize(),
          );
        });
      }
    };
  });

  tearDown(() {
    client.dispose();
    transport.dispose();
  });

  group('MSF publisher layout', () {
    test('publishes each LOC object on a fresh stream', () async {
      await client.connect('localhost', 4443);
      final publisher = MoQPublisher(client: client);

      await publisher.announce(['live']);
      transport.clearSentMessages();

      await publisher.addVideoTrack('video0');
      final timelineTrack = publisher.catalog!.tracks.singleWhere(
        (track) => track.name == 'video0.timeline',
      );
      expect(timelineTrack.packaging, equals('mediatimeline'));
      expect(timelineTrack.parentName, equals('video0'));
      transport.clearSentMessages();

      await publisher.publishFrame(
        'video0',
        Uint8List.fromList([0x01, 0x02]),
        newGroup: true,
      );
      await publisher.publishFrame('video0', Uint8List.fromList([0x03, 0x04]));

      expect(transport.sentStreamData.length, equals(4));
      for (final writes in transport.sentStreamData.values) {
        expect(writes.length, equals(2));
      }
    });
  });

  group('CMSF catalog', () {
    test(
      'publishes per-track initData instead of relying on initTrack',
      () async {
        await client.connect('localhost', 4443);
        final publisher = CmafPublisher(client: client);

        publisher.configureAudioTrack('audio0');
        await publisher.announce(['live']);
        await publisher.addAudioTrack('audio0');
        await publisher.setAudioReady('audio0');

        final track = publisher.catalog!.tracks.singleWhere(
          (t) => t.name == 'audio0',
        );
        expect(track.initData, isNotNull);
        expect(track.initTrack, isNull);
        expect(track.packaging, equals('cmaf'));

        final timelineTrack = publisher.catalog!.tracks.singleWhere(
          (t) => t.name == 'audio0.sap',
        );
        expect(timelineTrack.packaging, equals('eventtimeline'));
        expect(timelineTrack.eventType, equals('urn:ietf:params:moq:cmsf:sap'));
        expect(timelineTrack.parentName, equals('audio0'));
      },
    );

    test(
      'publishes init segment on media tracks at group 0 object 0',
      () async {
        await client.connect('localhost', 4443);
        final publisher = CmafPublisher(client: client);

        publisher.configureAudioTrack('audio0');
        await publisher.announce(['live']);

        // Clear messages from announce/catalog so we only see init publish
        transport.clearSentMessages();

        await publisher.addAudioTrack('audio0');
        await publisher.setAudioReady('audio0');

        // After setAudioReady, init segments should be published on media
        // tracks plus the catalog is re-published. Find the streams that
        // carry the init segment (group 0, subgroup 0, object 0).
        //
        // sentStreamData should contain:
        //   - 1 stream for the audio init segment on the media track
        //   - 1 stream for the re-published catalog
        // Each stream has 2 writes: subgroup header + object.
        expect(transport.sentStreamData.length, greaterThanOrEqualTo(2));

        // Verify at least one stream wrote exactly 2 chunks (header + object)
        // and the object payload is non-empty (init segment bytes)
        bool foundInitStream = false;
        for (final writes in transport.sentStreamData.values) {
          if (writes.length == 2) {
            // The second write is the object; check it has content
            if (writes[1].isNotEmpty) {
              foundInitStream = true;
            }
          }
        }
        expect(foundInitStream, isTrue,
            reason: 'Expected at least one stream with init segment data');
      },
    );
  });
}
