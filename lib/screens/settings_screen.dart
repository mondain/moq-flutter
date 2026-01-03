import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/moq_providers.dart';

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
          _buildSectionHeader(context, 'Video Resolution'),
          ...VideoResolution.values.map((resolution) {
            final currentResolution = ref.watch(videoResolutionProvider);
            final isSelected = currentResolution == resolution;
            return RadioListTile<VideoResolution>(
              value: resolution,
              groupValue: currentResolution,
              onChanged: (value) {
                if (value != null) {
                  ref.read(videoResolutionProvider.notifier).setResolution(value);
                }
              },
              title: Text(resolution.label),
              subtitle: Text('${resolution.description} @ ${resolution.bitrateLabel}'),
              secondary: Icon(
                isSelected ? Icons.check_circle : Icons.circle_outlined,
                color: isSelected ? Theme.of(context).colorScheme.primary : null,
              ),
            );
          }),
          const Divider(),

          // Packaging Format section
          _buildSectionHeader(context, 'Packaging Format'),
          ...PackagingFormat.values.map((format) {
            final currentFormat = ref.watch(packagingFormatProvider);
            final isSelected = currentFormat == format;
            return RadioListTile<PackagingFormat>(
              value: format,
              groupValue: currentFormat,
              onChanged: (value) {
                if (value != null) {
                  ref.read(packagingFormatProvider.notifier).setPackagingFormat(value);
                }
              },
              title: Text(format.label),
              subtitle: Text(format.description),
              secondary: Icon(
                isSelected ? Icons.check_circle : Icons.circle_outlined,
                color: isSelected ? Theme.of(context).colorScheme.primary : null,
              ),
            );
          }),
          const Divider(),

          // Appearance section
          _buildSectionHeader(context, 'Appearance'),
          ...ThemeMode.values.map((mode) {
            final currentMode = ref.watch(themeModeProvider);
            final isSelected = currentMode == mode;
            return RadioListTile<ThemeMode>(
              value: mode,
              groupValue: currentMode,
              onChanged: (value) {
                if (value != null) {
                  ref.read(themeModeProvider.notifier).setThemeMode(value);
                }
              },
              title: Text(_themeModeLabel(mode)),
              subtitle: Text(_themeModeDescription(mode)),
              secondary: Icon(
                _themeModeIcon(mode),
                color: isSelected ? Theme.of(context).colorScheme.primary : null,
              ),
            );
          }),
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

  String _themeModeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'System';
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.dark:
        return 'Dark';
    }
  }

  String _themeModeDescription(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'Follow device settings';
      case ThemeMode.light:
        return 'Always use light theme';
      case ThemeMode.dark:
        return 'Always use dark theme';
    }
  }

  IconData _themeModeIcon(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return Icons.brightness_auto;
      case ThemeMode.light:
        return Icons.light_mode;
      case ThemeMode.dark:
        return Icons.dark_mode;
    }
  }
}
