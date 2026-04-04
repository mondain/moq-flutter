import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moq_flutter/moq/catalog/moq_catalog.dart';

void main() {
  group('MoQCatalog MSF/CMSF', () {
    test('serializes MSF-style LOC catalog per draft-ietf-moq-msf-00', () {
      final catalog = MoQCatalog.loc(
        namespace: 'conference.example.com/conference123/alice',
        tracks: [
          CatalogTrack(
            name: '1080p-video',
            packaging: 'loc',
            isLive: true,
            targetLatency: 2000,
            role: 'video',
            renderGroup: 1,
            codec: 'av01.0.08M.10.0.110.09',
            width: 1920,
            height: 1080,
            framerate: 30,
            bitrate: 1500000,
          ),
          CatalogTrack(
            name: 'audio',
            packaging: 'loc',
            isLive: true,
            targetLatency: 2000,
            role: 'audio',
            renderGroup: 1,
            codec: 'opus',
            samplerate: 48000,
            channelConfig: '2',
            bitrate: 32000,
          ),
        ],
      );

      final json = jsonDecode(catalog.toJson()) as Map<String, dynamic>;
      expect(json['version'], equals(1));
      // MSF: no streamingFormat or streamingFormatVersion at root
      expect(json.containsKey('streamingFormat'), isFalse);
      expect(json.containsKey('streamingFormatVersion'), isFalse);
      expect(json.containsKey('commonTrackFields'), isFalse);

      final tracks = json['tracks'] as List<dynamic>;
      expect(tracks.length, equals(2));

      final video = tracks[0] as Map<String, dynamic>;
      expect(video['name'], equals('1080p-video'));
      expect(video['packaging'], equals('loc'));
      expect(video['codec'], equals('av01.0.08M.10.0.110.09'));
      expect(video['width'], equals(1920));
      expect(video['isLive'], isTrue);
      expect(video['role'], equals('video'));
      // Selection params are flattened (no nested selectionParams object)
      expect(video.containsKey('selectionParams'), isFalse);
    });

    test('serializes CMSF-style CMAF catalog per draft-ietf-moq-cmsf-00', () {
      final catalog = MoQCatalog.cmaf(
        namespace: 'live/demo',
        tracks: [
          CatalogTrack(
            name: 'video_1080',
            packaging: 'cmaf',
            role: 'video',
            isLive: true,
            targetLatency: 1500,
            maxGrpSapStartingType: 1,
            maxObjSapStartingType: 1,
            initData: 'AAAA',
            renderGroup: 1,
            codec: 'avc1.640028',
            mimeType: 'video/mp4',
            width: 1920,
            height: 1080,
            framerate: 30,
            bitrate: 6000000,
          ),
        ],
      );

      final json = jsonDecode(catalog.toJson()) as Map<String, dynamic>;
      final track =
          (json['tracks'] as List<dynamic>).single as Map<String, dynamic>;

      expect(track['packaging'], equals('cmaf'));
      expect(track['initData'], equals('AAAA'));
      expect(track['maxGrpSapStartingType'], equals(1));
      expect(track['maxObjSapStartingType'], equals(1));
      expect(track['codec'], equals('avc1.640028'));
      expect(track['mimeType'], equals('video/mp4'));
    });

    test('delta update catalog with addTracks/removeTracks/cloneTracks', () {
      final catalog = MoQCatalog(
        deltaUpdate: true,
        generatedAt: 1746104606044,
        tracks: [],
        addTracks: [
          CatalogTrack(
            name: 'slides',
            packaging: 'loc',
            isLive: true,
            role: 'video',
            codec: 'av01.0.08M.10.0.110.09',
            width: 1920,
            height: 1080,
            framerate: 15,
            bitrate: 750000,
            renderGroup: 1,
          ),
        ],
        removeTracks: ['old-video'],
        cloneTracks: [
          CatalogCloneTrack(
            parentName: 'video-1080',
            name: 'video-720',
            overrides: {'width': 1280, 'height': 720, 'bitrate': 600000},
          ),
        ],
      );

      final json = jsonDecode(catalog.toJson()) as Map<String, dynamic>;
      expect(json['deltaUpdate'], isTrue);
      expect(json.containsKey('version'), isFalse);
      expect(json.containsKey('tracks'), isFalse);

      final addTracks = json['addTracks'] as List<dynamic>;
      expect(addTracks.length, equals(1));
      expect((addTracks[0] as Map)['name'], equals('slides'));

      final removeTracks = json['removeTracks'] as List<dynamic>;
      expect(removeTracks, equals(['old-video']));

      final clones = json['cloneTracks'] as List<dynamic>;
      expect(clones.length, equals(1));
      final clone = clones[0] as Map<String, dynamic>;
      expect(clone['parentName'], equals('video-1080'));
      expect(clone['name'], equals('video-720'));
      expect(clone['width'], equals(1280));
    });

    test('fromJson parses MSF catalog', () {
      const input = '''
      {
        "version": 1,
        "generatedAt": 1746104606044,
        "tracks": [
          {
            "name": "video",
            "namespace": "live/demo",
            "packaging": "loc",
            "isLive": true,
            "role": "video",
            "codec": "avc1.64001f",
            "width": 1280,
            "height": 720,
            "framerate": 30,
            "bitrate": 3000000
          }
        ]
      }
      ''';

      final catalog = MoQCatalog.fromJson(input);
      expect(catalog.version, equals(1));
      expect(catalog.tracks.length, equals(1));
      final track = catalog.tracks.first;
      expect(track.codec, equals('avc1.64001f'));
      expect(track.width, equals(1280));
      expect(track.packaging, equals('loc'));
      expect(track.isLive, isTrue);
    });

    test('fromJson parses legacy commonTrackFields and nested selectionParams', () {
      const legacyJson = '''
      {
        "version": 1,
        "streamingFormat": 1,
        "streamingFormatVersion": "0.2",
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

      // commonTrackFields inherited
      expect(track.namespace, equals('legacy/ns'));
      expect(track.packaging, equals('loc'));
      expect(track.renderGroup, equals(2));
      // selectionParams flattened into track
      expect(track.codec, equals('opus'));
      expect(track.samplerate, equals(48000));
    });

    test('fromJson parses delta update with cloneTracks', () {
      const input = '''
      {
        "deltaUpdate": true,
        "addTracks": [
          {"name": "new-track", "packaging": "loc", "isLive": true}
        ],
        "removeTracks": ["old-track"],
        "cloneTracks": [
          {"parentName": "hd", "name": "sd", "width": 640, "height": 480}
        ]
      }
      ''';

      final catalog = MoQCatalog.fromJson(input);
      expect(catalog.deltaUpdate, isTrue);
      expect(catalog.addTracks?.length, equals(1));
      expect(catalog.addTracks!.first.name, equals('new-track'));
      expect(catalog.removeTracks, equals(['old-track']));
      expect(catalog.cloneTracks?.length, equals(1));
      expect(catalog.cloneTracks!.first.parentName, equals('hd'));
      expect(catalog.cloneTracks!.first.overrides['width'], equals(640));
    });

    test('round-trip preserves all MSF fields', () {
      final original = MoQCatalog(
        generatedAt: 1700000000,
        isComplete: true,
        tracks: [
          CatalogTrack(
            name: 'video',
            namespace: 'ns/one',
            packaging: 'loc',
            isLive: true,
            targetLatency: 2000,
            renderGroup: 1,
            role: 'video',
            codec: 'avc1.640028',
            width: 1920,
            height: 1080,
            framerate: 30,
            bitrate: 3000000,
          ),
          CatalogTrack(
            name: 'audio',
            namespace: 'ns/one',
            packaging: 'loc',
            isLive: true,
            role: 'audio',
            codec: 'opus',
            samplerate: 48000,
            channelConfig: '2',
          ),
        ],
      );

      final roundTripped = MoQCatalog.fromJson(original.toJson());
      expect(roundTripped.version, equals(original.version));
      expect(roundTripped.generatedAt, equals(original.generatedAt));
      expect(roundTripped.isComplete, equals(original.isComplete));
      expect(roundTripped.tracks.length, equals(2));
      expect(roundTripped.tracks[0].codec, equals('avc1.640028'));
      expect(roundTripped.tracks[0].role, equals('video'));
      expect(roundTripped.tracks[1].samplerate, equals(48000));
      expect(roundTripped.tracks[1].channelConfig, equals('2'));
    });

    test('VOD catalog with trackDuration', () {
      final catalog = MoQCatalog(
        tracks: [
          CatalogTrack(
            name: 'video',
            packaging: 'loc',
            isLive: false,
            trackDuration: 8072340,
            codec: 'avc1.640028',
            width: 1920,
            height: 1080,
          ),
        ],
      );

      final json = jsonDecode(catalog.toJson()) as Map<String, dynamic>;
      final track = (json['tracks'] as List).first as Map<String, dynamic>;
      expect(track['isLive'], isFalse);
      expect(track['trackDuration'], equals(8072340));

      final parsed = MoQCatalog.fromJson(catalog.toJson());
      expect(parsed.tracks.first.trackDuration, equals(8072340));
    });
  });
}
