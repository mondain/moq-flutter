import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:sizer/sizer.dart';
import '../providers/moq_providers.dart';
import '../widgets/connection_status_card.dart';
import '../media/moq_video_player.dart';
import '../media/native_moq_player.dart';
import '../services/native_media_player.dart';

/// Screen for viewing subscribed MoQ streams with video playback
class ViewerScreen extends ConsumerStatefulWidget {
  final String namespace;
  final String trackName;
  final String videoTrackAlias;
  final String audioTrackAlias;

  const ViewerScreen({
    super.key,
    required this.namespace,
    required this.trackName,
    required this.videoTrackAlias,
    required this.audioTrackAlias,
  });

  @override
  ConsumerState<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends ConsumerState<ViewerScreen> {
  String _statusMessage = '';
  MoQVideoPlayer? _videoPlayer;
  NativeMoQPlayer? _nativePlayer;
  bool _useNativePlayer = false;
  bool _isInitializing = true;
  String? _errorMessage;

  // Statistics updated by timer
  Timer? _statsTimer;
  int _videoObjectsReceived = 0;
  int _videoFramesDecoded = 0;
  int _audioFramesDecoded = 0;
  int _videoSegmentsWritten = 0;
  int _totalBytesReceived = 0;
  int _bytesWrittenToBuffer = 0;

  @override
  void initState() {
    super.initState();
    _statusMessage = 'Initializing playback...';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializePlayer();
    });
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _videoPlayer?.dispose();
    _nativePlayer?.dispose();
    super.dispose();
  }

  Future<void> _initializePlayer() async {
    try {
      final client = ref.read(moqClientProvider);

      if (client.subscriptions.isEmpty) {
        setState(() {
          _errorMessage = 'No active subscriptions';
          _isInitializing = false;
        });
        return;
      }

      debugPrint('ViewerScreen: Initializing player with ${client.subscriptions.length} subscriptions');

      // Check if native player is available (with defensive try/catch)
      bool nativeAvailable = false;
      try {
        debugPrint('ViewerScreen: Checking native player availability...');
        nativeAvailable = NativeMoQPlayer.isAvailable;
        debugPrint('ViewerScreen: Native player available: $nativeAvailable');
      } catch (e) {
        debugPrint('ViewerScreen: Native player check threw exception: $e');
        nativeAvailable = false;
      }

      // Try native player first (more efficient, no file I/O)
      if (nativeAvailable) {
        debugPrint('ViewerScreen: Using native buffer-based player');
        _useNativePlayer = true;
        _nativePlayer = NativeMoQPlayer();
        await _nativePlayer!.initialize(
          client.subscriptions.values.toList(),
          outputMode: VideoOutputMode.window, // Opens separate mpv window
        );

        // Start statistics timer
        _statsTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
          _updateStats();
        });

        setState(() {
          _statusMessage = 'Using native player (video in separate window)';
          _isInitializing = false;
        });

        // Auto-start playback
        await _nativePlayer!.play();
      } else {
        // Fall back to file-based player
        debugPrint('ViewerScreen: Native player not available, using file-based player');
        _useNativePlayer = false;
        _videoPlayer = MoQVideoPlayer();
        await _videoPlayer!.initialize(client.subscriptions.values.toList());

        // Start statistics timer
        _statsTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
          _updateStats();
        });

        setState(() {
          _statusMessage = 'Waiting for keyframe...';
          _isInitializing = false;
        });

        // Auto-start playback
        await _videoPlayer!.play();
      }

    } catch (e) {
      debugPrint('ViewerScreen: Error initializing player: $e');
      setState(() {
        _errorMessage = 'Failed to initialize player: $e';
        _isInitializing = false;
      });
    }
  }

  void _updateStats() {
    if (!mounted) return;

    if (_useNativePlayer && _nativePlayer != null) {
      setState(() {
        _videoObjectsReceived = _nativePlayer!.objectsReceived;
        _totalBytesReceived = _nativePlayer!.bytesReceived;
        _videoFramesDecoded = _nativePlayer!.videoFramesReceived;
        _audioFramesDecoded = _nativePlayer!.audioFramesReceived;
        _bytesWrittenToBuffer = _nativePlayer!.bytesWrittenToBuffer;

        final stats = _nativePlayer!.getStats();
        if (_nativePlayer!.isPlaying) {
          _statusMessage = 'Playing (native, buffered: ${stats?.buffered ?? 0} bytes)';
        } else if (_videoFramesDecoded > 0) {
          _statusMessage = 'Buffering...';
        } else if (_videoObjectsReceived > 0) {
          _statusMessage = 'Waiting for keyframe... (received $_videoObjectsReceived objects)';
        }
      });
    } else if (_videoPlayer != null) {
      setState(() {
        _videoObjectsReceived = _videoPlayer!.objectsReceived;
        _totalBytesReceived = _videoPlayer!.bytesReceived;
        _videoFramesDecoded = _videoPlayer!.videoFramesReceived;
        _audioFramesDecoded = _videoPlayer!.audioFramesReceived;
        _videoSegmentsWritten = _videoPlayer!.videoSegmentsWritten;

        if (_videoPlayer!.isMediaReady) {
          _statusMessage = 'Playing';
        } else if (_videoFramesDecoded > 0) {
          _statusMessage = 'Buffering video...';
        } else if (_videoObjectsReceived > 0) {
          _statusMessage = 'Decoding frames...';
        }
      });
    }
  }

  Future<void> _disconnect() async {
    try {
      _statsTimer?.cancel();
      await _videoPlayer?.dispose();
      _videoPlayer = null;
      await _nativePlayer?.dispose();
      _nativePlayer = null;

      final client = ref.read(moqClientProvider);
      await client.disconnect();

      if (mounted) {
        context.go('/');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Disconnect failed: $e')),
        );
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = ref.watch(isConnectedProvider);

    // Listen for connection loss
    ref.listen<AsyncValue<bool>>(
      connectionStateProvider,
      (_, state) {
        if (state.hasValue && !state.value! && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Connection lost'),
              backgroundColor: Colors.red,
            ),
          );
          context.go('/');
        }
      },
    );

    return Scaffold(
      appBar: AppBar(
        title: Text('Stream Viewer', style: TextStyle(fontSize: 14.sp)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _disconnect,
        ),
      ),
      body: Column(
        children: [
          // Video player area
          Expanded(
            child: Container(
              color: Colors.black,
              child: _buildVideoArea(),
            ),
          ),

          // Info and controls
          Padding(
            padding: EdgeInsets.all(4.w),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ConnectionStatusCard(statusMessage: _statusMessage),
                    SizedBox(height: 2.h),

                    // Statistics card
                    Card(
                      child: Padding(
                        padding: EdgeInsets.all(4.w),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Stream Statistics',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 13.sp),
                            ),
                            SizedBox(height: 1.h),
                            _buildStatsRow('Objects Received', '$_videoObjectsReceived'),
                            _buildStatsRow('Video Frames', '$_videoFramesDecoded'),
                            _buildStatsRow('Audio Frames', '$_audioFramesDecoded'),
                            if (_useNativePlayer)
                              _buildStatsRow('Buffer Written', _formatBytes(_bytesWrittenToBuffer))
                            else
                              _buildStatsRow('Segments Written', '$_videoSegmentsWritten'),
                            _buildStatsRow('Data Received', _formatBytes(_totalBytesReceived)),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 1.h),

                    // Track info card
                    Card(
                      child: Padding(
                        padding: EdgeInsets.all(4.w),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Track Info',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 13.sp),
                            ),
                            SizedBox(height: 1.h),
                            _buildInfoRow('Namespace', widget.namespace),
                            _buildInfoRow('Video Track', widget.videoTrackAlias),
                            _buildInfoRow('Audio Track', widget.audioTrackAlias),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 2.h),

                    // Disconnect button
                    OutlinedButton.icon(
                      onPressed: isConnected ? _disconnect : null,
                      icon: const Icon(Icons.stop),
                      label: Text('Disconnect', style: TextStyle(fontSize: 12.sp)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoArea() {
    if (_isInitializing) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 2.h),
            Text(
              'Initializing player...',
              style: TextStyle(color: Colors.white70, fontSize: 12.sp),
            ),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 8.h, color: Colors.red),
            SizedBox(height: 2.h),
            Text(
              'Playback Error',
              style: TextStyle(color: Colors.white, fontSize: 14.sp),
            ),
            SizedBox(height: 1.h),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 4.w),
              child: Text(
                _errorMessage!,
                style: TextStyle(color: Colors.white70, fontSize: 11.sp),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      );
    }

    // Native player - video in separate mpv window
    if (_useNativePlayer) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _nativePlayer?.isPlaying == true
                  ? Icons.videocam
                  : Icons.play_circle_outline,
              size: 8.h,
              color: _nativePlayer?.isPlaying == true
                  ? Colors.green
                  : Colors.white54,
            ),
            SizedBox(height: 2.h),
            Text(
              'Native Player Mode',
              style: TextStyle(color: Colors.white, fontSize: 14.sp),
            ),
            SizedBox(height: 1.h),
            Text(
              'Video appears in separate mpv window',
              style: TextStyle(color: Colors.white70, fontSize: 12.sp),
            ),
            SizedBox(height: 1.h),
            Text(
              _statusMessage,
              style: TextStyle(color: Colors.white54, fontSize: 11.sp),
            ),
            SizedBox(height: 2.h),
            Text(
              'V:$_videoFramesDecoded A:$_audioFramesDecoded',
              style: TextStyle(color: Colors.white70, fontSize: 10.sp),
            ),
          ],
        ),
      );
    }

    if (_videoPlayer == null) {
      return Center(
        child: Text(
          'No player available',
          style: TextStyle(color: Colors.white70, fontSize: 12.sp),
        ),
      );
    }

    // Show video player or waiting indicator (file-based player)
    return Stack(
      children: [
        // Video player widget
        if (_videoPlayer!.isMediaReady)
          Video(
            controller: _videoPlayer!.controller,
          )
        else
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.play_circle_outline,
                  size: 8.h,
                  color: Colors.white54,
                ),
                SizedBox(height: 2.h),
                Text(
                  'Receiving stream: ${widget.namespace}',
                  style: TextStyle(color: Colors.white70, fontSize: 12.sp),
                ),
                SizedBox(height: 1.h),
                Text(
                  _statusMessage,
                  style: TextStyle(color: Colors.white54, fontSize: 11.sp),
                ),
                if (_videoFramesDecoded > 0) ...[
                  SizedBox(height: 2.h),
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ],
            ),
          ),

        // Overlay stats when playing
        if (_videoPlayer!.isMediaReady)
          Positioned(
            top: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'V:$_videoFramesDecoded A:$_audioFramesDecoded',
                style: const TextStyle(color: Colors.white70, fontSize: 10),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 0.3.h),
      child: Row(
        children: [
          Text(
            '$label: ',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11.sp),
          ),
          Expanded(
            child: Text(value, style: TextStyle(fontSize: 11.sp)),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 0.2.h),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 10.sp, color: Colors.grey)),
          Text(value, style: TextStyle(fontSize: 10.sp, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
