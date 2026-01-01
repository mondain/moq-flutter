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

/// Packaging format enum
enum PackagingFormat {
  loc('LOC', 'Raw codec data (H.264 NALUs, Opus frames)'),
  cmaf('CMAF', 'Fragmented MP4 (CARP-compliant)'),
  moqMi('MoQ-MI', 'Media Interop with extension headers');

  const PackagingFormat(this.label, this.description);
  final String label;
  final String description;
}

/// Video resolution enum with recommended bitrates (in kbps)
enum VideoResolution {
  r360p(640, 360, '360p', 800),
  r480p(854, 480, '480p', 1500),
  r540p(960, 540, '540p', 2000),
  r720p(1280, 720, '720p', 3000),
  r1080p(1920, 1080, '1080p', 6000),
  r1440p(2560, 1440, '1440p', 12000),
  r2160p(3840, 2160, '4K', 25000);

  const VideoResolution(this.width, this.height, this.label, this.bitrateKbps);
  final int width;
  final int height;
  final String label;
  final int bitrateKbps;

  String get description => '${width}x$height';
  int get bitrateBps => bitrateKbps * 1000;
  String get bitrateLabel => bitrateKbps >= 1000
      ? '${(bitrateKbps / 1000).toStringAsFixed(bitrateKbps % 1000 == 0 ? 0 : 1)} Mbps'
      : '$bitrateKbps kbps';
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

/// Packaging format provider (defaults to moq-mi)
class PackagingFormatNotifier extends Notifier<PackagingFormat> {
  @override
  PackagingFormat build() => PackagingFormat.moqMi;

  void setPackagingFormat(PackagingFormat format) => state = format;
}

final packagingFormatProvider = NotifierProvider<PackagingFormatNotifier, PackagingFormat>(
  PackagingFormatNotifier.new,
);

/// Video resolution provider (defaults to 720p)
class VideoResolutionNotifier extends Notifier<VideoResolution> {
  @override
  VideoResolution build() => VideoResolution.r720p;

  void setResolution(VideoResolution resolution) => state = resolution;
}

final videoResolutionProvider = NotifierProvider<VideoResolutionNotifier, VideoResolution>(
  VideoResolutionNotifier.new,
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
