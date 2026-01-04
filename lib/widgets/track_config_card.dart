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
              isPublisher ? 'Track to Publish' : 'Tracks to Subscribe',
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
            if (isPublisher)
              // Publisher can configure track name
              TextField(
                controller: trackNameController,
                decoration: const InputDecoration(
                  labelText: 'Track Name',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                enabled: enabled,
              )
            else
              // Subscriber uses fixed track names (FB convention)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outline.withOpacity(0.5),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Will subscribe to:',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          Icons.videocam,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'video0',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Icon(
                          Icons.audiotrack,
                          size: 16,
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'audio0',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
