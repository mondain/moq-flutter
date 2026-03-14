import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moq_flutter/moq/catalog/moq_catalog.dart';

void main() {
  group('MoQCatalog', () {
    test('serializes flattened MSF/CMSF-style track metadata', () {
      final catalog = MoQCatalog.cmaf(
        namespace: 'live/demo',
        tracks: [
          CatalogTrack(
            name: 'video',
            role: 'video',
            packaging: 'cmaf',
            targetLatency: 1500,
            isLive: true,
            timescale: 90000,
            maxGroupSapStartingType: 1,
            maxObjectSapStartingType: 1,
            initData: 'AAAA',
            selectionParams: SelectionParams(
              codec: 'avc1.64001f',
              mimeType: 'video/mp4',
              width: 1280,
              height: 720,
              framerate: 30,
            ),
          ),
        ],
      );

      final json = jsonDecode(catalog.toJson()) as Map<String, dynamic>;
      final track =
          (json['tracks'] as List<dynamic>).single as Map<String, dynamic>;

      expect(json.containsKey('generatedAt'), isTrue);
      expect(json['isComplete'], isFalse);
      expect(json.containsKey('commonTrackFields'), isFalse);
      expect(track['name'], equals('video'));
      expect(track['namespace'], equals('live/demo'));
      expect(track['packaging'], equals('cmaf'));
      expect(track['codec'], equals('avc1.64001f'));
      expect(track['mimeType'], equals('video/mp4'));
      expect(track['targetLatency'], equals(1500));
      expect(track['isLive'], isTrue);
      expect(track['initData'], equals('AAAA'));
      expect(track.containsKey('selectionParams'), isFalse);
    });

    test('parses legacy commonTrackFields and nested selectionParams', () {
      const legacyJson = '''
      {
        "version": 1,
        "commonTrackFields": {
          "namespace": "legacy/ns",
          "packaging": "loc",
          "renderGroup": 2
        },
        "tracks": [
          {
            "name": "audio",
            "selectionParams": {
              "codec": "opus",
              "samplerate": 48000
            }
          }
        ]
      }
      ''';

      final catalog = MoQCatalog.fromJson(legacyJson);
      final track = catalog.tracks.single;

      expect(track.namespace, equals('legacy/ns'));
      expect(track.packaging, equals('loc'));
      expect(track.renderGroup, equals(2));
      expect(track.selectionParams?.codec, equals('opus'));
      expect(track.selectionParams?.samplerate, equals(48000));
    });
  });
}
