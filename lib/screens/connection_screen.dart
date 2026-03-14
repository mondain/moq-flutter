import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../moq/protocol/moq_messages.dart';
import '../providers/moq_providers.dart';
import '../widgets/server_config_card.dart';
import '../widgets/track_config_card.dart';

/// Client role - what action to take after connecting
enum ClientRole { subscriber, publisher }

enum SubscriberPlaybackMode { catalog, directTracks }

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

  bool _isLoading = false;
  bool _insecureMode = false;
  TransportType _transportType = TransportType.moqt;
  ClientRole _clientRole = ClientRole.subscriber;
  SubscriberPlaybackMode _subscriberPlaybackMode =
      SubscriberPlaybackMode.catalog;
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
    _insecureMode = settings.insecureMode;
    _transportType = ref.read(transportTypeProvider);

    // Add listeners to save on change
    _hostController.addListener(_saveHost);
    _portController.addListener(_savePort);
    _urlController.addListener(_saveUrl);
    _namespaceController.addListener(_saveNamespace);
  }

  void _saveHost() =>
      ref.read(settingsServiceProvider).setHost(_hostController.text);
  void _savePort() =>
      ref.read(settingsServiceProvider).setPort(_portController.text);
  void _saveUrl() =>
      ref.read(settingsServiceProvider).setUrl(_urlController.text);
  void _saveNamespace() =>
      ref.read(settingsServiceProvider).setNamespace(_namespaceController.text);

  /// Refresh controllers from settings (e.g. after returning from settings screen)
  void _refreshFromSettings() {
    final settings = ref.read(settingsServiceProvider);
    if (_hostController.text != settings.host) {
      _hostController.text = settings.host;
    }
    if (_portController.text != settings.port) {
      _portController.text = settings.port;
    }
    if (_urlController.text != settings.url) {
      _urlController.text = settings.url;
    }
    if (_namespaceController.text != settings.namespace) {
      _namespaceController.text = settings.namespace;
    }
  }

  @override
  void dispose() {
    _hostController.removeListener(_saveHost);
    _portController.removeListener(_savePort);
    _urlController.removeListener(_saveUrl);
    _namespaceController.removeListener(_saveNamespace);
    _hostController.dispose();
    _portController.dispose();
    _urlController.dispose();
    _namespaceController.dispose();
    super.dispose();
  }

  void _setStatus(String message) {
    if (mounted) {
      setState(() => _statusMessage = message);
    }
  }

  (String, String) _resolvedDirectTrackNames() {
    final packagingFormat = ref.read(packagingFormatProvider);
    switch (packagingFormat) {
      case PackagingFormat.cmaf:
        return ('1.m4s', '2.m4s');
      case PackagingFormat.loc:
        return ('video', 'audio');
      case PackagingFormat.moqMi:
        return (
          ref.read(videoTrackNameProvider),
          ref.read(audioTrackNameProvider),
        );
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
        await client.connect(
          host,
          port,
          options: {'insecure': _insecureMode.toString(), 'path': path},
        );
      } else {
        final host = _hostController.text;
        final port = int.tryParse(_portController.text) ?? 8443;

        _setStatus('Connecting to $host:$port via QUIC...');
        await client.connect(
          host,
          port,
          options: {'insecure': _insecureMode.toString()},
        );
      }

      _setStatus('Connected!');

      if (!mounted) return;

      // Navigate to appropriate screen based on role
      final namespace = _namespaceController.text;
      final trackName = ref.read(settingsServiceProvider).trackName;

      if (_clientRole == ClientRole.subscriber) {
        final (videoTrackName, audioTrackName) = _resolvedDirectTrackNames();
        String videoTrackAlias = '';
        String audioTrackAlias = '';

        if (_subscriberPlaybackMode == SubscriberPlaybackMode.directTracks) {
          final namespaceBytes = [Uint8List.fromList(namespace.codeUnits)];

          _setStatus('Subscribing to $namespace/$videoTrackName...');
          final videoTrackNameBytes = Uint8List.fromList(
            videoTrackName.codeUnits,
          );
          final videoResult = await client.subscribe(
            namespaceBytes,
            videoTrackNameBytes,
            filterType: FilterType.nextGroupStart,
          );
          videoTrackAlias = videoResult.trackAlias.toString();

          _setStatus('Subscribing to $namespace/$audioTrackName...');
          final audioTrackNameBytes = Uint8List.fromList(
            audioTrackName.codeUnits,
          );
          final audioResult = await client.subscribe(
            namespaceBytes,
            audioTrackNameBytes,
            filterType: FilterType.nextGroupStart,
          );
          audioTrackAlias = audioResult.trackAlias.toString();
        } else {
          _setStatus('Connected. Opening catalog playback...');
        }

        if (mounted) {
          context.go(
            '/viewer',
            extra: {
              'namespace': namespace,
              'trackName': videoTrackName,
              'videoTrackAlias': videoTrackAlias,
              'audioTrackAlias': audioTrackAlias,
              'useCatalogPlayback':
                  _subscriberPlaybackMode == SubscriberPlaybackMode.catalog,
            },
          );
        }
      } else {
        // Navigate to publisher screen
        if (mounted) {
          context.go(
            '/publisher',
            extra: {'namespace': namespace, 'trackName': trackName},
          );
        }
      }
    } catch (e) {
      _setStatus('Error: $e');
      // Disconnect so the UI returns to a connectable state
      try {
        final client = ref.read(moqClientProvider);
        await client.disconnect();
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red),
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
        title: const Text(
          'MoQ Client',
          style: TextStyle(fontSize: 18),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await context.push('/settings');
              _refreshFromSettings();
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Role selector
                Text(
                  'Client Role',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontSize: 15),
                ),
                const SizedBox(height: 8),
                SegmentedButton<ClientRole>(
                  segments: const [
                    ButtonSegment(
                      value: ClientRole.subscriber,
                      label: Text('Subscribe', style: TextStyle(fontSize: 14)),
                      icon: Icon(Icons.download),
                    ),
                    ButtonSegment(
                      value: ClientRole.publisher,
                      label: Text('Publish', style: TextStyle(fontSize: 14)),
                      icon: Icon(Icons.upload),
                    ),
                  ],
                  selected: {_clientRole},
                  onSelectionChanged: (isConnected || _isLoading)
                      ? null
                      : (Set<ClientRole> newSelection) {
                          setState(() => _clientRole = newSelection.first);
                        },
                ),
                const SizedBox(height: 4),

                // Transport type selector
                Text(
                  'Transport Type',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontSize: 15),
                ),
                const SizedBox(height: 8),
                SegmentedButton<TransportType>(
                  segments: const [
                    ButtonSegment(
                      value: TransportType.moqt,
                      label: Text('Raw QUIC', style: TextStyle(fontSize: 14)),
                      icon: Icon(Icons.router),
                    ),
                    ButtonSegment(
                      value: TransportType.webtransport,
                      label: Text(
                        'WebTransport',
                        style: TextStyle(fontSize: 14),
                      ),
                      icon: Icon(Icons.http),
                    ),
                  ],
                  selected: {_transportType},
                  onSelectionChanged: (isConnected || _isLoading)
                      ? null
                      : (Set<TransportType> newSelection) {
                          final newType = newSelection.first;
                          setState(() => _transportType = newType);
                          ref
                              .read(transportTypeProvider.notifier)
                              .setTransportType(newType);
                        },
                ),
                const SizedBox(height: 16),

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
                const SizedBox(height: 16),

                // Track configuration
                TrackConfigCard(
                  namespaceController: _namespaceController,
                  isPublisher: _clientRole == ClientRole.publisher,
                  title: _clientRole == ClientRole.publisher
                      ? 'Publishing Namespace'
                      : _subscriberPlaybackMode ==
                            SubscriberPlaybackMode.catalog
                      ? 'Catalog Subscription'
                      : 'Tracks to Subscribe',
                  showPublisherTrackName: false,
                  showSubscriberTracks:
                      _clientRole == ClientRole.publisher ||
                      _subscriberPlaybackMode ==
                          SubscriberPlaybackMode.directTracks,
                  enabled: !isConnected && !_isLoading,
                ),
                if (_clientRole == ClientRole.subscriber) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Subscribe Mode',
                    style: Theme.of(
                      context,
                    ).textTheme.titleSmall?.copyWith(fontSize: 15),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<SubscriberPlaybackMode>(
                    segments: const [
                      ButtonSegment(
                        value: SubscriberPlaybackMode.catalog,
                        label: Text('Catalog', style: TextStyle(fontSize: 14)),
                        icon: Icon(Icons.library_books),
                      ),
                      ButtonSegment(
                        value: SubscriberPlaybackMode.directTracks,
                        label: Text(
                          'Direct Tracks',
                          style: TextStyle(fontSize: 14),
                        ),
                        icon: Icon(Icons.alt_route),
                      ),
                    ],
                    selected: {_subscriberPlaybackMode},
                    onSelectionChanged: (isConnected || _isLoading)
                        ? null
                        : (Set<SubscriberPlaybackMode> newSelection) {
                            setState(
                              () =>
                                  _subscriberPlaybackMode = newSelection.first,
                            );
                          },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _subscriberPlaybackMode == SubscriberPlaybackMode.catalog
                        ? 'Catalog playback is the default. The player will subscribe to the catalog and pick media tracks automatically.'
                        : 'Direct track playback subscribes immediately to the configured video and audio track names.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 24),

                // Connect button
                FilledButton.icon(
                  onPressed: (isConnected || _isLoading) ? null : _connect,
                  icon: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          _clientRole == ClientRole.subscriber
                              ? Icons.play_arrow
                              : Icons.publish,
                        ),
                  label: Text(
                    _isLoading
                        ? 'Connecting...'
                        : _clientRole == ClientRole.subscriber
                        ? _subscriberPlaybackMode ==
                                  SubscriberPlaybackMode.catalog
                              ? 'Connect & Play Catalog'
                              : 'Connect & Subscribe'
                        : 'Connect & Publish',
                    style: const TextStyle(fontSize: 15),
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
