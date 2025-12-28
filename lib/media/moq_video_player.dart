import 'dart:async';
import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:logger/logger.dart';
import '../moq/protocol/moq_messages.dart';
import '../moq/client/moq_client.dart';

/// Video player service for MoQ media streams
class MoQVideoPlayer {
  final Logger _logger;
  final Player _player;
  late final VideoController _controller;

  // Stream subscription
  StreamSubscription<MoQObject>? _objectSubscription;

  // Buffer for incoming media data
  final _mediaBuffer = StreamController<Uint8List>();
  int _bufferedBytes = 0;
  static const int _maxBufferSize = 10 * 1024 * 1024; // 10MB

  // Playback state
  bool _isInitialized = false;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  // Statistics
  int _objectsReceived = 0;
  int _bytesReceived = 0;

  MoQVideoPlayer({Logger? logger})
      : _logger = logger ?? Logger(),
        _player = Player() {
    _controller = VideoController(_player);
    _logger.i('MoQVideoPlayer created');
    _setupPlayerListeners();
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

  /// Get current playback position
  Duration get position => _position;

  /// Get total duration
  Duration get duration => _duration;

  /// Get statistics
  int get objectsReceived => _objectsReceived;
  int get bytesReceived => _bytesReceived;
  int get bufferedBytes => _bufferedBytes;

  /// Initialize the player with a MoQ subscription
  Future<void> initialize(MoQSubscription subscription) async {
    if (_isInitialized) {
      _logger.w('Player already initialized');
      return;
    }

    _logger.i('Initializing player with subscription: ${subscription.id}');

    // Subscribe to incoming objects
    _objectSubscription = subscription.objectStream.listen(
      _handleMediaObject,
      onError: (error) => _logger.e('Object stream error: $error'),
      onDone: () => _logger.i('Object stream closed'),
    );

    _isInitialized = true;
    _logger.i('Player initialized');
  }

  void _handleMediaObject(MoQObject object) {
    if (object.status != ObjectStatus.normal || object.payload == null) {
      if (object.status == ObjectStatus.endOfTrack) {
        _logger.i('Received end of track');
        // Optionally stop playback or seek to beginning
      }
      return;
    }

    _objectsReceived++;
    _bytesReceived += object.payload!.length;
    _bufferedBytes += object.payload!.length;

    // Add payload to media buffer
    _mediaBuffer.add(object.payload!);

    // Trim buffer if it exceeds max size
    if (_bufferedBytes > _maxBufferSize) {
      _logger.w('Buffer exceeds max size, dropping oldest data');
      _bufferedBytes = 0; // Reset for simplicity
      // In production, implement proper sliding window
    }

    _logger.d('Received object: ${object.objectId}, ${object.payload!.length} bytes');

    // TODO: Detect media format and initialize player if needed
    // For now, we'll assume the stream is in a playable format
  }

  /// Start playback
  Future<void> play() async {
    if (!_isInitialized) {
      throw StateError('Player not initialized');
    }

    _logger.i('Starting playback');

    // In a real implementation, you would:
    // 1. Feed buffered data to the player
    // 2. Handle codec initialization
    // 3. Start playback

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
    await _player.setVolume(volume);
  }

  /// Release resources
  Future<void> dispose() async {
    _logger.i('Disposing player');

    await _objectSubscription?.cancel();
    _objectSubscription = null;

    await _mediaBuffer.close();
    await _player.dispose();

    _isInitialized = false;
    _bufferedBytes = 0;
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
  Int64? _subscriptionId;

  MoQStreamPlayer({required MoQClient client, Logger? logger})
      : _client = client,
        _logger = logger ?? Logger();

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

    // Note: We're bypassing the subscribe() method to get access to the subscription
    // In production, you'd want to refactor the client to expose the subscription properly
    _subscriptionId = requestId;

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
    if (_subscriptionId != null) {
      await _client.unsubscribe(_subscriptionId!);
      _subscriptionId = null;
    }

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
