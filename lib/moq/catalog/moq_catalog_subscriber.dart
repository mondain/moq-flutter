import 'dart:async';
import 'dart:typed_data';

import 'package:logger/logger.dart';

import '../client/moq_client.dart';
import '../protocol/moq_messages.dart';
import 'moq_catalog.dart';
import 'moq_timeline.dart';

class TimelineUpdate {
  final CatalogTrack track;
  final String parentTrackName;
  final List<MediaTimelineEntry>? mediaEntries;
  final List<EventTimelineEntry>? eventEntries;

  const TimelineUpdate({
    required this.track,
    required this.parentTrackName,
    this.mediaEntries,
    this.eventEntries,
  });
}

class CatalogPlaybackSession {
  final MoQCatalog catalog;
  final MoQSubscription catalogSubscription;
  final List<CatalogTrack> mediaTracks;
  final List<CatalogTrack> timelineTracks;
  final List<MoQSubscription> mediaSubscriptions;
  final List<MoQSubscription> timelineSubscriptions;
  final Stream<TimelineUpdate> timelineUpdates;
  final Future<void> Function() _dispose;

  CatalogPlaybackSession({
    required this.catalog,
    required this.catalogSubscription,
    required this.mediaTracks,
    required this.timelineTracks,
    required this.mediaSubscriptions,
    required this.timelineSubscriptions,
    required this.timelineUpdates,
    required Future<void> Function() dispose,
  }) : _dispose = dispose;

  Future<void> close() => _dispose();
}

class MoQCatalogSubscriber {
  final MoQClient _client;
  final Logger _logger;

  final _catalogController = StreamController<MoQCatalog>.broadcast();
  final _timelineController = StreamController<TimelineUpdate>.broadcast();
  final _timelineObjectSubscriptions =
      <String, StreamSubscription<MoQObject>>{};

  MoQSubscription? _catalogSubscription;
  StreamSubscription<MoQObject>? _catalogObjectSubscription;
  Completer<MoQCatalog>? _pendingCatalog;
  MoQCatalog? _latestCatalog;

  MoQCatalogSubscriber({required MoQClient client, Logger? logger})
    : _client = client,
      _logger = logger ?? Logger();

  Stream<MoQCatalog> get catalogs => _catalogController.stream;

  Stream<TimelineUpdate> get timelineUpdates => _timelineController.stream;

  MoQCatalog? get latestCatalog => _latestCatalog;

  Future<MoQCatalog> subscribeCatalog(
    List<Uint8List> trackNamespace, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (_latestCatalog != null && _catalogSubscription != null) {
      return _latestCatalog!;
    }

    _pendingCatalog = Completer<MoQCatalog>();
    try {
      _catalogSubscription = await _subscribeTrack(
        trackNamespace,
        Uint8List.fromList(MoQCatalog.catalogTrackName.codeUnits),
      );
    } on Object {
      _catalogSubscription = await _subscribeTrack(
        trackNamespace,
        Uint8List.fromList(MoQCatalog.legacyCatalogTrackName.codeUnits),
      );
    }
    _catalogObjectSubscription = _catalogSubscription!.objectStream.listen(
      _handleCatalogObject,
      onError: (Object error, StackTrace stackTrace) {
        _logger.e('Catalog stream error: $error');
      },
    );

    try {
      return await _pendingCatalog!.future.timeout(timeout);
    } on TimeoutException {
      if (_catalogSubscription != null) {
        await _client.unsubscribe(_catalogSubscription!.id);
      }
      _catalogSubscription = null;
      _catalogObjectSubscription = null;
      rethrow;
    }
  }

  Future<CatalogPlaybackSession> subscribePlaybackTracks(
    List<Uint8List> trackNamespace, {
    String? videoTrackName,
    String? audioTrackName,
    bool includeTimelines = true,
    FilterType filterType = FilterType.largestObject,
    GroupOrder groupOrder = GroupOrder.descending,
  }) async {
    final catalog = await subscribeCatalog(trackNamespace);
    final mediaTracks = _selectMediaTracks(
      catalog,
      videoTrackName: videoTrackName,
      audioTrackName: audioTrackName,
    );
    final timelineTracks = includeTimelines
        ? _selectTimelineTracks(catalog, mediaTracks)
        : <CatalogTrack>[];

    final mediaSubscriptions = <MoQSubscription>[];
    for (final track in mediaTracks) {
      mediaSubscriptions.add(
        await _subscribeTrack(
          trackNamespace,
          Uint8List.fromList(track.name.codeUnits),
          filterType: filterType,
          groupOrder: groupOrder,
        ),
      );
    }

    final timelineSubscriptions = <MoQSubscription>[];
    for (final track in timelineTracks) {
      final subscription = await _subscribeTrack(
        trackNamespace,
        Uint8List.fromList(track.name.codeUnits),
        filterType: FilterType.largestObject,
        groupOrder: GroupOrder.descending,
      );
      timelineSubscriptions.add(subscription);
      _listenToTimelineTrack(track, subscription);
    }

    return CatalogPlaybackSession(
      catalog: catalog,
      catalogSubscription: _catalogSubscription!,
      mediaTracks: mediaTracks,
      timelineTracks: timelineTracks,
      mediaSubscriptions: mediaSubscriptions,
      timelineSubscriptions: timelineSubscriptions,
      timelineUpdates: timelineUpdates,
      dispose: () async {
        for (final subscription in timelineSubscriptions) {
          await _client.unsubscribe(subscription.id);
        }
        for (final subscription in mediaSubscriptions) {
          await _client.unsubscribe(subscription.id);
        }
      },
    );
  }

  Future<void> dispose({bool unsubscribeCatalog = true}) async {
    await _catalogObjectSubscription?.cancel();
    _catalogObjectSubscription = null;

    for (final subscription in _timelineObjectSubscriptions.values) {
      await subscription.cancel();
    }
    _timelineObjectSubscriptions.clear();

    if (unsubscribeCatalog && _catalogSubscription != null) {
      await _client.unsubscribe(_catalogSubscription!.id);
    }
    _catalogSubscription = null;
    _latestCatalog = null;

    await _catalogController.close();
    await _timelineController.close();
  }

  void _handleCatalogObject(MoQObject object) {
    if (object.status != ObjectStatus.normal || object.payload == null) {
      return;
    }

    try {
      final catalog = MoQCatalog.fromBytes(object.payload!);
      _latestCatalog = catalog;
      _catalogController.add(catalog);
      if (_pendingCatalog != null && !_pendingCatalog!.isCompleted) {
        _pendingCatalog!.complete(catalog);
      }
    } catch (error) {
      _logger.w('Ignoring invalid catalog object: $error');
    }
  }

  List<CatalogTrack> _selectMediaTracks(
    MoQCatalog catalog, {
    String? videoTrackName,
    String? audioTrackName,
  }) {
    final candidates = catalog.tracks.where(_isMediaTrack).toList();
    final mediaTracks = <CatalogTrack>[];

    if (videoTrackName != null) {
      mediaTracks.add(
        candidates.firstWhere((track) => track.name == videoTrackName),
      );
    } else {
      final videoTrack = _firstTrackByRole(candidates, 'video');
      if (videoTrack != null) {
        mediaTracks.add(videoTrack);
      }
    }

    if (audioTrackName != null) {
      mediaTracks.add(
        candidates.firstWhere((track) => track.name == audioTrackName),
      );
    } else {
      final audioTrack = _firstTrackByRole(candidates, 'audio');
      if (audioTrack != null) {
        mediaTracks.add(audioTrack);
      }
    }

    if (mediaTracks.isEmpty) {
      throw StateError('Catalog does not contain playable media tracks');
    }

    return mediaTracks;
  }

  List<CatalogTrack> _selectTimelineTracks(
    MoQCatalog catalog,
    List<CatalogTrack> mediaTracks,
  ) {
    final mediaNames = mediaTracks.map((track) => track.name).toSet();
    return catalog.tracks.where((track) {
      if (!_isTimelineTrack(track)) {
        return false;
      }
      if (track.parentName != null && mediaNames.contains(track.parentName)) {
        return true;
      }
      return track.depends?.any(mediaNames.contains) ?? false;
    }).toList();
  }

  CatalogTrack? _firstTrackByRole(List<CatalogTrack> tracks, String role) {
    for (final track in tracks) {
      if (track.role == role) {
        return track;
      }
    }
    return null;
  }

  bool _isMediaTrack(CatalogTrack track) {
    return track.packaging == 'loc' || track.packaging == 'cmaf';
  }

  bool _isTimelineTrack(CatalogTrack track) {
    return track.packaging == 'mediatimeline' ||
        track.packaging == 'eventtimeline';
  }

  Future<MoQSubscription> _subscribeTrack(
    List<Uint8List> trackNamespace,
    Uint8List trackName, {
    FilterType filterType = FilterType.largestObject,
    GroupOrder groupOrder = GroupOrder.descending,
  }) async {
    final previousIds = _client.subscriptions.keys.toSet();
    await _client.subscribe(
      trackNamespace,
      trackName,
      filterType: filterType,
      groupOrder: groupOrder,
    );
    final newIds = _client.subscriptions.keys.toSet().difference(previousIds);
    if (newIds.length != 1) {
      throw StateError('Could not resolve new subscription for track');
    }
    return _client.subscriptions[newIds.single]!;
  }

  void _listenToTimelineTrack(
    CatalogTrack track,
    MoQSubscription subscription,
  ) {
    _timelineObjectSubscriptions[track.name]?.cancel();
    _timelineObjectSubscriptions[track.name] = subscription.objectStream.listen(
      (object) {
        if (object.status != ObjectStatus.normal || object.payload == null) {
          return;
        }
        try {
          if (track.packaging == 'mediatimeline') {
            _timelineController.add(
              TimelineUpdate(
                track: track,
                parentTrackName: track.parentName ?? track.name,
                mediaEntries: decodeMediaTimeline(object.payload!),
              ),
            );
          } else if (track.packaging == 'eventtimeline') {
            _timelineController.add(
              TimelineUpdate(
                track: track,
                parentTrackName: track.parentName ?? track.name,
                eventEntries: decodeEventTimeline(object.payload!),
              ),
            );
          }
        } catch (error) {
          _logger.w(
            'Ignoring invalid timeline object on ${track.name}: $error',
          );
        }
      },
    );
  }
}
