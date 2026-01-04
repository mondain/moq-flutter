import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sizer/sizer.dart';
import '../providers/moq_providers.dart';
import '../widgets/connection_status_card.dart';
import '../moq/protocol/moq_messages.dart';

/// Screen for viewing subscribed MoQ streams
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
  int _videoObjectsReceived = 0;
  int _audioObjectsReceived = 0;
  int _totalBytesReceived = 0;
  final List<StreamSubscription<MoQObject>> _objectSubscriptions = [];

  @override
  void initState() {
    super.initState();
    _statusMessage = 'Subscribed to ${widget.namespace}/${widget.trackName}';
    // Delay slightly to allow the widget to fully initialize with ref
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startListeningToObjects();
    });
  }

  @override
  void dispose() {
    for (final sub in _objectSubscriptions) {
      sub.cancel();
    }
    _objectSubscriptions.clear();
    super.dispose();
  }

  void _startListeningToObjects() {
    final client = ref.read(moqClientProvider);

    debugPrint('ViewerScreen: Starting to listen to objects');
    debugPrint('ViewerScreen: Found ${client.subscriptions.length} subscriptions');

    // Listen to all subscriptions' object streams
    for (final entry in client.subscriptions.entries) {
      final subscriptionId = entry.key;
      final subscription = entry.value;
      debugPrint('ViewerScreen: Listening to subscription $subscriptionId');

      final sub = subscription.objectStream.listen((object) {
        debugPrint('ViewerScreen: Received object from subscription $subscriptionId');
        _onObjectReceived(object);
      }, onError: (e) {
        debugPrint('ViewerScreen: Error on subscription $subscriptionId: $e');
      }, onDone: () {
        debugPrint('ViewerScreen: Subscription $subscriptionId stream closed');
      });
      _objectSubscriptions.add(sub);
    }

    if (client.subscriptions.isEmpty) {
      _statusMessage = 'No active subscriptions';
    } else {
      _statusMessage = 'Listening to ${client.subscriptions.length} tracks';
    }
    if (mounted) setState(() {});
  }

  void _onObjectReceived(MoQObject object) {
    if (!mounted) return;

    final trackName = String.fromCharCodes(object.trackName);
    final payloadLen = object.payload?.length ?? 0;
    debugPrint('ViewerScreen: Object received - track=$trackName, bytes=$payloadLen');

    setState(() {
      _totalBytesReceived += payloadLen;

      // Determine if video or audio based on track name
      if (trackName.contains('video')) {
        _videoObjectsReceived++;
        debugPrint('ViewerScreen: Video object $_videoObjectsReceived');
      } else if (trackName.contains('audio')) {
        _audioObjectsReceived++;
        debugPrint('ViewerScreen: Audio object $_audioObjectsReceived');
      } else {
        // Count as video if name doesn't match
        _videoObjectsReceived++;
        debugPrint('ViewerScreen: Unknown track "$trackName", counting as video');
      }

      _statusMessage = 'Receiving: video=$_videoObjectsReceived, audio=$_audioObjectsReceived';
    });
  }

  Future<void> _disconnect() async {
    try {
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
              child: Center(
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
                      'Receiving stream: ${widget.namespace}/${widget.trackName}',
                      style: TextStyle(color: Colors.white70, fontSize: 12.sp),
                    ),
                    SizedBox(height: 1.h),
                    Text(
                      'Video: ${widget.videoTrackAlias} | Audio: ${widget.audioTrackAlias}',
                      style: TextStyle(color: Colors.white54, fontSize: 10.sp),
                    ),
                    SizedBox(height: 2.h),
                    // Stats display
                    Container(
                      padding: EdgeInsets.all(2.w),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          Text(
                            'Video Objects: $_videoObjectsReceived',
                            style: TextStyle(color: Colors.greenAccent, fontSize: 11.sp),
                          ),
                          Text(
                            'Audio Objects: $_audioObjectsReceived',
                            style: TextStyle(color: Colors.blueAccent, fontSize: 11.sp),
                          ),
                          Text(
                            'Total Data: ${_formatBytes(_totalBytesReceived)}',
                            style: TextStyle(color: Colors.white70, fontSize: 11.sp),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
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
                            _buildInfoRow('Video Alias', widget.videoTrackAlias),
                            _buildInfoRow('Audio Alias', widget.audioTrackAlias),
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

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 0.5.h),
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
}
