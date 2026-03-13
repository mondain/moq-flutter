import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moq_flutter/moq/client/moq_client.dart';
import 'package:moq_flutter/moq/protocol/moq_messages.dart';
import 'package:moq_flutter/services/quic_transport.dart';

void main() {
  final config = _LiveInteropConfig.fromEnvironment();

  group('Live draft-16 interop', () {
    test(
      'connects to ${config.host}:${config.port} with ${config.versionLabel}',
      () async {
        if (!config.enabled) {
          return;
        }

        final transport = QuicTransport();
        final client = MoQClient(transport: transport);

        try {
          await client.connect(
            config.host,
            config.port,
            targetVersion: config.targetVersion,
            options: {
              'insecure': '${config.insecure}',
              if (config.alpn != null) 'moq_alpn': config.alpn!,
            },
          );

          expect(client.isConnected, isTrue);
          expect(
            client.selectedVersion,
            equals(config.expectedSelectedVersion),
          );
        } finally {
          await client.disconnect();
          client.dispose();
          transport.dispose();
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
      skip: config.skipReason,
    );

    test(
      'can optionally subscribe to a configured track',
      () async {
        if (!config.enabled) {
          return;
        }
        if (config.namespaceParts == null || config.trackName == null) {
          return;
        }

        final transport = QuicTransport();
        final client = MoQClient(transport: transport);

        try {
          await client.connect(
            config.host,
            config.port,
            targetVersion: config.targetVersion,
            options: {
              'insecure': '${config.insecure}',
              if (config.alpn != null) 'moq_alpn': config.alpn!,
            },
          );

          final result = await client.subscribe(
            config.namespaceParts!
                .map((part) => Uint8List.fromList(part.codeUnits))
                .toList(),
            Uint8List.fromList(config.trackName!.codeUnits),
          );

          expect(result.trackAlias, isNotNull);
        } finally {
          await client.disconnect();
          client.dispose();
          transport.dispose();
        }
      },
      timeout: const Timeout(Duration(seconds: 45)),
      skip: config.skipReason ?? config.subscribeSkipReason,
    );

    test(
      'can optionally announce a namespace for publish interop',
      () async {
        if (!config.enabled) {
          return;
        }
        if (config.publishNamespaceParts == null) {
          return;
        }

        final transport = QuicTransport();
        final client = MoQClient(transport: transport);

        try {
          await client.connect(
            config.host,
            config.port,
            targetVersion: config.targetVersion,
            options: {
              'insecure': '${config.insecure}',
              if (config.alpn != null) 'moq_alpn': config.alpn!,
            },
          );

          final requestId = await client.announceNamespace(
            config.publishNamespaceParts!
                .map((part) => Uint8List.fromList(part.codeUnits))
                .toList(),
          );

          expect(requestId, isNotNull);
        } finally {
          await client.disconnect();
          client.dispose();
          transport.dispose();
        }
      },
      timeout: const Timeout(Duration(seconds: 45)),
      skip: config.skipReason ?? config.publishSkipReason,
    );
  });
}

class _LiveInteropConfig {
  final bool enabled;
  final String host;
  final int port;
  final bool insecure;
  final String? alpn;
  final int targetVersion;
  final List<String>? namespaceParts;
  final String? trackName;
  final List<String>? publishNamespaceParts;

  const _LiveInteropConfig({
    required this.enabled,
    required this.host,
    required this.port,
    required this.insecure,
    required this.alpn,
    required this.targetVersion,
    required this.namespaceParts,
    required this.trackName,
    required this.publishNamespaceParts,
  });

  factory _LiveInteropConfig.fromEnvironment() {
    final env = Platform.environment;
    final host = env['MOQ_LIVE_HOST'] ?? 'fb.mvfst.net';
    final insecureEnv = env['MOQ_LIVE_INSECURE'];
    final targetVersion = _parseVersion(env['MOQ_LIVE_VERSION']);
    return _LiveInteropConfig(
      enabled: env['MOQ_LIVE_INTEROP'] == '1',
      host: host,
      port: int.tryParse(env['MOQ_LIVE_PORT'] ?? '') ?? 9448,
      insecure: insecureEnv == null
          ? host == 'fb.mvfst.net'
          : insecureEnv == '1',
      alpn: _optionalEnv(env['MOQ_LIVE_ALPN']),
      targetVersion: targetVersion,
      namespaceParts: _splitPath(env['MOQ_LIVE_NAMESPACE']),
      trackName: env['MOQ_LIVE_TRACK'],
      publishNamespaceParts: _splitPath(env['MOQ_LIVE_PUBLISH_NAMESPACE']),
    );
  }

  String get versionLabel =>
      targetVersion == MoQVersion.draft16 ? 'draft-16' : 'draft-14';

  int get expectedSelectedVersion => targetVersion;

  String? get skipReason => enabled
      ? null
      : 'Set MOQ_LIVE_INTEROP=1 to enable live interop tests against fb.mvfst.net:9448.';

  String? get subscribeSkipReason =>
      'Set MOQ_LIVE_NAMESPACE and MOQ_LIVE_TRACK to enable the live subscribe test.';

  String? get publishSkipReason =>
      'Set MOQ_LIVE_PUBLISH_NAMESPACE to enable the live publish namespace test.';

  static List<String>? _splitPath(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return value
        .split('/')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
  }

  static String? _optionalEnv(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return value.trim();
  }

  static int _parseVersion(String? value) {
    switch (value?.trim()) {
      case '14':
      case 'draft14':
      case 'draft-14':
        return MoQVersion.draft14;
      case '16':
      case 'draft16':
      case 'draft-16':
      case null:
      case '':
        return MoQVersion.draft16;
      default:
        throw ArgumentError(
          'Unsupported MOQ_LIVE_VERSION=$value. Use 14 or 16.',
        );
    }
  }
}
