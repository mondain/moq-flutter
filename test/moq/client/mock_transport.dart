import 'dart:async';
import 'dart:typed_data';
import 'package:moq_flutter/moq/transport/moq_transport.dart';

/// Mock transport for testing MoQ client without a real QUIC connection
class MockMoQTransport implements MoQTransport {
  bool _isConnected = false;
  final _connectionStateController = StreamController<bool>.broadcast();
  final _incomingDataController = StreamController<Uint8List>.broadcast();
  final _incomingDataStreamsController = StreamController<DataStreamChunk>.broadcast();

  // Track sent data for assertions
  final List<Uint8List> sentControlMessages = [];
  final Map<int, List<Uint8List>> sentStreamData = {};

  // Stream ID counter
  int _nextStreamId = 1;

  // Stats
  int _bytesSent = 0;
  int _bytesReceived = 0;

  // Callbacks for custom response handling
  void Function(Uint8List data)? onControlMessageSent;

  @override
  bool get isConnected => _isConnected;

  @override
  Stream<bool> get connectionStateStream => _connectionStateController.stream;

  @override
  Stream<Uint8List> get incomingData => _incomingDataController.stream;

  @override
  Stream<DataStreamChunk> get incomingDataStreams => _incomingDataStreamsController.stream;

  @override
  MoQTransportStats get stats => MoQTransportStats(
        bytesSent: _bytesSent,
        bytesReceived: _bytesReceived,
        packetsSent: sentControlMessages.length,
        packetsReceived: 0,
        lastActivity: DateTime.now(),
      );

  @override
  Future<void> connect(String host, int port, {Map<String, String>? options}) async {
    _isConnected = true;
    _connectionStateController.add(true);
  }

  @override
  Future<void> disconnect() async {
    _isConnected = false;
    _connectionStateController.add(false);
  }

  @override
  Future<void> send(Uint8List data) async {
    sentControlMessages.add(data);
    _bytesSent += data.length;
    onControlMessageSent?.call(data);
  }

  @override
  Future<void> sendData(Uint8List data) async {
    // Single-shot unidirectional stream
    final streamId = _nextStreamId++;
    sentStreamData[streamId] = [data];
    _bytesSent += data.length;
  }

  @override
  Future<int> openStream() async {
    final streamId = _nextStreamId++;
    sentStreamData[streamId] = [];
    return streamId;
  }

  @override
  Future<void> streamWrite(int streamId, Uint8List data) async {
    sentStreamData[streamId] ??= [];
    sentStreamData[streamId]!.add(data);
    _bytesSent += data.length;
  }

  @override
  Future<void> streamFinish(int streamId) async {
    // Mark stream as finished (no-op for mock)
  }

  @override
  void dispose() {
    _connectionStateController.close();
    _incomingDataController.close();
    _incomingDataStreamsController.close();
  }

  // Test helper methods

  /// Simulate receiving control data from server
  void simulateIncomingControlData(Uint8List data) {
    _bytesReceived += data.length;
    _incomingDataController.add(data);
  }

  /// Simulate receiving data stream chunk
  void simulateIncomingDataStream(int streamId, Uint8List data, {bool isComplete = false}) {
    _bytesReceived += data.length;
    _incomingDataStreamsController.add(DataStreamChunk(
      streamId: streamId,
      data: data,
      isComplete: isComplete,
    ));
  }

  /// Clear sent messages (for test isolation)
  void clearSentMessages() {
    sentControlMessages.clear();
    sentStreamData.clear();
    _bytesSent = 0;
    _bytesReceived = 0;
  }

  /// Get the last sent control message
  Uint8List? get lastSentControlMessage =>
      sentControlMessages.isNotEmpty ? sentControlMessages.last : null;
}
