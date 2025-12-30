import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import '../moq/client/moq_client.dart';
import '../moq/transport/moq_transport.dart';
import '../services/quic_transport.dart';
import '../services/webtransport_quinn_transport.dart';

/// Transport type enum
enum TransportType {
  moqt,
  webtransport,
}

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

/// Transport type provider (defaults to moqt)
class TransportTypeNotifier extends Notifier<TransportType> {
  @override
  TransportType build() => TransportType.moqt;

  void setTransportType(TransportType type) => state = type;
}

final transportTypeProvider = NotifierProvider<TransportTypeNotifier, TransportType>(
  TransportTypeNotifier.new,
);

/// QUIC Transport provider
final quicTransportProvider = Provider<MoQTransport>((ref) {
  final logger = ref.watch(loggerProvider);
  final transport = QuicTransport(logger: logger);

  ref.onDispose(() {
    transport.dispose();
  });

  return transport;
});

/// WebTransport provider
final webTransportProvider = Provider<MoQTransport>((ref) {
  final logger = ref.watch(loggerProvider);
  final transport = WebTransportQuinnTransport(logger: logger);

  ref.onDispose(() {
    transport.dispose();
  });

  return transport;
});

/// Current transport provider (selects based on transportTypeProvider)
final currentTransportProvider = Provider<MoQTransport>((ref) {
  final transportType = ref.watch(transportTypeProvider);
  switch (transportType) {
    case TransportType.moqt:
      return ref.watch(quicTransportProvider);
    case TransportType.webtransport:
      return ref.watch(webTransportProvider);
  }
});

/// MoQ Client provider
final moqClientProvider = Provider<MoQClient>((ref) {
  final logger = ref.watch(loggerProvider);
  final transport = ref.watch(currentTransportProvider);

  final client = MoQClient(
    transport: transport,
    logger: logger,
  );

  ref.onDispose(() {
    client.dispose();
  });

  return client;
});

/// Connection state provider (stream-based for reactive updates)
final connectionStateProvider = StreamProvider<bool>((ref) {
  final client = ref.watch(moqClientProvider);
  return client.connectionStateStream;
});

/// Connected state provider (derives from stream for proper updates)
final isConnectedProvider = Provider<bool>((ref) {
  // Watch the stream provider to get reactive updates
  final asyncState = ref.watch(connectionStateProvider);
  // Also check the client's current state as a fallback
  final client = ref.watch(moqClientProvider);

  // Use stream value if available, otherwise use client's current state
  return asyncState.when(
    data: (isConnected) => isConnected,
    loading: () => client.isConnected,
    error: (_, _) => client.isConnected,
  );
});
