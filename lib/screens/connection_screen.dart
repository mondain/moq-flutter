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
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _urlController;
  late final TextEditingController _namespaceController;
  late final TextEditingController _trackNameController;

  bool _isLoading = false;
  bool _insecureMode = false;
  TransportType _transportType = TransportType.moqt;
  ClientRole _clientRole = ClientRole.subscriber;
  String _statusMessage = '';

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsServiceProvider);

    // Load saved settings
    _hostController = TextEditingController(text: settings.host);
    _portController = TextEditingController(text: settings.port);
    _urlController = TextEditingController(text: settings.url);
    _namespaceController = TextEditingController(text: settings.namespace);
    _trackNameController = TextEditingController(text: settings.trackName);
    _insecureMode = settings.insecureMode;
    _transportType = ref.read(transportTypeProvider);

    // Add listeners to save on change
    _hostController.addListener(_saveHost);
    _portController.addListener(_savePort);
    _urlController.addListener(_saveUrl);
    _namespaceController.addListener(_saveNamespace);
    _trackNameController.addListener(_saveTrackName);
  }

  void _saveHost() => ref.read(settingsServiceProvider).setHost(_hostController.text);
  void _savePort() => ref.read(settingsServiceProvider).setPort(_portController.text);
  void _saveUrl() => ref.read(settingsServiceProvider).setUrl(_urlController.text);
  void _saveNamespace() => ref.read(settingsServiceProvider).setNamespace(_namespaceController.text);
  void _saveTrackName() => ref.read(settingsServiceProvider).setTrackName(_trackNameController.text);

  @override
  void dispose() {
    _hostController.removeListener(_saveHost);
    _portController.removeListener(_savePort);
    _urlController.removeListener(_saveUrl);
    _namespaceController.removeListener(_saveNamespace);
    _trackNameController.removeListener(_saveTrackName);
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
                  onInsecureModeChanged: (value) {
                    setState(() => _insecureMode = value);
                    ref.read(settingsServiceProvider).setInsecureMode(value);
                  },
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
