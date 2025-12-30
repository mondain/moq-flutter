import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sizer/sizer.dart';
import '../providers/moq_providers.dart';
import '../widgets/connection_status_card.dart';
import '../widgets/server_config_card.dart';
import '../widgets/track_config_card.dart';

/// Client role - what action to take after connecting
enum ClientRole {
  subscriber,
  publisher,
}

/// Connection screen for configuring and establishing MoQ connections
class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({super.key});

  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  final _hostController = TextEditingController(text: 'localhost');
  final _portController = TextEditingController(text: '8443');
  final _urlController = TextEditingController(text: 'https://localhost:4433/moq');
  final _namespaceController = TextEditingController(text: 'demo');
  final _trackNameController = TextEditingController(text: 'video');

  bool _isLoading = false;
  bool _insecureMode = false;
  TransportType _transportType = TransportType.moqt;
  ClientRole _clientRole = ClientRole.subscriber;
  String _statusMessage = '';

  @override
  void initState() {
    super.initState();
    _transportType = ref.read(transportTypeProvider);
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _urlController.dispose();
    _namespaceController.dispose();
    _trackNameController.dispose();
    super.dispose();
  }

  void _setStatus(String message) {
    if (mounted) {
      setState(() => _statusMessage = message);
    }
  }

  Future<void> _connect() async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'Connecting...';
    });

    try {
      final client = ref.read(moqClientProvider);

      // Connect based on transport type
      if (_transportType == TransportType.webtransport) {
        final urlStr = _urlController.text;
        final uri = Uri.parse(urlStr);
        final host = uri.host;
        final port = uri.port;
        final path = uri.path;

        _setStatus('Connecting to $host:$port via WebTransport...');
        await client.connect(host, port, options: {
          'insecure': _insecureMode.toString(),
          'path': path,
        });
      } else {
        final host = _hostController.text;
        final port = int.tryParse(_portController.text) ?? 8443;

        _setStatus('Connecting to $host:$port via QUIC...');
        await client.connect(host, port, options: {'insecure': _insecureMode.toString()});
      }

      _setStatus('Connected!');

      if (!mounted) return;

      // Navigate to appropriate screen based on role
      final namespace = _namespaceController.text;
      final trackName = _trackNameController.text;

      if (_clientRole == ClientRole.subscriber) {
        // Subscribe and navigate to viewer
        _setStatus('Subscribing to $namespace/$trackName...');
        final namespaceBytes = [Uint8List.fromList(namespace.codeUnits)];
        final trackNameBytes = Uint8List.fromList(trackName.codeUnits);

        final result = await client.subscribe(namespaceBytes, trackNameBytes);
        _setStatus('Subscribed! Track alias: ${result.trackAlias}');

        if (mounted) {
          context.go('/viewer', extra: {
            'namespace': namespace,
            'trackName': trackName,
            'trackAlias': result.trackAlias.toString(),
          });
        }
      } else {
        // Navigate to publisher screen
        if (mounted) {
          context.go('/publisher', extra: {
            'namespace': namespace,
            'trackName': trackName,
          });
        }
      }
    } catch (e) {
      _setStatus('Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = ref.watch(isConnectedProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('MoQ Flutter Client', style: TextStyle(fontSize: 14.sp)),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(4.w),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 600),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Connection Status
                ConnectionStatusCard(statusMessage: _statusMessage),
                SizedBox(height: 2.h),

                // Role selector
                Text(
                  'Client Role',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(fontSize: 12.sp),
                ),
                SizedBox(height: 1.h),
                SegmentedButton<ClientRole>(
                  segments: [
                    ButtonSegment(
                      value: ClientRole.subscriber,
                      label: Text('Subscribe', style: TextStyle(fontSize: 11.sp)),
                      icon: const Icon(Icons.download),
                    ),
                    ButtonSegment(
                      value: ClientRole.publisher,
                      label: Text('Publish', style: TextStyle(fontSize: 11.sp)),
                      icon: const Icon(Icons.upload),
                    ),
                  ],
                  selected: {_clientRole},
                  onSelectionChanged: (isConnected || _isLoading)
                      ? null
                      : (Set<ClientRole> newSelection) {
                          setState(() => _clientRole = newSelection.first);
                        },
                ),
                SizedBox(height: 2.h),

                // Transport type selector
                Text(
                  'Transport Type',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(fontSize: 12.sp),
                ),
                SizedBox(height: 1.h),
                SegmentedButton<TransportType>(
                  segments: [
                    ButtonSegment(
                      value: TransportType.moqt,
                      label: Text('Raw QUIC', style: TextStyle(fontSize: 11.sp)),
                      icon: const Icon(Icons.router),
                    ),
                    ButtonSegment(
                      value: TransportType.webtransport,
                      label: Text('WebTransport', style: TextStyle(fontSize: 11.sp)),
                      icon: const Icon(Icons.http),
                    ),
                  ],
                  selected: {_transportType},
                  onSelectionChanged: (isConnected || _isLoading)
                      ? null
                      : (Set<TransportType> newSelection) {
                          final newType = newSelection.first;
                          setState(() => _transportType = newType);
                          ref.read(transportTypeProvider.notifier).setTransportType(newType);
                        },
                ),
                SizedBox(height: 2.h),

                // Server configuration
                ServerConfigCard(
                  hostController: _hostController,
                  portController: _portController,
                  urlController: _urlController,
                  transportType: _transportType,
                  insecureMode: _insecureMode,
                  onInsecureModeChanged: (value) => setState(() => _insecureMode = value),
                  enabled: !isConnected && !_isLoading,
                ),
                SizedBox(height: 2.h),

                // Track configuration
                TrackConfigCard(
                  namespaceController: _namespaceController,
                  trackNameController: _trackNameController,
                  isPublisher: _clientRole == ClientRole.publisher,
                  enabled: !isConnected && !_isLoading,
                ),
                SizedBox(height: 3.h),

                // Connect button
                FilledButton.icon(
                  onPressed: (isConnected || _isLoading) ? null : _connect,
                  icon: _isLoading
                      ? SizedBox(
                          height: 2.5.h,
                          width: 2.5.h,
                          child: const CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(_clientRole == ClientRole.subscriber
                          ? Icons.play_arrow
                          : Icons.publish),
                  label: Text(
                    _isLoading
                        ? 'Connecting...'
                        : _clientRole == ClientRole.subscriber
                            ? 'Connect & Subscribe'
                            : 'Connect & Publish',
                    style: TextStyle(fontSize: 12.sp),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
