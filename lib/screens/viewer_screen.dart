import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:sizer/sizer.dart';
import '../providers/moq_providers.dart';
import '../widgets/connection_status_card.dart';
import '../media/moq_video_player.dart';

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
  bool _isInitializing = true;
  String? _errorMessage;

  // Statistics updated by timer
  Timer? _statsTimer;
  int _videoObjectsReceived = 0;
  int _videoFramesDecoded = 0;
  int _audioFramesDecoded = 0;
  int _videoSegmentsWritten = 0;
  int _totalBytesReceived = 0;

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

      debugPrint('ViewerScreen: Initializing video player with ${client.subscriptions.length} subscriptions');

      // Create and initialize the video player
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

    } catch (e) {
      debugPrint('ViewerScreen: Error initializing player: $e');
      setState(() {
        _errorMessage = 'Failed to initialize player: $e';
        _isInitializing = false;
      });
    }
  }

  void _updateStats() {
    if (!mounted || _videoPlayer == null) return;

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

  Future<void> _disconnect() async {
    try {
      _statsTimer?.cancel();
      await _videoPlayer?.dispose();
      _videoPlayer = null;

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
                            _buildInfoRow('Video Track', 'video0'),
                            _buildInfoRow('Audio Track', 'audio0'),
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

    if (_videoPlayer == null) {
      return Center(
        child: Text(
          'No player available',
          style: TextStyle(color: Colors.white70, fontSize: 12.sp),
        ),
      );
    }

    // Show video player or waiting indicator
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
