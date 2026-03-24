// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moq_flutter/moq/protocol/moq_messages.dart';
import 'package:moq_flutter/services/quic_transport.dart';
import 'package:moq_flutter/services/webtransport_quinn_transport.dart';

/// Integration tests that connect to a live relay and check datagram support
/// at both QUIC transport and WebTransport (H3) levels.
///
/// Requires the native Rust library to be built:
///   cd native/moq_quic && cargo build --release
///
/// Run with environment variables:
///   MOQ_DATAGRAM_TEST=1 flutter test test/moq/client/relay_datagram_test.dart
///
/// Optional env vars:
///   MOQ_RELAY_HOST     - relay hostname (default: moq-relay.red5.net)
///   MOQ_RELAY_PORT     - relay port (default: 4433)
///   MOQ_RELAY_PATH     - WebTransport path (default: /moq)
///   MOQ_RELAY_INSECURE - set to 1 for self-signed certs (default: 0)
///   MOQ_RELAY_VERSION  - 14 or 16 (default: 16)
///   MOQ_RELAY_ALPN     - ALPN override for QUIC test (default: h3)
void main() {
  final env = Platform.environment;
  final enabled = env['MOQ_DATAGRAM_TEST'] == '1';
  final host = env['MOQ_RELAY_HOST'] ?? 'moq-relay.red5.net';
  final port = int.tryParse(env['MOQ_RELAY_PORT'] ?? '') ?? 4433;
  final path = env['MOQ_RELAY_PATH'] ?? '/moq';
  final insecure = env['MOQ_RELAY_INSECURE'] == '1';
  final alpn = env['MOQ_RELAY_ALPN'] ?? 'h3';
  final versionStr = env['MOQ_RELAY_VERSION'] ?? '16';
  final targetVersion =
      versionStr == '14' ? MoQVersion.draft14 : MoQVersion.draft16;
  final versionLabel = versionStr == '14' ? 'draft-14' : 'draft-16';

  final skipMsg =
      enabled ? null : 'Set MOQ_DATAGRAM_TEST=1 to enable relay datagram check';

  group('Relay datagram support', () {
    test(
      'QUIC transport: $host:$port signals max_datagram_frame_size',
      () async {
        final transport = QuicTransport();

        if (!transport.isNativeLibraryLoaded) {
          transport.dispose();
          markTestSkipped('Native QUIC library not available');
          return;
        }

        try {
          // Connect at QUIC transport level with h3 ALPN
          // (relay requires WebTransport ALPN to accept connection)
          await transport.connect(host, port, options: {
            'insecure': '$insecure',
            'moq_version': '$targetVersion',
            'moq_alpn': alpn,
          });

          expect(transport.isConnected, isTrue,
              reason: 'Should connect to relay');

          final maxSize = transport.maxDatagramSize;

          print('');
          print('=== QUIC Transport Datagram Check ===');
          print('Relay: $host:$port (ALPN: $alpn)');
          print('max_datagram_frame_size: $maxSize bytes');
          print('RESULT: ${maxSize > 0 ? "SUPPORTED" : "NOT SUPPORTED"}');
          print('=====================================');
          print('');

          expect(maxSize, greaterThan(0),
              reason: 'Relay should signal max_datagram_frame_size > 0 '
                  'in QUIC transport parameters');
        } finally {
          transport.dispose();
        }
      },
      timeout: const Timeout(Duration(seconds: 15)),
      skip: skipMsg,
    );

    test(
      'WebTransport: $host:$port$path ($versionLabel) negotiates H3 datagrams',
      () async {
        final transport = WebTransportQuinnTransport(path: path);

        if (!transport.isNativeLibraryLoaded) {
          transport.dispose();
          markTestSkipped('Native QUIC library not available');
          return;
        }

        try {
          // Connect via WebTransport - this performs full H3 session setup:
          //   1. QUIC handshake (max_datagram_frame_size transport param)
          //   2. H3 SETTINGS exchange (SETTINGS_H3_DATAGRAM, SETTINGS_ENABLE_WEBTRANSPORT)
          //   3. HTTP CONNECT with WT-Available-Protocols header
          //   4. Server response with WT-Protocol header
          await transport.connect(host, port, options: {
            'insecure': '$insecure',
            'path': path,
            'moq_version': '$targetVersion',
          });

          expect(transport.isConnected, isTrue,
              reason: 'WebTransport session should establish');

          final maxSize = transport.maxDatagramSize;

          print('');
          print('=== WebTransport H3 Datagram Check ===');
          print('Relay: $host:$port$path ($versionLabel)');
          print('Max H3 datagram payload: $maxSize bytes');
          print(
              'RESULT: ${maxSize > 0 ? "H3 DATAGRAMS NEGOTIATED ($maxSize bytes)" : "H3 DATAGRAMS NOT NEGOTIATED"}');
          print('=======================================');
          print('');

          expect(maxSize, greaterThan(0),
              reason: 'Relay should negotiate SETTINGS_H3_DATAGRAM=1 '
                  'during H3 SETTINGS exchange');
        } finally {
          transport.dispose();
        }
      },
      timeout: const Timeout(Duration(seconds: 15)),
      skip: skipMsg,
    );
  });
}
