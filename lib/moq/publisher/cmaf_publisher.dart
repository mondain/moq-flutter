import 'dart:async';
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
///
/// ## Usage Flow:
/// 1. Create publisher
/// 2. Configure tracks with capture info (before announce)
/// 3. Call announce() - publishes catalog after PUBLISH_NAMESPACE_OK
/// 4. Start capturing and publishing frames
/// 5. Handle incoming SUBSCRIBE requests automatically
class CmafPublisher {
  final MoQClient _client;
  final Logger _logger;

  // Publisher state
  bool _isAnnounced = false;
  bool _catalogPublished = false;
  List<Uint8List>? _namespace;
  String? _namespaceStr;

  // Catalog
  MoQCatalog? _catalog;
  final Int64 _catalogGroupId = Int64(0);
  final Int64 _catalogObjectId = Int64(0);

  // Init track for combined init data
  String? _initTrackName;
  bool _initPublished = false;

  // Track management - configured before announce
  final _tracks = <String, CmafTrack>{};
  final _catalogTracks = <CatalogTrack>[];
  final _trackConfigs = <String, TrackConfig>{};

  // Group/object counters
  Int64 _currentGroupId = Int64(0);
  Int64 _currentObjectId = Int64(0);

  // Active streams (streamId -> track)
  final _activeStreams = <int, CmafTrack>{};

  // Subscribe handling
  StreamSubscription<MoQSubscribeRequest>? _subscribeSubscription;
  final _pendingSubscribes = <Int64, MoQSubscribeRequest>{};

  CmafPublisher({
    required MoQClient client,
    Logger? logger,
  })  : _client = client,
        _logger = logger ?? Logger();

  /// Get whether namespace is announced
  bool get isAnnounced => _isAnnounced;

  /// Get whether catalog has been published
  bool get catalogPublished => _catalogPublished;

  /// Get the catalog
  MoQCatalog? get catalog => _catalog;

  /// Get the client
  MoQClient get client => _client;

  /// Get configured tracks
  Map<String, TrackConfig> get trackConfigs => Map.unmodifiable(_trackConfigs);

  /// Configure a video track (can be called before announce)
  ///
  /// This registers the track configuration for the catalog.
  /// The actual muxer is created when the track is used.
  void configureVideoTrack(
    String trackName, {
    required int width,
    required int height,
    int frameRate = 30,
    int timescale = 90000,
    int priority = 128,
    int trackId = 1,
    String? codec,
  }) {
    _trackConfigs[trackName] = VideoTrackConfig(
      name: trackName,
      width: width,
      height: height,
      frameRate: frameRate,
      timescale: timescale,
      priority: priority,
      trackId: trackId,
      codec: codec,
    );
    _logger.i('Configured video track: $trackName (${width}x$height @$frameRate fps)');
  }

  /// Configure an audio track (can be called before announce)
  ///
  /// This registers the track configuration for the catalog.
  void configureAudioTrack(
    String trackName, {
    int sampleRate = 48000,
    int channels = 2,
    int bitrate = 128000,
    int frameDurationMs = 20,
    int priority = 200,
    int trackId = 2,
    String? codec,
  }) {
    _trackConfigs[trackName] = AudioTrackConfig(
      name: trackName,
      sampleRate: sampleRate,
      channels: channels,
      bitrate: bitrate,
      frameDurationMs: frameDurationMs,
      priority: priority,
      trackId: trackId,
      codec: codec,
    );
    _logger.i('Configured audio track: $trackName (${sampleRate}Hz, ${channels}ch)');
  }

  /// Announce a namespace for publishing
  ///
  /// This sends PUBLISH_NAMESPACE, waits for PUBLISH_NAMESPACE_OK,
  /// then publishes the catalog with configured track information.
  ///
  /// Tracks should be configured before calling this method.
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

    if (_trackConfigs.isEmpty) {
      _logger.w('No tracks configured - catalog will be empty');
    }

    _namespaceStr = namespaceParts.join('/');
    _namespace =
        namespaceParts.map((p) => Uint8List.fromList(p.codeUnits)).toList();
    _initTrackName = initTrackName;

    try {
      // Send PUBLISH_NAMESPACE and wait for PUBLISH_NAMESPACE_OK
      await _client.announceNamespace(_namespace!);
      _isAnnounced = true;
      _logger.i('Namespace announced: $_namespaceStr');

      // Build catalog tracks from configurations
      _buildCatalogTracks();

      // Create the catalog with CMAF packaging
      _catalog = MoQCatalog.cmaf(
        namespace: _namespaceStr!,
        tracks: _catalogTracks,
      );

      // Publish catalog immediately after PUBLISH_NAMESPACE_OK
      await _publishCatalog();

      // Start handling incoming SUBSCRIBE requests
      _startSubscribeHandler();

      _logger.i('Publisher ready - catalog published, awaiting subscriptions');
    } catch (e) {
      _logger.e('Failed to announce namespace: $e');
      rethrow;
    }
  }

  /// Build catalog tracks from configurations
  void _buildCatalogTracks() {
    _catalogTracks.clear();

    for (final config in _trackConfigs.values) {
      if (config is VideoTrackConfig) {
        _catalogTracks.add(CatalogTrack(
          name: config.name,
          initTrack: _initTrackName,
          selectionParams: SelectionParams(
            codec: config.codec ?? 'avc1.64001f', // Default H.264 High Profile
            mimeType: 'video/mp4',
            width: config.width,
            height: config.height,
            framerate: config.frameRate,
          ),
        ));
      } else if (config is AudioTrackConfig) {
        _catalogTracks.add(CatalogTrack(
          name: config.name,
          initTrack: _initTrackName,
          selectionParams: SelectionParams(
            codec: config.codec ?? 'opus', // Default Opus
            mimeType: 'audio/mp4',
            samplerate: config.sampleRate,
            channelConfig: config.channels.toString(),
            bitrate: config.bitrate,
          ),
        ));
      }
    }
  }

  /// Start handling incoming SUBSCRIBE requests
  void _startSubscribeHandler() {
    _subscribeSubscription?.cancel();
    _subscribeSubscription = _client.incomingSubscribeRequests.listen(
      _handleSubscribeRequest,
      onError: (e) => _logger.e('Subscribe handler error: $e'),
    );
    _logger.i('Subscribe handler started');
  }

  /// Handle an incoming SUBSCRIBE request
  Future<void> _handleSubscribeRequest(MoQSubscribeRequest request) async {
    final trackName = String.fromCharCodes(request.trackName);
    _logger.i('Received SUBSCRIBE for track: $trackName');

    // Check if we have this track configured
    final config = _trackConfigs[trackName];
    if (config == null) {
      // Check for catalog or init track
      if (trackName == '.catalog' || trackName == _initTrackName) {
        // Accept catalog/init subscriptions
        await _acceptSubscription(request, trackName);
        return;
      }

      _logger.w('SUBSCRIBE for unknown track: $trackName');
      await _client.rejectSubscribe(
        request.requestId,
        errorCode: 0x4, // UNINTERESTED
        reason: 'Track not found: $trackName',
      );
      return;
    }

    // Accept the subscription
    await _acceptSubscription(request, trackName);
  }

  /// Accept a subscription request
  Future<void> _acceptSubscription(MoQSubscribeRequest request, String trackName) async {
    // Get or assign track alias
    Int64 trackAlias;
    final existingTrack = _tracks[trackName];
    if (existingTrack != null) {
      trackAlias = existingTrack.alias;
    } else {
      trackAlias = Int64(_tracks.length);
    }

    try {
      await _client.acceptSubscribe(
        request.requestId,
        trackAlias: trackAlias,
        expires: Int64(0), // No expiry
        groupOrder: GroupOrder.ascending,
        contentExists: _initPublished,
        largestLocation: _initPublished ? Location(
          group: _currentGroupId,
          object: _currentObjectId,
        ) : null,
      );

      _pendingSubscribes[request.requestId] = request;
      _logger.i('Accepted SUBSCRIBE for $trackName (alias: $trackAlias)');
    } catch (e) {
      _logger.e('Failed to accept SUBSCRIBE: $e');
    }
  }

  /// Add an H.264 video track (creates the muxer)
  ///
  /// Call configureVideoTrack() first, then this after announce.
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

  /// Add an Opus audio track (creates the muxer)
  ///
  /// Call configureAudioTrack() first, then this after announce.
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

    // Update catalog with actual codec string
    final codecString = track.muxer.codecString;
    if (codecString != null) {
      _updateCatalogCodec(trackName, codecString);
    }

    _logger.i('Video codec configured: $codecString');

    // Publish init segment when ready
    await _maybePublishInitSegment();
  }

  /// Mark audio track as ready (Opus doesn't need external config)
  Future<void> setAudioReady(String trackName) async {
    final track = _tracks[trackName];
    if (track is! CmafAudioTrack) {
      throw ArgumentError('Track $trackName is not an audio track');
    }

    // Update catalog with actual codec string
    _updateCatalogCodec(trackName, track.muxer.codecString);

    _logger.i('Audio track ready: ${track.muxer.codecString}');

    // Publish init segment when ready
    await _maybePublishInitSegment();
  }

  /// Update catalog codec string for a track
  void _updateCatalogCodec(String trackName, String codec) {
    for (int i = 0; i < _catalogTracks.length; i++) {
      if (_catalogTracks[i].name == trackName) {
        final oldTrack = _catalogTracks[i];
        _catalogTracks[i] = CatalogTrack(
          name: oldTrack.name,
          initTrack: oldTrack.initTrack,
          selectionParams: SelectionParams(
            codec: codec,
            mimeType: oldTrack.selectionParams?.mimeType,
            width: oldTrack.selectionParams?.width,
            height: oldTrack.selectionParams?.height,
            framerate: oldTrack.selectionParams?.framerate,
            samplerate: oldTrack.selectionParams?.samplerate,
            channelConfig: oldTrack.selectionParams?.channelConfig,
            bitrate: oldTrack.selectionParams?.bitrate,
          ),
        );
        break;
      }
    }
  }

  /// Check if all tracks are configured and publish init segment
  Future<void> _maybePublishInitSegment() async {
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
    _initPublished = true;

    // Re-publish catalog with updated codec info
    await _publishCatalog();
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
    _logger.d('_publishCatalog called, isAnnounced=$_isAnnounced');
    if (!_isAnnounced) return;

    // Rebuild catalog
    _catalog = MoQCatalog.cmaf(
      namespace: _namespaceStr!,
      tracks: _catalogTracks,
    );
    _logger.d('Catalog built with ${_catalogTracks.length} tracks');

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
    _logger.d('About to open data stream for catalog');

    // Open stream and publish catalog
    final streamId = await _client.openDataStream();
    _logger.d('Opened data stream: $streamId');

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

    _catalogPublished = true;
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
        // Update catalog with actual codec
        final codecString = track.muxer.codecString;
        if (codecString != null) {
          _updateCatalogCodec(trackName, codecString);
        }
        await _maybePublishInitSegment();
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
    // Stop subscribe handler
    await _subscribeSubscription?.cancel();
    _subscribeSubscription = null;

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
    _catalogPublished = false;
    _tracks.clear();
    _catalogTracks.clear();
    _trackConfigs.clear();
    _pendingSubscribes.clear();
    _logger.i('CMAF Publisher stopped');
  }

  void dispose() {
    stop();
  }
}

/// Track configuration (before muxer is created)
abstract class TrackConfig {
  String get name;
  int get priority;
  int get trackId;
  String? get codec;
}

/// Video track configuration
class VideoTrackConfig implements TrackConfig {
  @override
  final String name;
  final int width;
  final int height;
  final int frameRate;
  final int timescale;
  @override
  final int priority;
  @override
  final int trackId;
  @override
  final String? codec;

  VideoTrackConfig({
    required this.name,
    required this.width,
    required this.height,
    this.frameRate = 30,
    this.timescale = 90000,
    this.priority = 128,
    this.trackId = 1,
    this.codec,
  });
}

/// Audio track configuration
class AudioTrackConfig implements TrackConfig {
  @override
  final String name;
  final int sampleRate;
  final int channels;
  final int bitrate;
  final int frameDurationMs;
  @override
  final int priority;
  @override
  final int trackId;
  @override
  final String? codec;

  AudioTrackConfig({
    required this.name,
    this.sampleRate = 48000,
    this.channels = 2,
    this.bitrate = 128000,
    this.frameDurationMs = 20,
    this.priority = 200,
    this.trackId = 2,
    this.codec,
  });
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
