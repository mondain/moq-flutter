import 'dart:async';
import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import '../moq/client/moq_client.dart';
import '../moq/protocol/moq_messages.dart';
import 'moq_video_player.dart';

/// Provider for the MoQ client
final moqClientProvider = Provider<MoQClient>((ref) {
  throw UnimplementedError('MoQClient must be provided externally');
});

/// Logger provider
final loggerProvider = Provider<Logger>((ref) {
  return Logger();
});

/// Video player state
class VideoPlayerState {
  final MoQVideoPlayer? player;
  final bool isLoading;
  final bool isPlaying;
  final String? error;
  final Duration position;
  final Duration duration;

  const VideoPlayerState({
    this.player,
    this.isLoading = false,
    this.isPlaying = false,
    this.error,
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });

  VideoPlayerState copyWith({
    MoQVideoPlayer? player,
    bool? isLoading,
    bool? isPlaying,
    String? error,
    Duration? position,
    Duration? duration,
  }) {
    return VideoPlayerState(
      player: player ?? this.player,
      isLoading: isLoading ?? this.isLoading,
      isPlaying: isPlaying ?? this.isPlaying,
      error: error ?? this.error,
      position: position ?? this.position,
      duration: duration ?? this.duration,
    );
  }
}

/// Video player state notifier
class VideoPlayerNotifier extends StateNotifier<VideoPlayerState> {
  final MoQClient _client;
  final Logger _logger;

  MoQStreamPlayer? _streamPlayer;
  StreamSubscription? _positionSubscription;

  VideoPlayerNotifier({required MoQClient client, required Logger logger})
      : _client = client,
        _logger = logger,
        super(const VideoPlayerState());

  /// Subscribe to a track and start video playback
  Future<void> subscribeAndPlay(
    List<Uint8List> trackNamespace,
    Uint8List trackName, {
    FilterType filterType = FilterType.largestObject,
    Location? startLocation,
    Int64? endGroup,
    int subscriberPriority = 128,
    GroupOrder groupOrder = GroupOrder.none,
    bool forward = true,
  }) async {
    if (state.player != null) {
      await stop();
    }

    state = state.copyWith(isLoading: true, error: null);

    try {
      _streamPlayer = MoQStreamPlayer(client: _client, logger: _logger);
      final player = await _streamPlayer!.subscribeAndPlay(
        trackNamespace,
        trackName,
        filterType: filterType,
        startLocation: startLocation,
        endGroup: endGroup,
        subscriberPriority: subscriberPriority,
        groupOrder: groupOrder,
        forward: forward,
      );

      // Start listening to position updates
      _startPositionListener(player);

      state = state.copyWith(
        player: player,
        isLoading: false,
        isPlaying: player.isPlaying,
      );

      _logger.i('Video playback started');
    } catch (e) {
      _logger.e('Failed to start playback: $e');
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  void _startPositionListener(MoQVideoPlayer player) {
    _positionSubscription?.cancel();
    _positionSubscription = Stream.periodic(
      const Duration(milliseconds: 100),
      (_) => player,
    ).listen((player) {
      if (mounted) {
        state = state.copyWith(
          position: player.position,
          duration: player.duration,
          isPlaying: player.isPlaying,
        );
      }
    });
  }

  /// Play/Pause toggle
  Future<void> togglePlayPause() async {
    final player = state.player;
    if (player == null) return;

    if (player.isPlaying) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  /// Seek to position
  Future<void> seek(Duration position) async {
    final player = state.player;
    if (player == null) return;

    await player.seek(position);
  }

  /// Set playback speed
  Future<void> setPlaybackSpeed(double speed) async {
    final player = state.player;
    if (player == null) return;

    await player.setPlaybackSpeed(speed);
  }

  /// Set volume
  Future<void> setVolume(double volume) async {
    final player = state.player;
    if (player == null) return;

    await player.setVolume(volume);
  }

  /// Stop playback
  Future<void> stop() async {
    await _streamPlayer?.stop();
    await _positionSubscription?.cancel();
    _streamPlayer = null;
    _positionSubscription = null;

    state = const VideoPlayerState();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

/// Video player provider
final videoPlayerProvider =
    StateNotifierProvider<VideoPlayerNotifier, VideoPlayerState>((ref) {
  final client = ref.watch(moqClientProvider);
  final logger = ref.watch(loggerProvider);

  final notifier = VideoPlayerNotifier(client: client, logger: logger);

  ref.onDispose(() {
    notifier.dispose();
  });

  return notifier;
});

/// Current video player state
final currentPlayerState = Provider<VideoPlayerState>((ref) {
  return ref.watch(videoPlayerProvider);
});

/// Convenience provider for the video player instance
final currentPlayer = Provider<MoQVideoPlayer?>((ref) {
  return ref.watch(videoPlayerProvider).player;
});

/// Video player widget that connects to the provider
class MoQVideoPlayerScreen extends ConsumerStatefulWidget {
  final List<Uint8List> trackNamespace;
  final Uint8List trackName;
  final Map<String, String>? connectionOptions;

  const MoQVideoPlayerScreen({
    super.key,
    required this.trackNamespace,
    required this.trackName,
    this.connectionOptions,
  });

  @override
  ConsumerState<MoQVideoPlayerScreen> createState() =>
      _MoQVideoPlayerScreenState();
}

class _MoQVideoPlayerScreenState extends ConsumerState<MoQVideoPlayerScreen> {
  @override
  void initState() {
    super.initState();
    // Auto-start playback when screen is loaded
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startPlayback();
    });
  }

  Future<void> _startPlayback() async {
    final notifier = ref.read(videoPlayerProvider.notifier);
    await notifier.subscribeAndPlay(
      widget.trackNamespace,
      widget.trackName,
    );
  }

  @override
  Widget build(BuildContext context) {
    final playerState = ref.watch(currentPlayerState);

    return Scaffold(
      appBar: AppBar(
        title: const Text('MoQ Video Player'),
        actions: [
          if (playerState.player != null)
            IconButton(
              icon: Icon(playerState.isPlaying ? Icons.pause : Icons.play_arrow),
              onPressed: () {
                ref.read(videoPlayerProvider.notifier).togglePlayPause();
              },
            ),
        ],
      ),
      body: _buildBody(playerState),
    );
  }

  Widget _buildBody(VideoPlayerState playerState) {
    if (playerState.isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Connecting to MoQ stream...'),
          ],
        ),
      );
    }

    if (playerState.error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text('Error: ${playerState.error}'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => _startPlayback(),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (playerState.player == null) {
      return const Center(
        child: Text('No video player initialized'),
      );
    }

    return Column(
      children: [
        // Video player
        Expanded(
          child: MoQVideoPlayerWidget(
            player: playerState.player!,
            showControls: false, // Custom controls below
          ),
        ),
        // Custom controls
        _buildControls(playerState),
        // Statistics
        _buildStatistics(playerState),
      ],
    );
  }

  Widget _buildControls(VideoPlayerState playerState) {
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Progress bar
          Slider(
            value: playerState.position.inMilliseconds.toDouble(),
            max: playerState.duration.inMilliseconds
                .clamp(1, double.infinity)
                .toDouble(),
            onChanged: (value) {
              ref.read(videoPlayerProvider.notifier).seek(
                Duration(milliseconds: value.toInt()),
              );
            },
          ),
          const SizedBox(height: 8),
          // Time display
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_formatDuration(playerState.position)),
              Text(_formatDuration(playerState.duration)),
            ],
          ),
          const SizedBox(height: 16),
          // Control buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.replay_10),
                onPressed: () {
                  final newPos = playerState.position - const Duration(seconds: 10);
                  ref.read(videoPlayerProvider.notifier).seek(
                    newPos < Duration.zero ? Duration.zero : newPos,
                  );
                },
              ),
              const SizedBox(width: 16),
              IconButton(
                icon: Icon(
                  playerState.isPlaying ? Icons.pause : Icons.play_arrow,
                ),
                iconSize: 48,
                onPressed: () {
                  ref.read(videoPlayerProvider.notifier).togglePlayPause();
                },
              ),
              const SizedBox(width: 16),
              IconButton(
                icon: const Icon(Icons.forward_10),
                onPressed: () {
                  final newPos = playerState.position + const Duration(seconds: 10);
                  ref.read(videoPlayerProvider.notifier).seek(newPos);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatistics(VideoPlayerState playerState) {
    final player = playerState.player;
    if (player == null) return const SizedBox.shrink();

    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          Text('Objects: ${player.objectsReceived}'),
          Text('Bytes: ${_formatBytes(player.bytesReceived)}'),
          Text('Buffer: ${_formatBytes(player.bufferedBytes)}'),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));

    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
