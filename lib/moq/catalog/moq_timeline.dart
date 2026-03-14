import 'dart:convert';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';

import '../protocol/moq_messages.dart';

class MediaTimelineEntry {
  final int mediaTime;
  final Location location;
  final int wallclock;

  const MediaTimelineEntry({
    required this.mediaTime,
    required this.location,
    required this.wallclock,
  });

  List<Object> toJsonValue() => [
    mediaTime,
    [location.group.toInt(), location.object.toInt()],
    wallclock,
  ];

  static MediaTimelineEntry fromJsonValue(List<dynamic> value) {
    final locationArray = value[1] as List<dynamic>;
    return MediaTimelineEntry(
      mediaTime: value[0] as int,
      location: Location(
        group: Int64(locationArray[0] as int),
        object: Int64(locationArray[1] as int),
      ),
      wallclock: value[2] as int,
    );
  }
}

class EventTimelineEntry {
  final String indexRef;
  final Location location;
  final Object data;

  const EventTimelineEntry({
    required this.indexRef,
    required this.location,
    required this.data,
  });

  Map<String, Object> toJsonValue() => {
    'idx': indexRef,
    'l': [location.group.toInt(), location.object.toInt()],
    'data': data,
  };

  static EventTimelineEntry fromJsonValue(Map<String, dynamic> value) {
    final locationArray = value['l'] as List<dynamic>;
    return EventTimelineEntry(
      indexRef: value['idx'] as String,
      location: Location(
        group: Int64(locationArray[0] as int),
        object: Int64(locationArray[1] as int),
      ),
      data: value['data'] as Object,
    );
  }
}

Uint8List encodeMediaTimeline(List<MediaTimelineEntry> entries) {
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode(entries.map((entry) => entry.toJsonValue()).toList()),
    ),
  );
}

List<MediaTimelineEntry> decodeMediaTimeline(Uint8List bytes) {
  final payload = jsonDecode(utf8.decode(bytes)) as List<dynamic>;
  return payload
      .map((entry) => MediaTimelineEntry.fromJsonValue(entry as List<dynamic>))
      .toList();
}

Uint8List encodeEventTimeline(List<EventTimelineEntry> entries) {
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode(entries.map((entry) => entry.toJsonValue()).toList()),
    ),
  );
}

List<EventTimelineEntry> decodeEventTimeline(Uint8List bytes) {
  final payload = jsonDecode(utf8.decode(bytes)) as List<dynamic>;
  return payload
      .map(
        (entry) =>
            EventTimelineEntry.fromJsonValue(entry as Map<String, dynamic>),
      )
      .toList();
}
