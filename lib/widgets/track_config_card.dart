import 'package:flutter/material.dart';

/// Card for track configuration (namespace and track name)
class TrackConfigCard extends StatelessWidget {
  final TextEditingController namespaceController;
  final TextEditingController trackNameController;
  final bool isPublisher;
  final bool enabled;

  const TrackConfigCard({
    super.key,
    required this.namespaceController,
    required this.trackNameController,
    this.isPublisher = false,
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
              isPublisher ? 'Track to Publish' : 'Track to Subscribe',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: namespaceController,
              decoration: const InputDecoration(
                labelText: 'Namespace',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              enabled: enabled,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: trackNameController,
              decoration: const InputDecoration(
                labelText: 'Track Name',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              enabled: enabled,
            ),
          ],
        ),
      ),
    );
  }
}
