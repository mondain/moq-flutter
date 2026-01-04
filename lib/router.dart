import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'screens/connection_screen.dart';
import 'screens/viewer_screen.dart';
import 'screens/publisher_screen.dart';
import 'screens/settings_screen.dart';

/// App router configuration using go_router
final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    // Connection/home screen
    GoRoute(
      path: '/',
      builder: (context, state) => const ConnectionScreen(),
    ),

    // Viewer screen (for subscribers)
    GoRoute(
      path: '/viewer',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>? ?? {};
        return ViewerScreen(
          namespace: extra['namespace'] as String? ?? '',
          trackName: extra['trackName'] as String? ?? '',
          videoTrackAlias: extra['videoTrackAlias'] as String? ?? '',
          audioTrackAlias: extra['audioTrackAlias'] as String? ?? '',
        );
      },
    ),

    // Publisher screen
    GoRoute(
      path: '/publisher',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>? ?? {};
        return PublisherScreen(
          namespace: extra['namespace'] as String? ?? '',
          trackName: extra['trackName'] as String? ?? '',
        );
      },
    ),

    // Settings screen
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsScreen(),
    ),
  ],

  // Error handling
  errorBuilder: (context, state) => Scaffold(
    appBar: AppBar(title: const Text('Error')),
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.red),
          const SizedBox(height: 16),
          Text('Page not found: ${state.uri}'),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => context.go('/'),
            child: const Text('Go Home'),
          ),
        ],
      ),
    ),
  ),
);
