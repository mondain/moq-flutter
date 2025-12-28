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

/// Native QUIC transport using FFI bindings to Quinn (Rust)
class QuicTransport extends MoQTransport {
  final Logger _logger;

  final _connectionStateController = StreamController<bool>.broadcast();
  final _incomingDataController = StreamController<Uint8List>.broadcast();

  bool _isConnected = false;
  int _connectionId = -1;
  DynamicLibrary? _nativeLib;
  MoQTransportStats _stats = const MoQTransportStats(
    bytesSent: 0,
    bytesReceived: 0,
    packetsSent: 0,
    packetsReceived: 0,
  );

  // Native function signatures (nullable to support stub mode)
  _InitFunc? _moqQuicInit;
  _ConnectFunc? _moqQuicConnect;
  _SendFunc? _moqQuicSend;
  _CloseFunc? _moqQuicClose;
  _CleanupFunc? _moqQuicCleanup;

  Timer? _pollTimer;
  bool _nativeLibraryLoaded = false;

  QuicTransport({Logger? logger}) : _logger = logger ?? Logger() {
    _loadNativeLibrary();
  }

  void _loadNativeLibrary() {
    try {
      _nativeLib = _openNativeLibrary();

      // Load native functions
      _moqQuicInit = _nativeLib!
          .lookup<NativeFunction<Void Function()>>('moq_quic_init')
          .asFunction();
      _moqQuicConnect = _nativeLib!
          .lookup<NativeFunction<NativeInt32 Function(Pointer<Int8>, NativeUint16, Uint8, Pointer<NativeUint64>)>>(
              'moq_quic_connect')
          .asFunction();
      _moqQuicSend = _nativeLib!
          .lookup<NativeFunction<NativeInt64 Function(NativeUint64, Pointer<Uint8>, NativeIntPtr)>>(
              'moq_quic_send')
          .asFunction();
      _moqQuicClose = _nativeLib!
          .lookup<NativeFunction<NativeInt32 Function(NativeUint64)>>('moq_quic_close')
          .asFunction();
      _moqQuicCleanup = _nativeLib!
          .lookup<NativeFunction<Void Function()>>('moq_quic_cleanup')
          .asFunction();

      // Initialize the native library
      _moqQuicInit!();

      _nativeLibraryLoaded = true;
      _logger.i('Native QUIC library loaded successfully');
    } catch (e) {
      _logger.e('Failed to load native QUIC library: $e');
      _logger.w('QUIC transport will not be available - running in stub mode');
      _nativeLibraryLoaded = false;
    }
  }

  DynamicLibrary _openNativeLibrary() {
    if (Platform.isLinux || Platform.isAndroid) {
      // Try multiple paths for the native library
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
      return DynamicLibrary.open('libmoq_quic.dylib');
    } else if (Platform.isWindows) {
      return DynamicLibrary.open('moq_quic.dll');
    } else {
      throw UnsupportedError('Platform not supported: ${Platform.operatingSystem}');
    }
  }

  @override
  bool get isConnected => _isConnected && _connectionId >= 0;

  @override
  Stream<bool> get connectionStateStream => _connectionStateController.stream;

  @override
  Future<void> connect(String host, int port, {Map<String, String>? options}) async {
    if (_isConnected) {
      _logger.w('Already connected');
      return;
    }

    if (!_nativeLibraryLoaded) {
      _logger.e('Cannot connect: Native QUIC library is not available');
      _logger.w('Please build the native Rust library first:');
      _logger.w('  cd native/moq_quic && cargo build --release');
      _connectionStateController.add(false);
      throw StateError('Native QUIC library not available');
    }

    try {
      _logger.i('Connecting to $host:$port via Quinn QUIC');

      // Check for insecure flag in options (for self-signed certificates)
      final insecureValue = options?['insecure'];
      final insecure = (insecureValue == 'true' || insecureValue?.toString() == 'true') ? 1 : 0;
      if (insecure != 0) {
        _logger.w('Certificate verification DISABLED (insecure mode)');
      }

      // Convert host to native string
      final hostPtr = host.toNativeUtf8();
      final connectionIdPtr = calloc<Uint64>();

      final result = _moqQuicConnect!(
          hostPtr.cast<Int8>(), port.toUnsigned(16), insecure, connectionIdPtr);

      calloc.free(hostPtr);

      if (result != 0) {
        calloc.free(connectionIdPtr);
        throw Exception('QUIC connection failed with error code: $result');
      }

      _connectionId = connectionIdPtr.value;
      calloc.free(connectionIdPtr);

      _isConnected = true;
      _connectionStateController.add(true);
      _logger.i('QUIC connection established (ID: $_connectionId)');

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

    _logger.i('Disconnecting QUIC connection');

    _stopReceiving();

    if (_connectionId >= 0 && _nativeLibraryLoaded && _moqQuicClose != null) {
      _moqQuicClose!(_connectionId);
      _connectionId = -1;
    }

    _isConnected = false;
    _connectionStateController.add(false);
    _logger.i('QUIC connection closed');
  }

  @override
  Future<void> send(Uint8List data) async {
    if (!isConnected) {
      throw StateError('Not connected');
    }

    if (!_nativeLibraryLoaded || _moqQuicSend == null) {
      _logger.e('Cannot send: Native QUIC library is not available');
      throw StateError('Native QUIC library not available');
    }

    try {
      // Allocate native buffer
      final dataPtr = calloc<Uint8>(data.length);
      final nativeData = dataPtr.asTypedList(data.length);
      nativeData.setAll(0, data);

      final sent = _moqQuicSend!(_connectionId, dataPtr, data.length);

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

      _logger.d('Sent $sentInt bytes via QUIC');
    } catch (e) {
      _logger.e('Send failed: $e');
      rethrow;
    }
  }

  @override
  Stream<Uint8List> get incomingData => _incomingDataController.stream;

  @override
  MoQTransportStats get stats => _stats;

  void _startReceiving() {
    // Poll for incoming data every 10ms
    _pollTimer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (!isConnected) return;

      try {
        // Buffer to receive data (max 4KB per poll)
        final buffer = calloc<Uint8>(4096);
        final received = _moqQuicRecv(_connectionId, buffer, 4096);

        if (received > 0) {
          // Copy received data
          final data = Uint8List(received);
          final nativeData = buffer.asTypedList(received);
          data.setAll(0, nativeData);

          _stats = _stats.copyWith(
            bytesReceived: _stats.bytesReceived + received,
            packetsReceived: _stats.packetsReceived + 1,
            lastActivity: DateTime.now(),
          );

          _incomingDataController.add(data);
          _logger.d('Received $received bytes via QUIC');
        }

        calloc.free(buffer);
      } catch (e) {
        _logger.e('Receive error: $e');
      }
    });
  }

  void _stopReceiving() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  int _moqQuicRecv(int connectionId, Pointer<Uint8> buffer, int bufferLen) {
    if (_nativeLib == null) return 0;
    try {
      final func = _nativeLib!
          .lookup<NativeFunction<NativeInt64 Function(NativeUint64, Pointer<Uint8>, NativeIntPtr)>>(
              'moq_quic_recv');
      final recv = func.asFunction<int Function(int, Pointer<Uint8>, int)>();
      return recv(connectionId, buffer, bufferLen);
    } catch (e) {
      _logger.e('Failed to call moq_quic_recv: $e');
      return 0;
    }
  }

  @override
  void dispose() {
    disconnect();
    if (_nativeLibraryLoaded && _moqQuicCleanup != null) {
      _moqQuicCleanup!();
    }
    _connectionStateController.close();
    _incomingDataController.close();
  }
}

// FFI function signatures
typedef _InitFunc = void Function();
typedef _ConnectFunc = int Function(
    Pointer<Int8> host, int port, int insecure, Pointer<Uint64> outConnectionId);
typedef _SendFunc = int Function(
    int connectionId, Pointer<Uint8> data, int len);
typedef _CloseFunc = int Function(int connectionId);
typedef _CleanupFunc = void Function();
