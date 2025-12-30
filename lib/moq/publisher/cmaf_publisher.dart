import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:logger/logger.dart';

import '../catalog/moq_catalog.dart';
import '../client/moq_client.dart';
import '../media/fmp4/h264_fmp4_muxer.dart';
import '../media/fmp4/opus_fmp4_muxer.dart';
import '../protocol/moq_messages.dart';

/// CMAF-aware MoQ Publisher for fMP4 packaged media
///
/// This publisher wraps media frames in fMP4 (moof+mdat) segments
/// suitable for CARP-compliant MoQ streaming.
class CmafPublisher {
  final MoQClient _client;
  final Logger _logger;

  // Publisher state
  bool _isAnnounced = false;
  List<Uint8List>? _namespace;
  String? _namespaceStr;

  // Catalog
  MoQCatalog? _catalog;
  final Int64 _catalogGroupId = Int64(0);
  final Int64 _catalogObjectId = Int64(0);

  // Init track for combined init data
  String? _initTrackName;
  bool _initPublished = false;

  // Track management
  final _tracks = <String, CmafTrack>{};
  final _catalogTracks = <CatalogTrack>[];

  // Group/object counters
  Int64 _currentGroupId = Int64(0);
  Int64 _currentObjectId = Int64(0);

  // Active streams (streamId -> track)
  final _activeStreams = <int, CmafTrack>{};

  CmafPublisher({
    required MoQClient client,
    Logger? logger,
  })  : _client = client,
        _logger = logger ?? Logger();

  /// Get whether namespace is announced
  bool get isAnnounced => _isAnnounced;

  /// Get the catalog
  MoQCatalog? get catalog => _catalog;

  /// Get the client
  MoQClient get client => _client;

  /// Announce a namespace for publishing
  ///
  /// [initTrackName] is the name for the combined init track (e.g., "0.mp4")
  Future<void> announce(
    List<String> namespaceParts, {
    String initTrackName = '0.mp4',
  }) async {
    if (_isAnnounced) {
      _logger.w('Already announced namespace');
      return;
    }

    _namespaceStr = namespaceParts.join('/');
    _namespace =
        namespaceParts.map((p) => Uint8List.fromList(p.codeUnits)).toList();
    _initTrackName = initTrackName;

    try {
      await _client.announceNamespace(_namespace!);
      _isAnnounced = true;
      _logger.i('Namespace announced: $_namespaceStr');

      // Create the catalog with CMAF packaging
      _catalog = MoQCatalog.cmaf(
        namespace: _namespaceStr!,
        tracks: _catalogTracks,
      );
    } catch (e) {
      _logger.e('Failed to announce namespace: $e');
      rethrow;
    }
  }

  /// Add an H.264 video track
  ///
  /// Returns the track name for publishing.
  Future<CmafVideoTrack> addVideoTrack(
    String trackName, {
    required int width,
    required int height,
    int frameRate = 30,
    int timescale = 90000,
    int priority = 128,
    int trackId = 1,
  }) async {
    if (!_isAnnounced) {
      throw StateError('Must announce namespace before adding tracks');
    }

    final muxer = H264Fmp4Muxer(
      width: width,
      height: height,
      frameRate: frameRate,
      timescale: timescale,
      trackId: trackId,
    );

    final track = CmafVideoTrack(
      name: trackName,
      alias: Int64(_tracks.length),
      priority: priority,
      muxer: muxer,
    );

    _tracks[trackName] = track;
    _logger.i('Added CMAF video track: $trackName (${width}x$height @$frameRate fps)');

    return track;
  }

  /// Add an Opus audio track
  ///
  /// Returns the track name for publishing.
  Future<CmafAudioTrack> addAudioTrack(
    String trackName, {
    int sampleRate = 48000,
    int channels = 2,
    int bitrate = 128000,
    int frameDurationMs = 20,
    int priority = 128,
    int trackId = 2,
  }) async {
    if (!_isAnnounced) {
      throw StateError('Must announce namespace before adding tracks');
    }

    final muxer = OpusFmp4Muxer(
      sampleRate: sampleRate,
      channels: channels,
      bitrate: bitrate,
      frameDurationMs: frameDurationMs,
      trackId: trackId,
    );

    final track = CmafAudioTrack(
      name: trackName,
      alias: Int64(_tracks.length),
      priority: priority,
      muxer: muxer,
    );

    _tracks[trackName] = track;
    _logger.i('Added CMAF audio track: $trackName (${sampleRate}Hz, ${channels}ch)');

    return track;
  }

  /// Set SPS/PPS for video track and publish init segment
  Future<void> setVideoCodecConfig(
    String trackName, {
    required Uint8List sps,
    required Uint8List pps,
  }) async {
    final track = _tracks[trackName];
    if (track is! CmafVideoTrack) {
      throw ArgumentError('Track $trackName is not a video track');
    }

    track.muxer.setSps(sps);
    track.muxer.setPps(pps);

    if (!track.muxer.isInitReady) {
      throw StateError('Init not ready after setting SPS/PPS');
    }

    // Add to catalog
    _catalogTracks.add(CatalogTrack(
      name: trackName,
      initTrack: _initTrackName,
      selectionParams: SelectionParams(
        codec: track.muxer.codecString,
        width: track.muxer.width,
        height: track.muxer.height,
        framerate: track.muxer.frameRate,
      ),
    ));

    _logger.i('Video codec configured: ${track.muxer.codecString}');

    // Publish init and catalog if all tracks ready
    await _maybePublishInitAndCatalog();
  }

  /// Mark audio track as ready (Opus doesn't need external config)
  Future<void> setAudioReady(String trackName) async {
    final track = _tracks[trackName];
    if (track is! CmafAudioTrack) {
      throw ArgumentError('Track $trackName is not an audio track');
    }

    // Add to catalog
    _catalogTracks.add(CatalogTrack(
      name: trackName,
      initTrack: _initTrackName,
      selectionParams: SelectionParams(
        codec: track.muxer.codecString,
        samplerate: track.muxer.sampleRate,
        channelConfig: track.muxer.channels.toString(),
        bitrate: track.muxer.bitrate,
      ),
    ));

    _logger.i('Audio track ready: ${track.muxer.codecString}');

    // Publish init and catalog if all tracks ready
    await _maybePublishInitAndCatalog();
  }

  /// Check if all tracks are configured and publish init/catalog
  Future<void> _maybePublishInitAndCatalog() async {
    if (_initPublished) return;

    // Check if all tracks have init ready
    bool allReady = true;
    for (final track in _tracks.values) {
      if (track is CmafVideoTrack && !track.muxer.isInitReady) {
        allReady = false;
        break;
      }
    }

    if (!allReady) return;

    // Publish combined init segment
    await _publishInitSegment();

    // Publish catalog
    await _publishCatalog();

    _initPublished = true;
  }

  /// Publish the combined init segment
  Future<void> _publishInitSegment() async {
    if (_initTrackName == null) return;

    // Combine all track init segments
    final initParts = <Uint8List>[];

    for (final track in _tracks.values) {
      if (track is CmafVideoTrack) {
        final init = track.muxer.initSegment;
        if (init != null) {
          initParts.add(init);
        }
      } else if (track is CmafAudioTrack) {
        initParts.add(track.muxer.initSegment);
      }
    }

    if (initParts.isEmpty) return;

    // Use first init segment (in real world, we'd need to merge moov boxes)
    // For now, publish the first one
    final initData = initParts.first;

    // Create init track
    final alias = Int64(_tracks.length);
    final initTrack = CmafTrack(
      name: _initTrackName!,
      alias: alias,
      priority: 255,
    );
    _tracks[_initTrackName!] = initTrack;

    // Open stream and publish init
    final streamId = await _client.openDataStream();

    await _client.writeSubgroupHeader(
      streamId,
      trackAlias: alias,
      groupId: Int64(0),
      subgroupId: Int64(0),
      publisherPriority: 255,
    );

    await _client.writeObject(
      streamId,
      objectId: Int64(0),
      payload: initData,
      status: ObjectStatus.normal,
    );

    await _client.finishDataStream(streamId);

    _logger.i('Published init segment (${initData.length} bytes) to $_initTrackName');
  }

  /// Publish the catalog
  Future<void> _publishCatalog() async {
    if (_catalog == null || !_isAnnounced) return;

    // Rebuild catalog
    _catalog = MoQCatalog.cmaf(
      namespace: _namespaceStr!,
      tracks: _catalogTracks,
    );

    // Create catalog track if not exists
    const catalogName = '.catalog';
    if (!_tracks.containsKey(catalogName)) {
      _tracks[catalogName] = CmafTrack(
        name: catalogName,
        alias: Int64(_tracks.length),
        priority: 255,
      );
    }

    final catalogTrack = _tracks[catalogName]!;

    // Open stream and publish catalog
    final streamId = await _client.openDataStream();

    await _client.writeSubgroupHeader(
      streamId,
      trackAlias: catalogTrack.alias,
      groupId: _catalogGroupId,
      subgroupId: Int64(0),
      publisherPriority: 255,
    );

    final catalogBytes = _catalog!.toBytes();
    await _client.writeObject(
      streamId,
      objectId: _catalogObjectId,
      payload: catalogBytes,
      status: ObjectStatus.normal,
    );

    await _client.finishDataStream(streamId);

    _logger.i('Published catalog (${catalogBytes.length} bytes)');
  }

  /// Publish an H.264 video frame
  ///
  /// [frameData] should be in Annex B format (with start codes)
  /// The first frame with SPS/PPS will be used to configure the muxer.
  Future<void> publishVideoFrame(
    String trackName,
    Uint8List frameData, {
    required bool isKeyframe,
    int? durationMs,
  }) async {
    final track = _tracks[trackName];
    if (track is! CmafVideoTrack) {
      throw ArgumentError('Track $trackName is not a video track');
    }

    // If this is the first frame and has SPS/PPS, extract them
    if (!track.muxer.isInitReady) {
      track.muxer.parseSpsPpsFromBitstream(frameData);

      if (track.muxer.isInitReady) {
        // Add to catalog and publish
        _catalogTracks.add(CatalogTrack(
          name: trackName,
          initTrack: _initTrackName,
          selectionParams: SelectionParams(
            codec: track.muxer.codecString,
            width: track.muxer.width,
            height: track.muxer.height,
            framerate: track.muxer.frameRate,
          ),
        ));
        await _maybePublishInitAndCatalog();
      }
    }

    if (!_initPublished) {
      _logger.w('Cannot publish video frame before init is published');
      return;
    }

    // Create fMP4 segment
    final segment = track.muxer.createMediaSegment(
      frameData: frameData,
      isKeyframe: isKeyframe,
      durationMs: durationMs,
    );

    // Publish segment
    await _publishMediaSegment(trackName, segment, newGroup: isKeyframe);
  }

  /// Publish an Opus audio frame
  Future<void> publishAudioFrame(
    String trackName,
    Uint8List opusData,
  ) async {
    final track = _tracks[trackName];
    if (track is! CmafAudioTrack) {
      throw ArgumentError('Track $trackName is not an audio track');
    }

    if (!_initPublished) {
      _logger.w('Cannot publish audio frame before init is published');
      return;
    }

    // Create fMP4 segment
    final segment = track.muxer.createSingleFrameSegment(opusData);

    // Publish segment (audio doesn't need new groups for each frame)
    await _publishMediaSegment(trackName, segment, newGroup: false);
  }

  /// Publish an fMP4 media segment
  Future<void> _publishMediaSegment(
    String trackName,
    Uint8List segment, {
    required bool newGroup,
  }) async {
    final track = _tracks[trackName];
    if (track == null) {
      throw ArgumentError('Track not found: $trackName');
    }

    // Start new group if requested or no current stream
    if (newGroup || track.currentStreamId == null) {
      // Close previous stream if exists
      if (track.currentStreamId != null) {
        await _closeStream(track.currentStreamId!);
        _activeStreams.remove(track.currentStreamId);
      }

      // Start new group
      track.currentGroupId = _currentGroupId;
      _currentGroupId += Int64(1);
      _currentObjectId = Int64(0);

      // Open new stream
      final streamId = await _client.openDataStream();
      track.currentStreamId = streamId;
      _activeStreams[streamId] = track;

      await _client.writeSubgroupHeader(
        streamId,
        trackAlias: track.alias,
        groupId: track.currentGroupId,
        subgroupId: Int64(0),
        publisherPriority: track.priority,
      );

      _logger.d('Started new group ${track.currentGroupId} for $trackName');
    }

    // Publish segment as object
    await _client.writeObject(
      track.currentStreamId!,
      objectId: _currentObjectId,
      payload: segment,
      status: ObjectStatus.normal,
    );

    _currentObjectId += Int64(1);
  }

  /// Close a stream
  Future<void> _closeStream(int streamId) async {
    try {
      await _client.finishDataStream(streamId);
    } catch (e) {
      _logger.w('Error closing stream $streamId: $e');
    }
  }

  /// End all current groups (call on video keyframe to sync audio)
  void syncGroupsOnKeyframe() {
    // This will cause all tracks to start new groups on next frame
    for (final track in _tracks.values) {
      if (track.currentStreamId != null) {
        _closeStream(track.currentStreamId!);
        _activeStreams.remove(track.currentStreamId);
        track.currentStreamId = null;
      }
    }
  }

  /// Stop publishing
  Future<void> stop({String reason = 'Publisher stopped'}) async {
    // Close all active streams
    for (final streamId in _activeStreams.keys.toList()) {
      await _closeStream(streamId);
    }
    _activeStreams.clear();

    // Cancel namespace
    if (_isAnnounced && _namespace != null) {
      try {
        await _client.cancelNamespace(_namespace!, reason: reason);
      } catch (e) {
        _logger.w('Error canceling namespace: $e');
      }
    }

    _isAnnounced = false;
    _initPublished = false;
    _tracks.clear();
    _catalogTracks.clear();
    _logger.i('CMAF Publisher stopped');
  }

  void dispose() {
    stop();
  }
}

/// Base CMAF track information
class CmafTrack {
  final String name;
  final Int64 alias;
  final int priority;

  Int64 currentGroupId = Int64(0);
  int? currentStreamId;

  CmafTrack({
    required this.name,
    required this.alias,
    required this.priority,
  });
}

/// CMAF video track with H.264 muxer
class CmafVideoTrack extends CmafTrack {
  final H264Fmp4Muxer muxer;

  CmafVideoTrack({
    required super.name,
    required super.alias,
    required super.priority,
    required this.muxer,
  });
}

/// CMAF audio track with Opus muxer
class CmafAudioTrack extends CmafTrack {
  final OpusFmp4Muxer muxer;

  CmafAudioTrack({
    required super.name,
    required super.alias,
    required super.priority,
    required this.muxer,
  });
}
