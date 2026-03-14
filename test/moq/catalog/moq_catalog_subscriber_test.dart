import 'dart:async';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moq_flutter/moq/catalog/moq_catalog.dart';
import 'package:moq_flutter/moq/catalog/moq_catalog_subscriber.dart';
import 'package:moq_flutter/moq/catalog/moq_timeline.dart';
import 'package:moq_flutter/moq/client/moq_client.dart';
import 'package:moq_flutter/moq/protocol/moq_messages.dart';

import '../client/mock_transport.dart';

void main() {
  late MockMoQTransport transport;
  late MoQClient client;
  final aliasByTrack = <String, Int64>{
    'catalog': Int64(1),
    '.catalog': Int64(1),
    'video0': Int64(2),
    'video0.timeline': Int64(3),
  };

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
      } else if (data.isNotEmpty && data[0] == 0x03) {
        final payloadLength = (data[1] << 8) | data[2];
        final payload = data.sublist(3, 3 + payloadLength);
        final subscribe = SubscribeMessage.deserialize(payload);
        final trackName = String.fromCharCodes(subscribe.trackName);
        Future.microtask(() {
          transport.simulateIncomingControlData(
            SubscribeOkMessage(
              requestId: subscribe.requestId,
              trackAlias: aliasByTrack[trackName] ?? Int64(99),
              expires: Int64.ZERO,
              groupOrder: GroupOrder.descending,
              contentExists: 1,
              largestLocation: Location.zero(),
            ).serialize(),
          );
        });
      } else if (data.isNotEmpty && data[0] == 0x0A) {
        // UNSUBSCRIBE, no response required.
      }
    };
  });

  tearDown(() async {
    client.dispose();
    transport.dispose();
  });

  group('MoQCatalogSubscriber', () {
    test(
      'subscribes to catalog, media tracks, and timeline sidecars',
      () async {
        await client.connect('localhost', 4443);
        final subscriber = MoQCatalogSubscriber(client: client);
        final namespace = [Uint8List.fromList('live'.codeUnits)];

        final catalogFuture = subscriber.subscribeCatalog(namespace);
        await _pushObject(
          client: client,
          transport: transport,
          streamId: 11,
          trackAlias: aliasByTrack['catalog']!,
          payload: MoQCatalog.loc(
            namespace: 'live',
            tracks: [
              CatalogTrack(
                name: 'video0',
                namespace: 'live',
                packaging: 'loc',
                role: 'video',
              ),
              CatalogTrack(
                name: 'video0.timeline',
                namespace: 'live',
                packaging: 'mediatimeline',
                role: 'timeline',
                parentName: 'video0',
                depends: const ['video0'],
              ),
            ],
          ).toBytes(),
        );

        final catalog = await catalogFuture;
        expect(catalog.tracks.length, equals(2));

        final timelineUpdateFuture = subscriber.timelineUpdates.first;
        final session = await subscriber.subscribePlaybackTracks(
          namespace,
          videoTrackName: 'video0',
        );

        expect(
          session.mediaTracks.map((track) => track.name),
          equals(['video0']),
        );
        expect(
          session.timelineTracks.map((track) => track.name),
          equals(['video0.timeline']),
        );
        expect(session.mediaSubscriptions.length, equals(1));
        expect(session.timelineSubscriptions.length, equals(1));

        await _pushObject(
          client: client,
          transport: transport,
          streamId: 12,
          trackAlias: aliasByTrack['video0.timeline']!,
          payload: encodeMediaTimeline([
            MediaTimelineEntry(
              mediaTime: 1000,
              location: Location(group: Int64(7), object: Int64(2)),
              wallclock: 123456,
            ),
          ]),
        );

        final update = await timelineUpdateFuture;
        expect(update.parentTrackName, equals('video0'));
        expect(update.mediaEntries, isNotNull);
        expect(update.mediaEntries!.single.location.group, equals(Int64(7)));
        expect(update.mediaEntries!.single.location.object, equals(Int64(2)));

        await session.close();
        await subscriber.dispose();
      },
    );
  });
}

Future<void> _pushObject({
  required MoQClient client,
  required MockMoQTransport transport,
  required int streamId,
  required Int64 trackAlias,
  required Uint8List payload,
}) async {
  final encodedStreamId = await client.openDataStream();
  await client.writeSubgroupHeader(
    encodedStreamId,
    trackAlias: trackAlias,
    groupId: Int64.ZERO,
    subgroupId: Int64.ZERO,
    publisherPriority: 128,
  );
  await client.writeObject(
    encodedStreamId,
    objectId: Int64.ZERO,
    payload: payload,
  );

  final writes = transport.sentStreamData[encodedStreamId]!;
  transport.sentStreamData.remove(encodedStreamId);

  transport.simulateIncomingDataStream(streamId, writes[0]);
  transport.simulateIncomingDataStream(streamId, writes[1], isComplete: true);
}
