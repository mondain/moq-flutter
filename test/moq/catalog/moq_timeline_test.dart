import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moq_flutter/moq/catalog/moq_timeline.dart';
import 'package:moq_flutter/moq/protocol/moq_messages.dart';

void main() {
  group('MoQ timelines', () {
    test('media timeline round-trips', () {
      final payload = encodeMediaTimeline([
        MediaTimelineEntry(
          mediaTime: 1000,
          location: Location(group: Int64(3), object: Int64(7)),
          wallclock: 1234567890,
        ),
      ]);

      final decoded = decodeMediaTimeline(payload);
      expect(decoded.single.mediaTime, equals(1000));
      expect(decoded.single.location.group, equals(Int64(3)));
      expect(decoded.single.location.object, equals(Int64(7)));
      expect(decoded.single.wallclock, equals(1234567890));
    });

    test('event timeline round-trips', () {
      final payload = encodeEventTimeline([
        EventTimelineEntry(
          indexRef: 'sap',
          location: Location(group: Int64(2), object: Int64(9)),
          data: {'type': 1, 'wallclock': 987654321},
        ),
      ]);

      final decoded = decodeEventTimeline(payload);
      final data = decoded.single.data as Map<String, dynamic>;
      expect(decoded.single.indexRef, equals('sap'));
      expect(decoded.single.location.group, equals(Int64(2)));
      expect(decoded.single.location.object, equals(Int64(9)));
      expect(data['type'], equals(1));
      expect(data['wallclock'], equals(987654321));
    });
  });
}
