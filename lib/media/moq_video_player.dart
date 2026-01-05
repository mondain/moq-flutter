import 'dart:async';
import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:logger/logger.dart';
import '../moq/protocol/moq_messages.dart';
import '../moq/client/moq_client.dart';
import '../moq/media/streaming_playback.dart';

/// Video player service for MoQ media streams
///
/// Uses StreamingPlaybackPipeline to decode moq-mi format and mux to fMP4
/// for playback with media_kit
class MoQVideoPlayer {
  final Logger _logger;
  final Player _player;
  late final VideoController _controller;

  // Streaming playback pipeline
  StreamingPlaybackPipeline? _playbackPipeline;

  // Stream subscriptions
  final List<StreamSubscription<MoQObject>> _objectSubscriptions = [];
  StreamSubscription<String>? _videoReadySubscription;
  StreamSubscription<String>? _audioReadySubscription;

  // Playback state
  bool _isInitialized = false;
  bool _isPlaying = false;
  bool _mediaOpened = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  // Statistics
  int _objectsReceived = 0;
  int _bytesReceived = 0;

  // Group tracking for mid-stream join detection
  Int64? _currentVideoGroupId;
  bool _joinedVideoMidGroup = false;
  bool _foundValidVideoStart = false;
  int _skippedVideoFrames = 0;

  // Media paths
  String? _videoPath;
  String? _audioPath;

  MoQVideoPlayer({Logger? logger})
      : _logger = logger ?? Logger(),
        _player = Player() {
    _controller = VideoController(_player);
    _logger.i('MoQVideoPlayer created');
    _setupPlayerListeners();
    _configureLivePlayback();
  }

  /// Configure mpv for live/growing file playback
  Future<void> _configureLivePlayback() async {
    try {
      // Access the native player to set mpv properties
      final nativePlayer = _player.platform;
      if (nativePlayer is NativePlayer) {
        // Tell demuxer this is a live/untimed stream
        await nativePlayer.setProperty('demuxer-lavf-o', 'live=1');
        // Use low-latency profile
        await nativePlayer.setProperty('profile', 'low-latency');
        // Reduce cache for live playback
        await nativePlayer.setProperty('cache', 'no');
        await nativePlayer.setProperty('cache-pause', 'no');
        // Don't wait for full file
        await nativePlayer.setProperty('demuxer-readahead-secs', '1');
        // Force continuous reading
        await nativePlayer.setProperty('stream-buffer-size', '4k');
        _logger.i('Configured mpv for live playback');
      }
    } catch (e) {
      _logger.w('Could not configure live playback options: $e');
    }
  }

  void _setupPlayerListeners() {
    _player.stream.completed.listen((completed) {
      _logger.d('Playback completed: $completed');
      if (completed) {
        _isPlaying = false;
      }
    });

    _player.stream.position.listen((position) {
      _position = position;
    });

    _player.stream.duration.listen((duration) {
      _duration = duration;
    });

    _player.stream.playing.listen((playing) {
      _isPlaying = playing;
      _logger.d('Playing state: $playing');
    });

    _player.stream.error.listen((error) {
      _logger.e('Player error: $error');
    });

    _player.stream.buffering.listen((buffering) {
      _logger.d('Buffering: $buffering');
    });
  }

  /// Get the underlying player
  Player get player => _player;

  /// Get the video controller for widget
  VideoController get controller => _controller;

  /// Check if player is initialized
  bool get isInitialized => _isInitialized;

  /// Check if player is currently playing
  bool get isPlaying => _isPlaying;

  /// Check if media is ready for playback
  bool get isMediaReady => _mediaOpened;

  /// Get current playback position
  Duration get position => _position;

  /// Get total duration
  Duration get duration => _duration;

  /// Get statistics
  int get objectsReceived => _objectsReceived;
  int get bytesReceived => _bytesReceived;

  /// Get pipeline statistics
  int get videoFramesReceived =>
      _playbackPipeline?.mediaPipeline.videoFramesReceived ?? 0;
  int get audioFramesReceived =>
      _playbackPipeline?.mediaPipeline.audioFramesReceived ?? 0;
  int get videoSegmentsWritten => _playbackPipeline?.videoSegmentsWritten ?? 0;
  int get audioSegmentsWritten => _playbackPipeline?.audioSegmentsWritten ?? 0;

  /// Initialize the player with MoQ subscriptions
  Future<void> initialize(List<MoQSubscription> subscriptions) async {
    if (_isInitialized) {
      _logger.w('Player already initialized');
      return;
    }

    _logger.i('Initializing player with ${subscriptions.length} subscriptions');

    // Create and initialize the playback pipeline
    _playbackPipeline = StreamingPlaybackPipeline();
    await _playbackPipeline!.initialize();

    // Listen for video ready notification
    _videoReadySubscription =
        _playbackPipeline!.onVideoReady.listen(_handleVideoReady);
    _audioReadySubscription =
        _playbackPipeline!.onAudioReady.listen(_handleAudioReady);

    // Subscribe to incoming objects from all subscriptions
    for (final subscription in subscriptions) {
      final sub = subscription.objectStream.listen(
        _handleMediaObject,
        onError: (error) => _logger.e('Object stream error: $error'),
        onDone: () => _logger.i('Object stream closed'),
      );
      _objectSubscriptions.add(sub);
    }

    _isInitialized = true;
    _logger.i('Player initialized with streaming pipeline');
  }

  /// Initialize the player with a single MoQ subscription (legacy API)
  Future<void> initializeSingle(MoQSubscription subscription) async {
    await initialize([subscription]);
  }

  void _handleMediaObject(MoQObject object) {
    final trackName = String.fromCharCodes(object.trackName);
    final isVideo = trackName.contains('video');

    _logger.d('Received object on track $trackName: groupId=${object.groupId}, '
        'objectId=${object.objectId}, status=${object.status}, '
        'payloadSize=${object.payload?.length ?? 0}, headers=${object.extensionHeaders.length}');

    if (object.status != ObjectStatus.normal || object.payload == null) {
      if (object.status == ObjectStatus.endOfTrack) {
        _logger.i('Received end of track');
      }
      return;
    }

    _objectsReceived++;
    _bytesReceived += object.payload!.length;

    // For video, implement mid-group join detection and skip logic
    if (isVideo) {
      if (!_handleVideoGroupTracking(object)) {
        // Skip this frame - we're waiting for a valid starting point
        return;
      }
    }

    // Process through the streaming pipeline
    _playbackPipeline?.processObject(object);

    _logger.d(
        'Processed object: ${object.objectId}, ${object.payload!.length} bytes');
  }

  /// Handle video group tracking for mid-stream join detection
  /// Returns true if the frame should be processed, false if it should be skipped
  bool _handleVideoGroupTracking(MoQObject object) {
    final groupId = object.groupId;
    final objectId = object.objectId;

    // First video object ever received
    if (_currentVideoGroupId == null) {
      _currentVideoGroupId = groupId;

      // Check if we joined mid-group (objectId != 0)
      if (objectId != Int64.ZERO) {
        _joinedVideoMidGroup = true;
        _skippedVideoFrames++;
        _logger.w('Detected mid-group join: groupId=$groupId, objectId=$objectId. '
            'Skipping P-frames until next group with keyframe at objectId=0...');
        return false; // Skip this frame - keyframe is at objectId=0 which we missed
      } else {
        // We joined at the start of a group - great!
        _foundValidVideoStart = true;
        _logger.i('Joined at group start: groupId=$groupId, objectId=0');
        return true;
      }
    }

    // Check if this is a new group
    if (groupId != _currentVideoGroupId) {
      _logger.i('New video group detected: $groupId (was $_currentVideoGroupId)');
      _currentVideoGroupId = groupId;

      // New group - check if we're at objectId=0
      if (objectId == Int64.ZERO) {
        if (_joinedVideoMidGroup && !_foundValidVideoStart) {
          _logger.i('Found valid starting point! groupId=$groupId, objectId=0. '
              'Skipped $_skippedVideoFrames frames from partial group.');
        }
        _foundValidVideoStart = true;
        _joinedVideoMidGroup = false;
        return true;
      } else {
        // New group but not at objectId=0 - shouldn't happen normally
        _logger.w('New group $groupId but objectId=$objectId (not 0). '
            'Continuing to wait for group with objectId=0...');
        _skippedVideoFrames++;
        return false;
      }
    }

    // Same group - check if we have a valid start
    if (_foundValidVideoStart) {
      return true; // Process normally
    } else {
      // Still waiting for valid start - skip this P-frame
      _skippedVideoFrames++;
      if (_skippedVideoFrames % 10 == 0) {
        _logger.d('Waiting for keyframe... skipped $_skippedVideoFrames video frames '
            '(groupId=$groupId, objectId=$objectId)');
      }
      return false;
    }
  }

  void _handleVideoReady(String videoPath) {
    _logger.i('Video file ready at: $videoPath');
    _videoPath = videoPath;

    if (!_mediaOpened) {
      _openMedia(videoPath);
    }
  }

  void _handleAudioReady(String audioPath) {
    _logger.i('Audio file ready at: $audioPath');
    _audioPath = audioPath;

    // We prefer to wait for video before starting playback
    // If video becomes available, we'll play video
    // Only play audio-only if explicitly needed (video track not subscribed)
    // For now, log that audio is ready and wait for video
    if (!_mediaOpened && _videoPath == null) {
      _logger.i('Audio ready, waiting for video before starting playback...');
      // Don't start audio-only playback - wait for video keyframe
      // The streaming file approach doesn't work well with audio-only
      // because mpv sees the file as complete after the initial data
    }
  }

  Future<void> _openMedia(String path) async {
    try {
      _logger.i('Opening media file: $path');

      // Open the fMP4 file with options for streaming
      await _player.open(
        Media(path),
        play: true, // Auto-play when opened
      );
      _mediaOpened = true;

      _logger.i('Media opened successfully, playback started');
    } catch (e) {
      _logger.e('Failed to open media: $e');
    }
  }

  /// Start playback
  Future<void> play() async {
    if (!_isInitialized) {
      throw StateError('Player not initialized');
    }

    _logger.i('Starting playback');
    await _player.play();
  }

  /// Pause playback
  Future<void> pause() async {
    _logger.i('Pausing playback');
    await _player.pause();
  }

  /// Stop playback
  Future<void> stop() async {
    _logger.i('Stopping playback');
    await _player.pause();
    await _player.seek(Duration.zero);
  }

  /// Seek to position
  Future<void> seek(Duration position) async {
    _logger.i('Seeking to: $position');
    await _player.seek(position);
  }

  /// Set playback speed
  Future<void> setPlaybackSpeed(double speed) async {
    _logger.i('Setting playback speed: $speed');
    await _player.setRate(speed);
  }

  /// Set volume (0.0 to 1.0)
  Future<void> setVolume(double volume) async {
    if (volume < 0.0 || volume > 1.0) {
      throw ArgumentError('Volume must be between 0.0 and 1.0');
    }
    _logger.d('Setting volume: $volume');
    await _player.setVolume(volume * 100); // media_kit uses 0-100
  }

  /// Release resources
  Future<void> dispose() async {
    _logger.i('Disposing player');

    for (final sub in _objectSubscriptions) {
      await sub.cancel();
    }
    _objectSubscriptions.clear();

    await _videoReadySubscription?.cancel();
    await _audioReadySubscription?.cancel();

    await _playbackPipeline?.dispose();
    _playbackPipeline = null;

    await _player.dispose();

    _isInitialized = false;
    _mediaOpened = false;

    // Reset group tracking state
    _currentVideoGroupId = null;
    _joinedVideoMidGroup = false;
    _foundValidVideoStart = false;
    _skippedVideoFrames = 0;
  }
}

/// Video player widget for displaying MoQ streams
class MoQVideoPlayerWidget extends StatefulWidget {
  final MoQVideoPlayer player;
  final bool showControls;
  final Map<String, String>? headers;

  const MoQVideoPlayerWidget({
    super.key,
    required this.player,
    this.showControls = true,
    this.headers,
  });

  @override
  State<MoQVideoPlayerWidget> createState() => _MoQVideoPlayerWidgetState();
}

class _MoQVideoPlayerWidgetState extends State<MoQVideoPlayerWidget> {
  bool _isBuffering = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _playerStateListener();
  }

  void _playerStateListener() {
    widget.player.player.stream.buffering.listen((buffering) {
      if (mounted) {
        setState(() {
          _isBuffering = buffering;
        });
      }
    });

    widget.player.player.stream.error.listen((error) {
      if (mounted) {
        setState(() {
          _errorMessage = error.toString();
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMessage != null) {
      return _buildErrorWidget();
    }

    return Stack(
      children: [
        // Video player
        Video(
          controller: widget.player.controller,
          // Use default controls or no controls based on showControls
          // Note: For custom controls, you can wrap the player in your own widget
          // TODO: Configure for streaming
          // For streaming sources, we'd use DataSource here
        ),

        // Buffering indicator
        if (_isBuffering)
          const Center(
            child: CircularProgressIndicator(),
          ),
      ],
    );
  }

  Widget _buildErrorWidget() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.red),
          const SizedBox(height: 16),
          Text(
            'Playback Error',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            _errorMessage ?? 'Unknown error',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _errorMessage = null;
              });
              widget.player.play();
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}

/// Custom controls for MoQ video player
class MoQVideoControls extends StatelessWidget {
  final MoQVideoPlayer player;

  const MoQVideoControls({
    super.key,
    required this.player,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black54,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Progress bar
          StreamBuilder(
            stream: player.player.stream.position,
            builder: (context, snapshot) {
              final position = snapshot.data ?? Duration.zero;
              return StreamBuilder(
                stream: player.player.stream.duration,
                builder: (context, snapshot) {
                  final duration = snapshot.data ?? Duration.zero;

                  return Row(
                    children: [
                      Text(_formatDuration(position)),
                      Expanded(
                        child: Slider(
                          value: position.inMilliseconds.toDouble(),
                          max: duration.inMilliseconds.toDouble().clamp(1, double.infinity),
                          onChanged: (value) {
                            player.seek(Duration(milliseconds: value.toInt()));
                          },
                        ),
                      ),
                      Text(_formatDuration(duration)),
                    ],
                  );
                },
              );
            },
          ),
          const SizedBox(height: 8),
          // Control buttons
          StreamBuilder(
            stream: player.player.stream.playing,
            builder: (context, snapshot) {
              final isPlaying = snapshot.data ?? false;

              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.skip_previous),
                    onPressed: () {
                      // TODO: Implement previous object/segment
                    },
                  ),
                  IconButton(
                    icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
                    iconSize: 48,
                    onPressed: () {
                      if (isPlaying) {
                        player.pause();
                      } else {
                        player.play();
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    onPressed: () {
                      // TODO: Implement next object/segment
                    },
                  ),
                  const SizedBox(width: 32),
                  // Volume control
                  IconButton(
                    icon: const Icon(Icons.volume_up),
                    onPressed: () {
                      // TODO: Show volume slider
                    },
                  ),
                  // Fullscreen
                  IconButton(
                    icon: const Icon(Icons.fullscreen),
                    onPressed: () {
                      // TODO: Implement fullscreen
                    },
                  ),
                ],
              );
            },
          ),
          // Statistics
          Text(
            'Objects: ${player.objectsReceived} | Bytes: ${_formatBytes(player.bytesReceived)}',
            style: const TextStyle(fontSize: 10, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// MoQ stream player with integrated subscription management
class MoQStreamPlayer {
  final MoQClient _client;
  final Logger _logger;
  MoQVideoPlayer? _videoPlayer;
  final List<Int64> _subscriptionIds = [];

  MoQStreamPlayer({required MoQClient client, Logger? logger})
      : _client = client,
        _logger = logger ?? Logger();

  /// Initialize player with existing subscriptions from MoQClient
  ///
  /// This should be called after the subscriptions are established
  Future<MoQVideoPlayer> initializeWithSubscriptions() async {
    _logger.i('Initializing player with existing subscriptions');

    final subscriptions = _client.subscriptions.values.toList();
    if (subscriptions.isEmpty) {
      throw StateError('No active subscriptions');
    }

    _videoPlayer = MoQVideoPlayer(logger: _logger);
    await _videoPlayer!.initialize(subscriptions);

    return _videoPlayer!;
  }

  /// Subscribe to a track and start video playback
  Future<MoQVideoPlayer> subscribeAndPlay(
    List<Uint8List> trackNamespace,
    Uint8List trackName, {
    FilterType filterType = FilterType.largestObject,
    Location? startLocation,
    Int64? endGroup,
    int subscriberPriority = 128,
    GroupOrder groupOrder = GroupOrder.none,
    bool forward = true,
  }) async {
    _logger.i('Subscribing to track for playback');

    // Subscribe to the track and get the subscription ID from the response
    final requestId = _client.getNextRequestId();

    final subscribeMessage = SubscribeMessage(
      requestId: requestId,
      trackNamespace: trackNamespace,
      trackName: trackName,
      subscriberPriority: subscriberPriority,
      groupOrder: groupOrder,
      forward: forward ? 1 : 0,
      filterType: filterType,
      startLocation: startLocation,
      endGroup: endGroup,
    );

    _subscriptionIds.add(requestId);

    // Create video player (will be initialized when SUBSCRIBE_OK arrives)
    _videoPlayer = MoQVideoPlayer(logger: _logger);

    // Send subscription message
    await _client.transport.send(subscribeMessage.serialize());

    // Wait for SUBSCRIBE_OK response (this is simplified - in production,
    // you'd wait for the subscription to be properly established)

    _logger.i('Subscription initiated, waiting for SUBSCRIBE_OK');

    // Auto-start playback (data will arrive asynchronously)
    await _videoPlayer!.play();

    return _videoPlayer!;
  }

  /// Get the current video player
  MoQVideoPlayer? get player => _videoPlayer;

  /// Stop playback and unsubscribe
  Future<void> stop() async {
    for (final subscriptionId in _subscriptionIds) {
      await _client.unsubscribe(subscriptionId);
    }
    _subscriptionIds.clear();

    if (_videoPlayer != null) {
      await _videoPlayer!.dispose();
      _videoPlayer = null;
    }
  }

  /// Dispose resources
  Future<void> dispose() async {
    await stop();
  }
}
