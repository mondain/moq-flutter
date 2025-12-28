import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/moq_providers.dart';

/// Main home screen for the MoQ application
class MoQHomeScreen extends ConsumerStatefulWidget {
  const MoQHomeScreen({super.key});

  @override
  ConsumerState<MoQHomeScreen> createState() => _MoQHomeScreenState();
}

class _MoQHomeScreenState extends ConsumerState<MoQHomeScreen> {
  final _hostController = TextEditingController(text: 'localhost');
  final _portController = TextEditingController(text: '4443');
  final _namespaceController = TextEditingController(text: 'demo');
  final _trackNameController = TextEditingController(text: 'video');
  bool _isLoading = false;

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _namespaceController.dispose();
    _trackNameController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() => _isLoading = true);

    try {
      final client = ref.read(moqClientProvider);
      final host = _hostController.text;
      final port = int.tryParse(_portController.text) ?? 4443;

      await client.connect(host, port);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Connected successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection failed: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _disconnect() async {
    try {
      final client = ref.read(moqClientProvider);
      await client.disconnect();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Disconnected')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Disconnect failed: $e')),
        );
      }
    }
  }

  Future<void> _subscribe() async {
    try {
      final client = ref.read(moqClientProvider);
      final namespace = _namespaceController.text;
      final trackName = _trackNameController.text;

      // Convert strings to bytes for the MoQ protocol
      final namespaceBytes = [Uint8List.fromList(namespace.codeUnits)];
      final trackNameBytes = Uint8List.fromList(trackName.codeUnits);

      final result = await client.subscribe(
        namespaceBytes,
        trackNameBytes,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Subscribed to $namespace:$trackName '
                  '(alias: ${result.trackAlias})')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Subscribe failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = ref.watch(isConnectedProvider);

    ref.listen<AsyncValue<bool>>(
      connectionStateProvider,
      (_, state) {
        if (state.hasValue && !state.value! && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Connection lost')),
          );
        }
      },
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('MoQ Flutter Client'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              // TODO: Open settings
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Connection Status',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          isConnected ? Icons.cloud_done : Icons.cloud_off,
                          color: isConnected ? Colors.green : Colors.red,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          isConnected ? 'Connected' : 'Disconnected',
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ],
                    ),
                    // TODO: Add statistics display when available
                    // if (isConnected) ...[
                    //   const SizedBox(height: 16),
                    //   Text(
                    //     'Statistics',
                    //     style: Theme.of(context).textTheme.titleSmall,
                    //   ),
                    // ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _hostController,
              decoration: const InputDecoration(
                labelText: 'Host',
                border: OutlineInputBorder(),
              ),
              enabled: !isConnected && !_isLoading,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _portController,
              decoration: const InputDecoration(
                labelText: 'Port',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              enabled: !isConnected && !_isLoading,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: (isConnected || _isLoading) ? null : _connect,
              child: _isLoading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Connect'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: isConnected ? _disconnect : null,
              child: const Text('Disconnect'),
            ),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            Text(
              'Subscribe to Track',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _namespaceController,
              decoration: const InputDecoration(
                labelText: 'Namespace',
                border: OutlineInputBorder(),
              ),
              enabled: isConnected,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _trackNameController,
              decoration: const InputDecoration(
                labelText: 'Track Name',
                border: OutlineInputBorder(),
              ),
              enabled: isConnected,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: isConnected ? _subscribe : null,
              child: const Text('Subscribe'),
            ),
          ],
        ),
      ),
    );
  }
}
