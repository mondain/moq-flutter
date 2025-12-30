import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sizer/sizer.dart';
import '../providers/moq_providers.dart';
import '../widgets/connection_status_card.dart';

/// Screen for viewing subscribed MoQ streams
class ViewerScreen extends ConsumerStatefulWidget {
  final String namespace;
  final String trackName;
  final String trackAlias;

  const ViewerScreen({
    super.key,
    required this.namespace,
    required this.trackName,
    required this.trackAlias,
  });

  @override
  ConsumerState<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends ConsumerState<ViewerScreen> {
  String _statusMessage = '';
  final int _receivedObjects = 0;

  @override
  void initState() {
    super.initState();
    _statusMessage = 'Subscribed to ${widget.namespace}/${widget.trackName}';
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
                      'Track alias: ${widget.trackAlias}',
                      style: TextStyle(color: Colors.white54, fontSize: 10.sp),
                    ),
                    SizedBox(height: 1.h),
                    Text(
                      '$_receivedObjects objects received',
                      style: TextStyle(color: Colors.white54, fontSize: 10.sp),
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
                            _buildInfoRow('Track Name', widget.trackName),
                            _buildInfoRow('Track Alias', widget.trackAlias),
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
