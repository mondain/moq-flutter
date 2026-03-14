import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moq_flutter/moq/media/fmp4/aac_fmp4_muxer.dart';
import 'package:moq_flutter/moq/media/fmp4/h264_fmp4_muxer.dart';
import 'package:moq_flutter/moq/media/streaming_playback.dart';

void main() {
  group('StreamingPlaybackPipeline.buildCombinedCmafInitSegment', () {
    test('builds a combined init segment for video and audio tracks', () {
      final videoMuxer = H264Fmp4Muxer(width: 1280, height: 720, trackId: 1);
      videoMuxer.setSps(
        Uint8List.fromList([0x67, 0x42, 0x00, 0x1f, 0xe5, 0x88, 0x80]),
      );
      videoMuxer.setPps(Uint8List.fromList([0x68, 0xce, 0x06, 0xe2]));

      final audioMuxer = AacFmp4Muxer(
        sampleRate: 48000,
        channels: 2,
        trackId: 2,
      );

      final initSegment =
          StreamingPlaybackPipeline.buildCombinedCmafInitSegment([
            CmafTrackInit(
              trackName: 'video0',
              initSegment: videoMuxer.initSegment!,
              isVideo: true,
            ),
            CmafTrackInit(
              trackName: 'audio0',
              initSegment: audioMuxer.initSegment,
              isAudio: true,
            ),
          ]);

      expect(_topLevelBoxes(initSegment), equals(['ftyp', 'moov']));
      final moov = _findBox(initSegment, 'moov');
      expect(moov, isNotNull);
      final children = _childBoxes(initSegment, moov!.$1, moov.$2);
      expect(children.where((type) => type == 'trak').length, equals(2));
      expect(children.last, equals('mvex'));
    });

    test('builds a valid init segment for a single video track', () {
      final videoMuxer = H264Fmp4Muxer(width: 640, height: 360, trackId: 1);
      videoMuxer.setSps(
        Uint8List.fromList([0x67, 0x42, 0x00, 0x1f, 0xe5, 0x88, 0x80]),
      );
      videoMuxer.setPps(Uint8List.fromList([0x68, 0xce, 0x06, 0xe2]));

      final initSegment =
          StreamingPlaybackPipeline.buildCombinedCmafInitSegment([
            CmafTrackInit(
              trackName: 'video0',
              initSegment: videoMuxer.initSegment!,
              isVideo: true,
            ),
          ]);

      final moov = _findBox(initSegment, 'moov');
      expect(moov, isNotNull);
      final children = _childBoxes(initSegment, moov!.$1, moov.$2);
      expect(children.where((type) => type == 'trak').length, equals(1));
      expect(children.last, equals('mvex'));
    });
  });
}

List<String> _topLevelBoxes(Uint8List data) {
  final result = <String>[];
  var offset = 0;
  while (offset + 8 <= data.length) {
    final size = _readUint32(data, offset);
    if (size < 8 || offset + size > data.length) {
      break;
    }
    result.add(String.fromCharCodes(data.sublist(offset + 4, offset + 8)));
    offset += size;
  }
  return result;
}

(int, int)? _findBox(Uint8List data, String type) {
  var offset = 0;
  while (offset + 8 <= data.length) {
    final size = _readUint32(data, offset);
    if (size < 8 || offset + size > data.length) {
      break;
    }
    final boxType = String.fromCharCodes(data.sublist(offset + 4, offset + 8));
    if (boxType == type) {
      return (offset, size);
    }
    offset += size;
  }
  return null;
}

List<String> _childBoxes(Uint8List data, int parentOffset, int parentSize) {
  final result = <String>[];
  var offset = parentOffset + 8;
  final limit = parentOffset + parentSize;
  while (offset + 8 <= limit) {
    final size = _readUint32(data, offset);
    if (size < 8 || offset + size > limit) {
      break;
    }
    result.add(String.fromCharCodes(data.sublist(offset + 4, offset + 8)));
    offset += size;
  }
  return result;
}

int _readUint32(Uint8List data, int offset) {
  return (data[offset] << 24) |
      (data[offset + 1] << 16) |
      (data[offset + 2] << 8) |
      data[offset + 3];
}
