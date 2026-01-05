// Native Media Player FFI bindings
//
// Uses libmpv via Rust for efficient buffer-based media playback.
// Data is written directly to an in-memory ring buffer, avoiding file I/O.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:logger/logger.dart';

/// Video output mode for the native media player
enum VideoOutputMode {
  /// Native window (desktop only)
  window(0),
  /// No video output (audio only)
  none(1),
  /// GPU texture (for Flutter integration)
  texture(2);

  final int value;
  const VideoOutputMode(this.value);
}

// FFI function signatures
typedef MediaPlayerCreateNative = Uint64 Function();
typedef MediaPlayerCreate = int Function();

typedef MediaPlayerCreateWithOutputNative = Uint64 Function(Int32 videoOutput);
typedef MediaPlayerCreateWithOutput = int Function(int videoOutput);

typedef MediaPlayerDestroyNative = Void Function(Uint64 playerId);
typedef MediaPlayerDestroy = void Function(int playerId);

typedef MediaPlayerWriteNative = IntPtr Function(
    Uint64 playerId, Pointer<Uint8> data, IntPtr len);
typedef MediaPlayerWrite = int Function(
    int playerId, Pointer<Uint8> data, int len);

typedef MediaPlayerPlayNative = Int32 Function(Uint64 playerId);
typedef MediaPlayerPlay = int Function(int playerId);

typedef MediaPlayerPauseNative = Int32 Function(Uint64 playerId);
typedef MediaPlayerPause = int Function(int playerId);

typedef MediaPlayerResumeNative = Int32 Function(Uint64 playerId);
typedef MediaPlayerResume = int Function(int playerId);

typedef MediaPlayerStopNative = Int32 Function(Uint64 playerId);
typedef MediaPlayerStop = int Function(int playerId);

typedef MediaPlayerEndStreamNative = Void Function(Uint64 playerId);
typedef MediaPlayerEndStream = void Function(int playerId);

typedef MediaPlayerProcessEventsNative = Void Function(Uint64 playerId);
typedef MediaPlayerProcessEvents = void Function(int playerId);

typedef MediaPlayerGetStatsNative = Int32 Function(
  Uint64 playerId,
  Pointer<IntPtr> outBuffered,
  Pointer<Uint64> outWritten,
  Pointer<Uint64> outRead,
);
typedef MediaPlayerGetStats = int Function(
  int playerId,
  Pointer<IntPtr> outBuffered,
  Pointer<Uint64> outWritten,
  Pointer<Uint64> outRead,
);

typedef MediaPlayerIsPlayingNative = Int32 Function(Uint64 playerId);
typedef MediaPlayerIsPlaying = int Function(int playerId);

/// Native media player using libmpv with custom stream protocol
///
/// This player reads media data from an in-memory ring buffer instead of files,
/// providing the most efficient path for streaming media from MoQ.
class NativeMediaPlayer {
  static final Logger _logger = Logger();
  static DynamicLibrary? _lib;
  static bool _initialized = false;

  // FFI function pointers
  static MediaPlayerCreate? _create;
  static MediaPlayerCreateWithOutput? _createWithOutput;
  static MediaPlayerDestroy? _destroy;
  static MediaPlayerWrite? _write;
  static MediaPlayerPlay? _play;
  static MediaPlayerPause? _pause;
  static MediaPlayerResume? _resume;
  static MediaPlayerStop? _stop;
  static MediaPlayerEndStream? _endStream;
  static MediaPlayerProcessEvents? _processEvents;
  static MediaPlayerGetStats? _getStats;
  static MediaPlayerIsPlaying? _isPlaying;

  /// Player instance ID
  final int _playerId;
  bool _disposed = false;

  NativeMediaPlayer._(this._playerId);

  /// Initialize the native library
  static void _initLib() {
    if (_initialized) return;

    try {
      if (Platform.isLinux) {
        _lib = DynamicLibrary.open('libmoq_quic.so');
      } else if (Platform.isMacOS) {
        _lib = DynamicLibrary.open('libmoq_quic.dylib');
      } else if (Platform.isWindows) {
        _lib = DynamicLibrary.open('moq_quic.dll');
      } else if (Platform.isAndroid) {
        _lib = DynamicLibrary.open('libmoq_quic.so');
      } else if (Platform.isIOS) {
        _lib = DynamicLibrary.process();
      } else {
        throw UnsupportedError('Platform not supported');
      }

      _create = _lib!
          .lookup<NativeFunction<MediaPlayerCreateNative>>('media_player_create')
          .asFunction();

      _createWithOutput = _lib!
          .lookup<NativeFunction<MediaPlayerCreateWithOutputNative>>(
              'media_player_create_with_output')
          .asFunction();

      _destroy = _lib!
          .lookup<NativeFunction<MediaPlayerDestroyNative>>('media_player_destroy')
          .asFunction();

      _write = _lib!
          .lookup<NativeFunction<MediaPlayerWriteNative>>('media_player_write')
          .asFunction();

      _play = _lib!
          .lookup<NativeFunction<MediaPlayerPlayNative>>('media_player_play')
          .asFunction();

      _pause = _lib!
          .lookup<NativeFunction<MediaPlayerPauseNative>>('media_player_pause')
          .asFunction();

      _resume = _lib!
          .lookup<NativeFunction<MediaPlayerResumeNative>>('media_player_resume')
          .asFunction();

      _stop = _lib!
          .lookup<NativeFunction<MediaPlayerStopNative>>('media_player_stop')
          .asFunction();

      _endStream = _lib!
          .lookup<NativeFunction<MediaPlayerEndStreamNative>>(
              'media_player_end_stream')
          .asFunction();

      _processEvents = _lib!
          .lookup<NativeFunction<MediaPlayerProcessEventsNative>>(
              'media_player_process_events')
          .asFunction();

      _getStats = _lib!
          .lookup<NativeFunction<MediaPlayerGetStatsNative>>(
              'media_player_get_stats')
          .asFunction();

      _isPlaying = _lib!
          .lookup<NativeFunction<MediaPlayerIsPlayingNative>>(
              'media_player_is_playing')
          .asFunction();

      _initialized = true;
      _logger.i('Native media player library initialized');
    } catch (e) {
      _logger.e('Failed to initialize native media player: $e');
      rethrow;
    }
  }

  /// Create a new native media player with default output mode
  ///
  /// Returns null if creation fails (e.g., libmpv not available)
  static NativeMediaPlayer? create() {
    try {
      _initLib();

      final playerId = _create!();
      if (playerId == 0) {
        _logger.e('Failed to create native media player');
        return null;
      }

      _logger.i('Created native media player: $playerId');
      return NativeMediaPlayer._(playerId);
    } catch (e) {
      _logger.e('Failed to create native media player: $e');
      return null;
    }
  }

  /// Create a new native media player with specific video output mode
  ///
  /// [outputMode] - The video output mode to use:
  ///   - [VideoOutputMode.window]: Native window (desktop only)
  ///   - [VideoOutputMode.none]: No video output (audio only)
  ///   - [VideoOutputMode.texture]: GPU texture for Flutter integration
  ///
  /// Returns null if creation fails (e.g., libmpv not available)
  static NativeMediaPlayer? createWithOutput(VideoOutputMode outputMode) {
    try {
      _initLib();

      final playerId = _createWithOutput!(outputMode.value);
      if (playerId == 0) {
        _logger.e('Failed to create native media player with output: $outputMode');
        return null;
      }

      _logger.i('Created native media player: $playerId with output: $outputMode');
      return NativeMediaPlayer._(playerId);
    } catch (e) {
      _logger.e('Failed to create native media player: $e');
      return null;
    }
  }

  /// Check if native media player is available on this platform
  static bool get isAvailable {
    try {
      _initLib();
      return _initialized;
    } catch (e) {
      return false;
    }
  }

  /// Write media data to the player's buffer
  ///
  /// Returns number of bytes written
  int writeData(Uint8List data) {
    if (_disposed || data.isEmpty) return 0;

    final ptr = calloc<Uint8>(data.length);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      return _write!(_playerId, ptr, data.length);
    } finally {
      calloc.free(ptr);
    }
  }

  /// Start playback
  bool play() {
    if (_disposed) return false;
    return _play!(_playerId) == 0;
  }

  /// Pause playback
  bool pause() {
    if (_disposed) return false;
    return _pause!(_playerId) == 0;
  }

  /// Resume playback
  bool resume() {
    if (_disposed) return false;
    return _resume!(_playerId) == 0;
  }

  /// Stop playback
  bool stop() {
    if (_disposed) return false;
    return _stop!(_playerId) == 0;
  }

  /// Signal end of stream
  void endStream() {
    if (_disposed) return;
    _endStream!(_playerId);
  }

  /// Process mpv events (should be called periodically)
  void processEvents() {
    if (_disposed) return;
    _processEvents!(_playerId);
  }

  /// Get buffer statistics
  MediaPlayerStats getStats() {
    if (_disposed) {
      return MediaPlayerStats(buffered: 0, written: 0, read: 0);
    }

    final bufferedPtr = calloc<IntPtr>();
    final writtenPtr = calloc<Uint64>();
    final readPtr = calloc<Uint64>();

    try {
      _getStats!(_playerId, bufferedPtr, writtenPtr, readPtr);
      return MediaPlayerStats(
        buffered: bufferedPtr.value,
        written: writtenPtr.value,
        read: readPtr.value,
      );
    } finally {
      calloc.free(bufferedPtr);
      calloc.free(writtenPtr);
      calloc.free(readPtr);
    }
  }

  /// Check if currently playing
  bool get isPlaying {
    if (_disposed) return false;
    return _isPlaying!(_playerId) == 1;
  }

  /// Dispose the player
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _destroy!(_playerId);
    _logger.i('Disposed native media player: $_playerId');
  }
}

/// Media player buffer statistics
class MediaPlayerStats {
  final int buffered;
  final int written;
  final int read;

  MediaPlayerStats({
    required this.buffered,
    required this.written,
    required this.read,
  });

  @override
  String toString() =>
      'MediaPlayerStats(buffered: $buffered, written: $written, read: $read)';
}
