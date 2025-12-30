import 'package:flutter/material.dart';
import '../providers/moq_providers.dart';

/// Card for server configuration (host/port or WebTransport URL)
class ServerConfigCard extends StatelessWidget {
  final TextEditingController hostController;
  final TextEditingController portController;
  final TextEditingController urlController;
  final TransportType transportType;
  final bool insecureMode;
  final ValueChanged<bool> onInsecureModeChanged;
  final bool enabled;

  const ServerConfigCard({
    super.key,
    required this.hostController,
    required this.portController,
    required this.urlController,
    required this.transportType,
    required this.insecureMode,
    required this.onInsecureModeChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Server',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (transportType == TransportType.moqt) ...[
              TextField(
                controller: hostController,
                decoration: const InputDecoration(
                  labelText: 'Host',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                enabled: enabled,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: portController,
                decoration: const InputDecoration(
                  labelText: 'Port',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.number,
                enabled: enabled,
              ),
            ] else ...[
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: 'WebTransport URL',
                  border: OutlineInputBorder(),
                  hintText: 'https://example.com:4433/moq',
                  isDense: true,
                ),
                enabled: enabled,
              ),
            ],
            const SizedBox(height: 8),
            CheckboxListTile(
              title: const Text('Skip Certificate Verification'),
              subtitle: const Text(
                'For self-signed certificates (insecure)',
                style: TextStyle(fontSize: 11, color: Colors.orange),
              ),
              value: insecureMode,
              onChanged: enabled ? (value) => onInsecureModeChanged(value ?? false) : null,
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ],
        ),
      ),
    );
  }
}
