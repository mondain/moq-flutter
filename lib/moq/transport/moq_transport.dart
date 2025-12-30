import 'dart:async';
import 'dart:typed_data';

/// Event for incoming data stream chunk
class DataStreamChunk {
  /// The stream ID this chunk belongs to
  final int streamId;

  /// The data received
  final Uint8List data;

  /// Whether the stream has completed (FIN received)
  final bool isComplete;

  DataStreamChunk({
    required this.streamId,
    required this.data,
    this.isComplete = false,
  });
}

/// Abstract transport layer for MoQ over QUIC
abstract class MoQTransport {
  /// Connection state
  bool get isConnected;
  Stream<bool> get connectionStateStream;

  /// Connect to the MoQ endpoint
  Future<void> connect(String host, int port, {Map<String, String>? options});

  /// Disconnect from the MoQ endpoint
  Future<void> disconnect();

  /// Send data over the bidirectional control stream
  Future<void> send(Uint8List data);

  /// Send data on a unidirectional stream (single-shot, opens and closes stream)
  /// Used for simple data objects
  Future<void> sendData(Uint8List data);

  /// Open a persistent unidirectional stream for subgroup data
  /// Returns the stream ID
  Future<int> openStream();

  /// Write data to an open stream
  Future<void> streamWrite(int streamId, Uint8List data);

  /// Finish/close an open stream
  Future<void> streamFinish(int streamId);

  /// Stream of incoming control data (bidirectional control stream)
  Stream<Uint8List> get incomingData;

  /// Stream of incoming data stream chunks (unidirectional data streams)
  /// Each chunk contains the stream ID and data for that stream.
  /// Used for receiving SUBGROUP_HEADER and object data.
  Stream<DataStreamChunk> get incomingDataStreams;

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
