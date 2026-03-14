import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:logger/logger.dart';
import '../catalog/moq_catalog.dart';
import '../catalog/moq_timeline.dart';
import '../client/moq_client.dart';
import '../protocol/moq_messages.dart';

/// High-level MoQ Publisher for managing media stream publishing
///
/// This class handles:
/// - Namespace announcement
/// - Catalog track for track discovery
/// - Track management with aliases
/// - Group and subgroup stream management
/// - Object publishing with proper sequencing
class MoQPublisher {
  final MoQClient _client;
  final Logger _logger;

  // Publisher state
  bool _isAnnounced = false;
  List<Uint8List>? _namespace;
  String? _namespaceStr;

  // Catalog management
  MoQCatalog? _catalog;
  Int64 _catalogGroupId = Int64(0);
  Int64 _catalogObjectId = Int64(0);

  // Track management
  final _tracks = <String, PublisherTrack>{};
  final _catalogTracks = <CatalogTrack>[];
  final _timelineTracks = <String, PublisherTrack>{};
  int _nextTrackAlias = 0;

  // Group/object counters
  Int64 _currentGroupId = _randomGroupSeed();

  // Active streams (streamId -> track)
  final _activeStreams = <int, PublisherTrack>{};

  MoQPublisher({required MoQClient client, Logger? logger})
    : _client = client,
      _logger = logger ?? Logger();

  /// Get whether namespace is announced
  bool get isAnnounced => _isAnnounced;

  /// Get the catalog (if created)
  MoQCatalog? get catalog => _catalog;

  /// Get the underlying client
  MoQClient get client => _client;

  /// Announce a namespace for publishing
  ///
  /// Must be called before adding tracks or publishing objects.
  /// This also creates and publishes a catalog track.
  Future<void> announce(List<String> namespaceParts) async {
    if (_isAnnounced) {
      _logger.w('Already announced namespace');
      return;
    }

    _namespaceStr = namespaceParts.join('/');
    _namespace = namespaceParts
        .map((p) => Uint8List.fromList(p.codeUnits))
        .toList();

    try {
      await _client.announceNamespace(_namespace!);
      _isAnnounced = true;
      _logger.i('Namespace announced: $_namespaceStr');

      // Create the catalog
      _catalog = MoQCatalog.loc(
        namespace: _namespaceStr!,
        tracks: [
          ..._catalogTracks,
          ..._timelineTracks.values.map(_timelineCatalogTrack),
        ],
      );

      // Publish initial catalog
      await _publishCatalog();
    } catch (e) {
      _logger.e('Failed to announce namespace: $e');
      rethrow;
    }
  }

  /// Publish the catalog track
  Future<void> _publishCatalog() async {
    if (_catalog == null || !_isAnnounced) return;

    try {
      // Add the catalog track if not already added
      if (!_tracks.containsKey(MoQCatalog.catalogTrackName)) {
        final alias = _allocateTrackAlias();
        final catalogTrack = PublisherTrack(
          name: MoQCatalog.catalogTrackName,
          alias: alias,
          priority: 255, // Highest priority for catalog
        );
        _tracks[MoQCatalog.catalogTrackName] = catalogTrack;
        _logger.d(
          'Added catalog track: ${MoQCatalog.catalogTrackName} (alias: $alias)',
        );
      }

      final catalogTrack = _tracks[MoQCatalog.catalogTrackName]!;

      // Open a stream for catalog
      final streamId = await _client.openDataStream();

      // Write subgroup header for catalog
      await _client.writeSubgroupHeader(
        streamId,
        trackAlias: catalogTrack.alias,
        groupId: _catalogGroupId,
        subgroupId: Int64(0),
        publisherPriority: catalogTrack.priority,
      );

      // Write catalog as a single object
      final catalogBytes = _catalog!.toBytes();
      await _client.writeObject(
        streamId,
        objectId: _catalogObjectId,
        payload: catalogBytes,
        status: ObjectStatus.normal,
      );

      // Finish the catalog stream
      await _client.finishDataStream(streamId);

      _logger.i(
        'Published catalog (${catalogBytes.length} bytes, group: $_catalogGroupId)',
      );
    } catch (e) {
      _logger.e('Failed to publish catalog: $e');
      rethrow;
    }
  }

  /// Update and republish the catalog
  Future<void> updateCatalog() async {
    if (!_isAnnounced) return;

    // Increment group ID for catalog update
    _catalogGroupId += Int64(1);
    _catalogObjectId = Int64(0);

    // Rebuild catalog with current tracks
    _catalog = MoQCatalog.loc(
      namespace: _namespaceStr!,
      tracks: [
        ..._catalogTracks,
        ..._timelineTracks.values.map(_timelineCatalogTrack),
      ],
    );

    await _publishCatalog();
  }

  /// Add a track to publish
  ///
  /// Returns the track alias assigned to this track.
  Int64 addTrack(String trackName, {int priority = 128}) {
    if (!_isAnnounced) {
      throw StateError('Must announce namespace before adding tracks');
    }

    if (_tracks.containsKey(trackName)) {
      return _tracks[trackName]!.alias;
    }

    final alias = _allocateTrackAlias();
    final track = PublisherTrack(
      name: trackName,
      alias: alias,
      priority: priority,
    );

    _tracks[trackName] = track;
    _logger.d('Added track: $trackName (alias: $alias)');

    return alias;
  }

  /// Add a video track with codec/resolution info
  ///
  /// Returns the track alias assigned to this track.
  Future<Int64> addVideoTrack(
    String trackName, {
    int priority = 128,
    String? codec,
    int? width,
    int? height,
    int? framerate,
    int? bitrate,
    bool updateCatalogNow = true,
  }) async {
    final alias = addTrack(trackName, priority: priority);

    // Add to catalog tracks
    _catalogTracks.add(
      CatalogTrack(
        name: trackName,
        namespace: _namespaceStr,
        packaging: 'loc',
        isLive: true,
        targetLatency: 2000,
        timescale: 1000000,
        role: 'video',
        selectionParams: SelectionParams(
          codec: codec,
          width: width,
          height: height,
          framerate: framerate,
          bitrate: bitrate,
        ),
      ),
    );
    _ensureTimelineTrack(trackName);

    // Optionally update catalog immediately
    if (updateCatalogNow) {
      await updateCatalog();
    }

    return alias;
  }

  /// Add an audio track with codec/sample rate info
  ///
  /// Returns the track alias assigned to this track.
  Future<Int64> addAudioTrack(
    String trackName, {
    int priority = 128,
    String? codec,
    int? samplerate,
    String? channelConfig,
    int? bitrate,
    bool updateCatalogNow = true,
  }) async {
    final alias = addTrack(trackName, priority: priority);

    // Add to catalog tracks
    _catalogTracks.add(
      CatalogTrack(
        name: trackName,
        namespace: _namespaceStr,
        packaging: 'loc',
        isLive: true,
        targetLatency: 2000,
        timescale: 1000000,
        role: 'audio',
        selectionParams: SelectionParams(
          codec: codec,
          samplerate: samplerate,
          channelConfig: channelConfig,
          bitrate: bitrate,
        ),
      ),
    );
    _ensureTimelineTrack(trackName);

    // Optionally update catalog immediately
    if (updateCatalogNow) {
      await updateCatalog();
    }

    return alias;
  }

  /// Start a new group for a track
  ///
  /// Returns the group ID.
  Int64 startGroup(String trackName) {
    final track = _tracks[trackName];
    if (track == null) {
      throw ArgumentError('Track not found: $trackName');
    }

    final groupId = _currentGroupId;
    _currentGroupId += Int64(1);
    track.currentGroupId = groupId;
    track.currentObjectId = Int64(0);
    _logger.d('Started group $groupId for track $trackName');

    return groupId;
  }

  /// Open a subgroup stream for publishing
  ///
  /// Returns the stream ID.
  Future<int> openSubgroup(String trackName, {Int64? subgroupId}) async {
    final track = _tracks[trackName];
    if (track == null) {
      throw ArgumentError('Track not found: $trackName');
    }

    final streamId = await _client.openDataStream();
    final subgroup = subgroupId ?? Int64(0);

    // Write subgroup header
    await _client.writeSubgroupHeader(
      streamId,
      trackAlias: track.alias,
      groupId: track.currentGroupId,
      subgroupId: subgroup,
      publisherPriority: track.priority,
    );

    _activeStreams[streamId] = track;
    _logger.d(
      'Opened subgroup stream $streamId for track $trackName (group: ${track.currentGroupId}, subgroup: $subgroup)',
    );

    return streamId;
  }

  /// Publish an object to a subgroup stream
  ///
  /// Returns the object ID assigned.
  Future<Int64> publishObject(
    int streamId,
    Uint8List payload, {
    ObjectStatus status = ObjectStatus.normal,
  }) async {
    final track = _activeStreams[streamId];
    if (track == null) {
      throw ArgumentError('Stream not found: $streamId');
    }

    final objectId = track.currentObjectId;
    track.currentObjectId += Int64(1);

    await _client.writeObject(
      streamId,
      objectId: objectId,
      payload: payload,
      status: status,
    );

    _logger.d(
      'Published object $objectId (${payload.length} bytes) to stream $streamId',
    );

    return objectId;
  }

  /// Publish media frame (convenience method)
  ///
  /// Handles group/subgroup management automatically.
  /// Set `newGroup` to true to start a new group (e.g., for keyframes).
  Future<Int64> publishFrame(
    String trackName,
    Uint8List frameData, {
    bool newGroup = false,
    bool isEndOfGroup = false,
  }) async {
    final track = _tracks[trackName];
    if (track == null) {
      throw ArgumentError('Track not found: $trackName');
    }

    // MSF-style publishing uses one stream per object while the publisher
    // maintains group/object numbering independently.
    if (newGroup || track.currentGroupId == Int64.ZERO) {
      startGroup(trackName);
    }

    final streamId = await openSubgroup(trackName);
    final status = isEndOfGroup ? ObjectStatus.endOfGroup : ObjectStatus.normal;
    final objectId = await publishObject(streamId, frameData, status: status);
    final now = DateTime.now().millisecondsSinceEpoch;
    await _publishMediaTimelineEntry(
      trackName,
      MediaTimelineEntry(
        mediaTime: now,
        location: Location(group: track.currentGroupId, object: objectId),
        wallclock: now,
      ),
    );
    await closeSubgroup(streamId);

    return objectId;
  }

  /// Close a subgroup stream
  Future<void> closeSubgroup(int streamId, {bool isEndOfGroup = false}) async {
    final track = _activeStreams.remove(streamId);
    if (track == null) {
      _logger.w('Stream $streamId not found in active streams');
      return;
    }

    await _client.finishDataStream(streamId);
    _logger.d('Closed subgroup stream $streamId');
  }

  /// Stop publishing and cancel namespace
  Future<void> stop({String reason = 'Publisher stopped'}) async {
    // Close all active streams
    for (final streamId in _activeStreams.keys.toList()) {
      try {
        await closeSubgroup(streamId);
      } catch (e) {
        _logger.w('Error closing stream $streamId: $e');
      }
    }

    // Cancel namespace
    if (_isAnnounced && _namespace != null) {
      try {
        await _client.cancelNamespace(_namespace!, reason: reason);
      } catch (e) {
        _logger.w('Error canceling namespace: $e');
      }
    }

    _isAnnounced = false;
    _tracks.clear();
    _timelineTracks.clear();
    _activeStreams.clear();
    _nextTrackAlias = 0;
    _logger.i('Publisher stopped');
  }

  void dispose() {
    stop();
  }

  void _ensureTimelineTrack(String trackName) {
    final timelineName = _timelineTrackName(trackName);
    if (_timelineTracks.containsKey(timelineName)) {
      return;
    }
    _timelineTracks[timelineName] = PublisherTrack(
      name: timelineName,
      alias: _allocateTrackAlias(),
      priority: 254,
    );
  }

  CatalogTrack _timelineCatalogTrack(PublisherTrack track) {
    final parentName = track.name.substring(
      0,
      track.name.length - '.timeline'.length,
    );
    return CatalogTrack(
      name: track.name,
      namespace: _namespaceStr,
      packaging: 'mediatimeline',
      role: 'timeline',
      parentName: parentName,
      depends: [parentName],
      isLive: true,
      targetLatency: 2000,
      selectionParams: SelectionParams(mimeType: 'application/json'),
    );
  }

  Future<void> _publishMediaTimelineEntry(
    String trackName,
    MediaTimelineEntry entry,
  ) async {
    final timelineTrack = _timelineTracks[_timelineTrackName(trackName)];
    if (timelineTrack == null) {
      return;
    }
    timelineTrack.currentGroupId += Int64(1);
    timelineTrack.currentObjectId = Int64.ZERO;

    final streamId = await _client.openDataStream();
    await _client.writeSubgroupHeader(
      streamId,
      trackAlias: timelineTrack.alias,
      groupId: timelineTrack.currentGroupId,
      subgroupId: Int64.ZERO,
      publisherPriority: timelineTrack.priority,
    );
    await _client.writeObject(
      streamId,
      objectId: timelineTrack.currentObjectId,
      payload: encodeMediaTimeline([entry]),
      status: ObjectStatus.normal,
    );
    timelineTrack.currentObjectId += Int64(1);
    await _client.finishDataStream(streamId);
  }

  String _timelineTrackName(String trackName) => '$trackName.timeline';

  Int64 _allocateTrackAlias() => Int64(_nextTrackAlias++);
}

/// Publisher track information
class PublisherTrack {
  final String name;
  final Int64 alias;
  final int priority;

  Int64 currentGroupId = Int64(0);
  Int64 currentObjectId = Int64(0);
  int? currentStreamId;

  PublisherTrack({
    required this.name,
    required this.alias,
    required this.priority,
  });
}

Int64 _randomGroupSeed() {
  final random = Random.secure();
  return Int64(random.nextInt(1 << 30));
}
