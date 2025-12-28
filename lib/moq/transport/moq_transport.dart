import 'dart:async';
import 'dart:typed_data';

/// Abstract transport layer for MoQ over QUIC
abstract class MoQTransport {
  /// Connection state
  bool get isConnected;
  Stream<bool> get connectionStateStream;

  /// Connect to the MoQ endpoint
  Future<void> connect(String host, int port, {Map<String, String>? options});

  /// Disconnect from the MoQ endpoint
  Future<void> disconnect();

  /// Send data over the QUIC connection
  Future<void> send(Uint8List data);

  /// Stream of incoming data
  Stream<Uint8List> get incomingData;

  /// Get the underlying transport statistics
  MoQTransportStats get stats;

  void dispose();
}

/// Transport statistics
class MoQTransportStats {
  final int bytesSent;
  final int bytesReceived;
  final int packetsSent;
  final int packetsReceived;
  final DateTime? lastActivity;

  const MoQTransportStats({
    required this.bytesSent,
    required this.bytesReceived,
    required this.packetsSent,
    required this.packetsReceived,
    this.lastActivity,
  });

  MoQTransportStats copyWith({
    int? bytesSent,
    int? bytesReceived,
    int? packetsSent,
    int? packetsReceived,
    DateTime? lastActivity,
  }) {
    return MoQTransportStats(
      bytesSent: bytesSent ?? this.bytesSent,
      bytesReceived: bytesReceived ?? this.bytesReceived,
      packetsSent: packetsSent ?? this.packetsSent,
      packetsReceived: packetsReceived ?? this.packetsReceived,
      lastActivity: lastActivity ?? this.lastActivity,
    );
  }
}
