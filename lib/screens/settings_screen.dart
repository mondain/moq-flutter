import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Settings screen for app configuration
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: ListView(
        children: [
          // Server Presets section
          _buildSectionHeader(context, 'Server Presets'),
          ListTile(
            leading: const Icon(Icons.cloud),
            title: const Text('Local Development'),
            subtitle: const Text('localhost:8443'),
            onTap: () {
              // TODO: Apply preset
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Preset applied')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.cloud),
            title: const Text('moq-rs Server'),
            subtitle: const Text('moq.rs:4443'),
            onTap: () {
              // TODO: Apply preset
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Preset applied')),
              );
            },
          ),
          const Divider(),

          // Video Quality section
          _buildSectionHeader(context, 'Video Quality'),
          ListTile(
            leading: const Icon(Icons.high_quality),
            title: const Text('Resolution'),
            subtitle: const Text('720p (1280x720)'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              // TODO: Show resolution picker
            },
          ),
          ListTile(
            leading: const Icon(Icons.speed),
            title: const Text('Bitrate'),
            subtitle: const Text('2 Mbps'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              // TODO: Show bitrate picker
            },
          ),
          ListTile(
            leading: const Icon(Icons.timer),
            title: const Text('Frame Rate'),
            subtitle: const Text('30 fps'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              // TODO: Show frame rate picker
            },
          ),
          const Divider(),

          // About section
          _buildSectionHeader(context, 'About'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('MoQ Flutter Client'),
            subtitle: const Text('Version 1.0.0'),
          ),
          ListTile(
            leading: const Icon(Icons.description),
            title: const Text('Protocol'),
            subtitle: const Text('draft-ietf-moq-transport-14'),
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: const Text('Source Code'),
            subtitle: const Text('github.com/user/moq-flutter'),
            onTap: () {
              // TODO: Open GitHub URL
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}
