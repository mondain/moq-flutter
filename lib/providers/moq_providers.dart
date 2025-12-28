import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import '../moq/client/moq_client.dart';
import '../moq/transport/moq_transport.dart';
import '../services/quic_transport.dart';

/// Logger provider
final loggerProvider = Provider<Logger>((ref) {
  return Logger(
    printer: PrettyPrinter(
      methodCount: 2,
      errorMethodCount: 8,
      lineLength: 120,
      colors: true,
      printEmojis: false,
      dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    ),
  );
});

/// QUIC Transport provider
final quicTransportProvider = Provider<MoQTransport>((ref) {
  final logger = ref.watch(loggerProvider);
  final transport = QuicTransport(logger: logger);

  ref.onDispose(() {
    transport.dispose();
  });

  return transport;
});

/// MoQ Client provider
final moqClientProvider = Provider<MoQClient>((ref) {
  final logger = ref.watch(loggerProvider);
  final transport = ref.watch(quicTransportProvider);

  final client = MoQClient(
    transport: transport,
    logger: logger,
  );

  ref.onDispose(() {
    client.dispose();
  });

  return client;
});

/// Connection state provider
final connectionStateProvider = StreamProvider<bool>((ref) {
  final client = ref.watch(moqClientProvider);
  return client.connectionStateStream;
});

/// Connected state provider (current value)
final isConnectedProvider = Provider<bool>((ref) {
  final client = ref.watch(moqClientProvider);
  return client.isConnected;
});
