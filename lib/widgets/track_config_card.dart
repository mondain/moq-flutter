import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/moq_providers.dart';

/// Card for track configuration (namespace and track name)
class TrackConfigCard extends ConsumerWidget {
  final TextEditingController namespaceController;
  final bool isPublisher;
  final bool enabled;
  final String? title;
  final bool showSubscriberTracks;
  final TextEditingController? publisherTrackNameController;
  final bool showPublisherTrackName;

  const TrackConfigCard({
    super.key,
    required this.namespaceController,
    this.isPublisher = false,
    this.enabled = true,
    this.title,
    this.showSubscriberTracks = true,
    this.publisherTrackNameController,
    this.showPublisherTrackName = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final packagingFormat = ref.watch(packagingFormatProvider);
    final videoTrackName = switch (packagingFormat) {
      PackagingFormat.cmaf => '1.m4s',
      PackagingFormat.loc => 'video',
      PackagingFormat.moqMi => ref.watch(videoTrackNameProvider),
    };
    final audioTrackName = switch (packagingFormat) {
      PackagingFormat.cmaf => '2.m4s',
      PackagingFormat.loc => 'audio',
      PackagingFormat.moqMi => ref.watch(audioTrackNameProvider),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title ??
                  (isPublisher ? 'Track to Publish' : 'Tracks to Subscribe'),
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
            if (isPublisher && showPublisherTrackName)
              // Publisher can configure track name
              TextField(
                controller: publisherTrackNameController,
                decoration: const InputDecoration(
                  labelText: 'Track Name',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                enabled: enabled,
              )
            else if (showSubscriberTracks)
              // Subscriber uses fixed track names (FB convention)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.outline.withOpacity(0.5),
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
                          videoTrackName,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(width: 16),
                        Icon(
                          Icons.audiotrack,
                          size: 16,
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          audioTrackName,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w500),
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
