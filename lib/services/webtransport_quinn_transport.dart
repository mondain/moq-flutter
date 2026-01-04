import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:logger/logger.dart';
import '../moq/transport/moq_transport.dart';

// FFI type aliases
typedef NativeInt32 = Int32;
typedef NativeInt64 = Int64;
typedef NativeUint16 = Uint16;
typedef NativeUint64 = Uint64;
typedef NativeIntPtr = IntPtr;

/// WebTransport over QUIC transport using FFI bindings to web-transport-quinn (Rust)
///
/// This implements WebTransport as specified in draft-ietf-moq-transport-14
/// which supports both raw QUIC connections and WebTransport sessions.
class WebTransportQuinnTransport extends MoQTransport {
  final Logger _logger;
  final String _path; // URL path for WebTransport (e.g., "/moq")

  final _connectionStateController = StreamController<bool>.broadcast();
  final _incomingDataController = StreamController<Uint8List>.broadcast();
  final _incomingDataStreamController = StreamController<DataStreamChunk>.broadcast();
  final _incomingDatagramController = StreamController<Uint8List>.broadcast();

  bool _isConnected = false;
  int _sessionId = -1;
  DynamicLibrary? _nativeLib;
  MoQTransportStats _stats = const MoQTransportStats(
    bytesSent: 0,
    bytesReceived: 0,
    packetsSent: 0,
    packetsReceived: 0,
  );

  // Native function signatures (nullable to support stub mode)
  _InitFunc? _moqWtInit;
  _ConnectFunc? _moqWtConnect;
  _SendFunc? _moqWtSend;
  _RecvFunc? _moqWtRecv;
  _RecvDataFunc? _moqWtRecvData;
  _CloseFunc? _moqWtClose;
  _CleanupFunc? _moqWtCleanup;
  _GetLastErrorFunc? _moqWtGetLastError;
  _OpenUniStreamFunc? _moqWtOpenUniStream;
  _StreamWriteFunc? _moqWtStreamWrite;
  _StreamFinishFunc? _moqWtStreamFinish;

  Timer? _pollTimer;
  bool _nativeLibraryLoaded = false;

  WebTransportQuinnTransport({Logger? logger, String path = '/moq'})
      : _logger = logger ?? Logger(),
        _path = path {
    _loadNativeLibrary();
  }

  void _loadNativeLibrary() {
    try {
      _nativeLib = _openNativeLibrary();

      // Load native functions
      _moqWtInit = _nativeLib!
          .lookup<NativeFunction<Void Function()>>('moq_webtransport_init')
          .asFunction();
      _moqWtConnect = _nativeLib!
          .lookup<NativeFunction<NativeInt32 Function(Pointer<Int8>, NativeUint16, Pointer<Int8>, Uint8, Pointer<NativeUint64>)>>(
              'moq_webtransport_connect')
          .asFunction();
      _moqWtSend = _nativeLib!
          .lookup<NativeFunction<NativeInt64 Function(NativeUint64, Pointer<Uint8>, NativeIntPtr)>>(
              'moq_webtransport_send')
          .asFunction();
      _moqWtRecv = _nativeLib!
          .lookup<NativeFunction<NativeInt64 Function(NativeUint64, Pointer<Uint8>, NativeIntPtr)>>(
              'moq_webtransport_recv')
          .asFunction();
      _moqWtRecvData = _nativeLib!
          .lookup<NativeFunction<NativeInt64 Function(NativeUint64, Pointer<NativeUint64>, Pointer<Uint8>, NativeIntPtr, Pointer<NativeInt32>)>>(
              'moq_webtransport_recv_data')
          .asFunction();
      _moqWtClose = _nativeLib!
          .lookup<NativeFunction<NativeInt32 Function(NativeUint64)>>('moq_webtransport_close')
          .asFunction();
      _moqWtCleanup = _nativeLib!
          .lookup<NativeFunction<Void Function()>>('moq_webtransport_cleanup')
          .asFunction();
      _moqWtGetLastError = _nativeLib!
          .lookup<NativeFunction<NativeInt32 Function(Pointer<Uint8>, NativeIntPtr)>>('moq_webtransport_get_last_error')
          .asFunction();
      _moqWtOpenUniStream = _nativeLib!
          .lookup<NativeFunction<NativeInt32 Function(NativeUint64, Pointer<NativeUint64>)>>('moq_webtransport_open_uni_stream')
          .asFunction();
      _moqWtStreamWrite = _nativeLib!
          .lookup<NativeFunction<NativeInt64 Function(NativeUint64, NativeUint64, Pointer<Uint8>, NativeIntPtr)>>('moq_webtransport_stream_write')
          .asFunction();
      _moqWtStreamFinish = _nativeLib!
          .lookup<NativeFunction<NativeInt32 Function(NativeUint64, NativeUint64)>>('moq_webtransport_stream_finish')
          .asFunction();

      // Initialize the native library
      _moqWtInit!();

      _nativeLibraryLoaded = true;
      _logger.i('Native WebTransport library loaded successfully');
    } catch (e) {
      _logger.e('Failed to load native WebTransport library: $e');
      _logger.w('WebTransport will not be available - running in stub mode');
      _nativeLibraryLoaded = false;
    }
  }

  DynamicLibrary _openNativeLibrary() {
    if (Platform.isLinux || Platform.isAndroid) {
      final paths = [
        'libmoq_quic.so',
        '../native/moq_quic/target/release/libmoq_quic.so',
        'native/moq_quic/target/release/libmoq_quic.so',
        '/usr/local/lib/libmoq_quic.so',
      ];

      for (final path in paths) {
        try {
          _logger.d('Trying to load library from: $path');
          return DynamicLibrary.open(path);
        } catch (e) {
          _logger.d('Failed to load from $path: $e');
        }
      }

      throw Exception('Could not find libmoq_quic.so in any of the expected paths');
    } else if (Platform.isIOS) {
      return DynamicLibrary.process();
    } else if (Platform.isMacOS) {
      final paths = [
        'libmoq_quic.dylib',
        '../native/moq_quic/target/release/libmoq_quic.dylib',
        'native/moq_quic/target/release/libmoq_quic.dylib',
        '../Frameworks/libmoq_quic.dylib',
        '@rpath/libmoq_quic.dylib',
      ];

      for (final path in paths) {
        try {
          _logger.d('Trying to load library from: $path');
          return DynamicLibrary.open(path);
        } catch (e) {
          _logger.d('Failed to load from $path: $e');
        }
      }

      throw Exception('Could not find libmoq_quic.dylib in any of the expected paths');
    } else if (Platform.isWindows) {
      final paths = [
        'moq_quic.dll',
        '../native/moq_quic/target/release/moq_quic.dll',
        'native/moq_quic/target/release/moq_quic.dll',
      ];

      for (final path in paths) {
        try {
          _logger.d('Trying to load library from: $path');
          return DynamicLibrary.open(path);
        } catch (e) {
          _logger.d('Failed to load from $path: $e');
        }
      }

      throw Exception('Could not find moq_quic.dll in any of the expected paths');
    } else {
      throw UnsupportedError('Platform not supported: ${Platform.operatingSystem}');
    }
  }

  @override
  bool get isConnected => _isConnected && _sessionId >= 0;

  @override
  Stream<bool> get connectionStateStream => _connectionStateController.stream;

  @override
  Future<void> connect(String host, int port, {Map<String, String>? options}) async {
    if (_isConnected) {
      _logger.w('Already connected');
      return;
    }

    if (!_nativeLibraryLoaded) {
      _logger.e('Cannot connect: Native WebTransport library is not available');
      _logger.w('Please build the native Rust library first');
      _connectionStateController.add(false);
      throw StateError('Native WebTransport library not available');
    }

    try {
      // Get path from options, fall back to constructor default
      final path = options?['path'] ?? _path;
      _logger.i('Connecting to $host:$port via WebTransport ($path)');

      // Check for insecure flag in options
      final insecureValue = options?['insecure'];
      final insecure = (insecureValue == 'true' || insecureValue?.toString() == 'true') ? 1 : 0;
      if (insecure != 0) {
        _logger.w('Certificate verification DISABLED (insecure mode)');
      }

      // Convert host and path to native strings
      final hostPtr = host.toNativeUtf8();
      final pathPtr = path.toNativeUtf8();
      final sessionIdPtr = calloc<Uint64>();

      final result = _moqWtConnect!(
          hostPtr.cast<Int8>(), port.toUnsigned(16), pathPtr.cast<Int8>(), insecure, sessionIdPtr);

      calloc.free(hostPtr);
      calloc.free(pathPtr);

      if (result != 0) {
        calloc.free(sessionIdPtr);
        // Try to get the detailed error message
        String errorMsg = 'WebTransport connection failed with error code: $result';
        if (_moqWtGetLastError != null) {
          final errorBuffer = calloc<Uint8>(512);
          final errorLen = _moqWtGetLastError!(errorBuffer, 512);
          if (errorLen > 0) {
            final errorBytes = errorBuffer.asTypedList(errorLen);
            errorMsg = '$errorMsg: ${String.fromCharCodes(errorBytes)}';
          }
          calloc.free(errorBuffer);
        }
        throw Exception(errorMsg);
      }

      _sessionId = sessionIdPtr.value;
      calloc.free(sessionIdPtr);

      _isConnected = true;
      _connectionStateController.add(true);
      _logger.i('WebTransport session established (ID: $_sessionId)');

      // Start polling for incoming data
      _startReceiving();
    } catch (e) {
      _logger.e('Failed to connect: $e');
      _connectionStateController.add(false);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    if (!_isConnected) return;

    _logger.i('Disconnecting WebTransport');

    _stopReceiving();

    if (_sessionId >= 0 && _nativeLibraryLoaded && _moqWtClose != null) {
      _moqWtClose!(_sessionId);
      _sessionId = -1;
    }

    _isConnected = false;
    _connectionStateController.add(false);
    _logger.i('WebTransport closed');
  }

  @override
  Future<void> send(Uint8List data) async {
    if (!isConnected) {
      throw StateError('Not connected');
    }

    if (!_nativeLibraryLoaded || _moqWtSend == null) {
      _logger.e('Cannot send: Native WebTransport library is not available');
      throw StateError('Native WebTransport library not available');
    }

    try {
      // Control messages are sent directly on the bidirectional control stream
      // without any stream type prefix. The Rust native library handles the
      // control stream management.
      // See draft-ietf-moq-transport-14 section 6.1
      final dataPtr = calloc<Uint8>(data.length);
      final nativeData = dataPtr.asTypedList(data.length);
      nativeData.setAll(0, data);

      final sent = _moqWtSend!(_sessionId, dataPtr, data.length);

      calloc.free(dataPtr);

      final sentInt = sent.toInt();
      if (sentInt < 0) {
        throw Exception('Send failed with error code: $sentInt');
      }

      _stats = _stats.copyWith(
        bytesSent: _stats.bytesSent + sentInt,
        packetsSent: _stats.packetsSent + 1,
        lastActivity: DateTime.now(),
      );

      _logger.d('Sent $sentInt bytes via WebTransport');
    } catch (e) {
      _logger.e('Send failed: $e');
      rethrow;
    }
  }

  @override
  Future<void> sendData(Uint8List data) async {
    // WebTransport data streams are not yet implemented
    // For now, fall back to control stream send
    _logger.w('sendData not yet implemented for WebTransport, using control stream');
    return send(data);
  }

  @override
  Future<int> openStream() async {
    if (!isConnected) {
      throw StateError('Not connected');
    }

    if (!_nativeLibraryLoaded || _moqWtOpenUniStream == null) {
      _logger.e('Cannot open stream: Native WebTransport library is not available');
      throw StateError('Native WebTransport library not available');
    }

    final streamIdPtr = calloc<Uint64>();
    final result = _moqWtOpenUniStream!(_sessionId, streamIdPtr);

    if (result != 0) {
      calloc.free(streamIdPtr);
      throw Exception('Failed to open unidirectional stream: error code $result');
    }

    final streamId = streamIdPtr.value;
    calloc.free(streamIdPtr);

    _logger.d('Opened unidirectional stream $streamId');
    return streamId;
  }

  @override
  Future<void> streamWrite(int streamId, Uint8List data) async {
    if (!isConnected) {
      throw StateError('Not connected');
    }

    if (!_nativeLibraryLoaded || _moqWtStreamWrite == null) {
      _logger.e('Cannot write to stream: Native WebTransport library is not available');
      throw StateError('Native WebTransport library not available');
    }

    final dataPtr = calloc<Uint8>(data.length);
    final nativeData = dataPtr.asTypedList(data.length);
    nativeData.setAll(0, data);

    final result = _moqWtStreamWrite!(_sessionId, streamId, dataPtr, data.length);

    calloc.free(dataPtr);

    if (result < 0) {
      throw Exception('Failed to write to stream $streamId: error code $result');
    }

    _stats = _stats.copyWith(
      bytesSent: _stats.bytesSent + result,
      packetsSent: _stats.packetsSent + 1,
      lastActivity: DateTime.now(),
    );

    _logger.d('Wrote $result bytes to stream $streamId');
  }

  @override
  Future<void> streamFinish(int streamId) async {
    if (!isConnected) {
      throw StateError('Not connected');
    }

    if (!_nativeLibraryLoaded || _moqWtStreamFinish == null) {
      _logger.e('Cannot finish stream: Native WebTransport library is not available');
      throw StateError('Native WebTransport library not available');
    }

    final result = _moqWtStreamFinish!(_sessionId, streamId);

    if (result != 0) {
      throw Exception('Failed to finish stream $streamId: error code $result');
    }

    _logger.d('Finished stream $streamId');
  }

  @override
  Stream<Uint8List> get incomingData => _incomingDataController.stream;

  @override
  Stream<DataStreamChunk> get incomingDataStreams => _incomingDataStreamController.stream;

  @override
  Future<void> sendDatagram(Uint8List data) async {
    // WebTransport datagrams not yet implemented
    _logger.w('sendDatagram not yet implemented for WebTransport');
    throw UnimplementedError('WebTransport datagrams not yet implemented');
  }

  @override
  Stream<Uint8List> get incomingDatagrams => _incomingDatagramController.stream;

  @override
  MoQTransportStats get stats => _stats;

  void _startReceiving() {
    // Poll for incoming data every 10ms
    _pollTimer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (!isConnected) return;

      // Poll control stream (bidirectional)
      _pollControlStream();

      // Poll data streams (incoming unidirectional)
      _pollDataStreams();
    });
  }

  void _pollControlStream() {
    if (_moqWtRecv == null) {
      return;
    }

    try {
      // Buffer to receive data (max 4KB per poll)
      final buffer = calloc<Uint8>(4096);
      final received = _moqWtRecv!(_sessionId, buffer, 4096);

      if (received > 0) {
        // Copy received data
        final data = Uint8List(received.toInt());
        final nativeData = buffer.asTypedList(received.toInt());
        data.setAll(0, nativeData);

        _stats = _stats.copyWith(
          bytesReceived: _stats.bytesReceived + received.toInt(),
          packetsReceived: _stats.packetsReceived + 1,
          lastActivity: DateTime.now(),
        );

        // For bidirectional control stream, there is NO stream type prefix.
        // Control messages are sent directly (raw wire format).
        _logger.d('Received $received bytes on WebTransport control stream');
        _incomingDataController.add(data);
      }

      calloc.free(buffer);
    } catch (e) {
      _logger.e('Control stream receive error: $e');
    }
  }

  void _pollDataStreams() {
    if (_moqWtRecvData == null) {
      return;
    }

    try {
      // Keep polling while there is data available
      while (true) {
        // Allocate buffers for data stream reception
        // Use larger buffer for media data
        final buffer = calloc<Uint8>(65536);
        final streamIdPtr = calloc<Uint64>();
        final isCompletePtr = calloc<Int32>();

        final received = _moqWtRecvData!(_sessionId, streamIdPtr, buffer, 65536, isCompletePtr);

        if (received > 0) {
          final streamId = streamIdPtr.value;
          final isComplete = isCompletePtr.value != 0;

          // Copy received data
          final data = Uint8List(received.toInt());
          final nativeData = buffer.asTypedList(received.toInt());
          data.setAll(0, nativeData);

          _stats = _stats.copyWith(
            bytesReceived: _stats.bytesReceived + received.toInt(),
            packetsReceived: _stats.packetsReceived + 1,
            lastActivity: DateTime.now(),
          );

          _logger.d('Received $received bytes on data stream $streamId (complete: $isComplete)');

          // Emit as DataStreamChunk
          _incomingDataStreamController.add(DataStreamChunk(
            streamId: streamId,
            data: data,
            isComplete: isComplete,
          ));

          calloc.free(buffer);
          calloc.free(streamIdPtr);
          calloc.free(isCompletePtr);

          // Continue polling if we got data
          continue;
        }

        calloc.free(buffer);
        calloc.free(streamIdPtr);
        calloc.free(isCompletePtr);

        // No more data available, exit loop
        break;
      }
    } catch (e) {
      _logger.e('Data stream receive error: $e');
    }
  }

  void _stopReceiving() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  @override
  void dispose() {
    disconnect();
    if (_nativeLibraryLoaded && _moqWtCleanup != null) {
      _moqWtCleanup!();
    }
    _connectionStateController.close();
    _incomingDataController.close();
    _incomingDataStreamController.close();
    _incomingDatagramController.close();
  }
}

// FFI function signatures
typedef _InitFunc = void Function();
typedef _ConnectFunc = int Function(
    Pointer<Int8> host, int port, Pointer<Int8> path, int insecure, Pointer<Uint64> outSessionId);
typedef _SendFunc = int Function(
    int sessionId, Pointer<Uint8> data, int len);
typedef _RecvFunc = int Function(
    int sessionId, Pointer<Uint8> buffer, int bufferLen);
typedef _RecvDataFunc = int Function(
    int sessionId, Pointer<Uint64> outStreamId, Pointer<Uint8> buffer, int bufferLen, Pointer<Int32> outIsComplete);
typedef _CloseFunc = int Function(int sessionId);
typedef _CleanupFunc = void Function();
typedef _GetLastErrorFunc = int Function(Pointer<Uint8> buffer, int bufferLen);
typedef _OpenUniStreamFunc = int Function(int sessionId, Pointer<Uint64> outStreamId);
typedef _StreamWriteFunc = int Function(int sessionId, int streamId, Pointer<Uint8> data, int len);
typedef _StreamFinishFunc = int Function(int sessionId, int streamId);
