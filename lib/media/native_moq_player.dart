// Native MoQ Video Player using Rust-based libmpv integration
//
// Uses the native media player for buffer-based playback without file I/O.
// This is more efficient for live streaming as data goes directly from
// the MoQ transport to mpv's ring buffer.

import 'dart:async';
import 'dart:io';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import '../moq/protocol/moq_messages.dart';
import '../moq/client/moq_client.dart';
import '../moq/media/moq_media_decoder.dart';
import '../moq/media/streaming_playback.dart';
import '../services/native_media_player.dart';

/// Native MoQ video player using Rust buffer-based playback
///
/// This player writes fMP4 data directly to an in-memory ring buffer
/// instead of files, providing the most efficient path for live streaming.
class NativeMoQPlayer {
  final Logger _logger;

  // Native player instance
  NativeMediaPlayer? _nativePlayer;

  // Media decoder and muxers
  final MoqMediaDecoder _mediaDecoder = MoqMediaDecoder();
  AvccFmp4Muxer? _videoMuxer;
  OpusStreamingMuxer? _audioMuxer;

  // Stream subscriptions
  final List<StreamSubscription<MoQObject>> _objectSubscriptions = [];

  // State
  bool _isInitialized = false;
  bool _isPlaying = false;
  bool _hasWrittenInit = false;

  // Statistics
  int _objectsReceived = 0;
  int _bytesReceived = 0;
  int _bytesWrittenToBuffer = 0;
  int _videoFramesReceived = 0;
  int _audioFramesReceived = 0;

  // Group tracking for mid-stream join detection
  Int64? _currentVideoGroupId;
  bool _joinedVideoMidGroup = false;
  bool _foundValidVideoStart = false;
  int _skippedVideoFrames = 0;

  // Event processing timer
  Timer? _eventTimer;

  NativeMoQPlayer({Logger? logger}) : _logger = logger ?? Logger();

  /// Check if native player is available on this platform
  static bool get isAvailable {
    // Only available on desktop platforms for now
    if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
      debugPrint('NativeMoQPlayer: Not a desktop platform');
      return false;
    }
    try {
      final available = NativeMediaPlayer.isAvailable;
      debugPrint('NativeMoQPlayer: isAvailable = $available');
      return available;
    } catch (e) {
      debugPrint('NativeMoQPlayer: isAvailable check failed: $e');
      return false;
    }
  }

  /// Initialize the player with MoQ subscriptions
  ///
  /// [outputMode] controls how video is displayed:
  /// - [VideoOutputMode.window]: mpv creates its own window (desktop testing)
  /// - [VideoOutputMode.none]: Audio only, no video output
  /// - [VideoOutputMode.texture]: For Flutter integration (future)
  Future<void> initialize(
    List<MoQSubscription> subscriptions, {
    VideoOutputMode outputMode = VideoOutputMode.window,
  }) async {
    if (_isInitialized) {
      _logger.w('Player already initialized');
      return;
    }

    _logger.i('Initializing native player with ${subscriptions.length} subscriptions');

    // Create native player
    _nativePlayer = NativeMediaPlayer.createWithOutput(outputMode);
    if (_nativePlayer == null) {
      throw StateError('Failed to create native media player - is libmpv installed?');
    }

    // Create muxers for fMP4 output
    _videoMuxer = AvccFmp4Muxer(
      width: 1920,
      height: 1080,
      timescale: 90000,
      trackId: 1,
    );
    _audioMuxer = OpusStreamingMuxer(
      sampleRate: 48000,
      channels: 2,
      trackId: 2,
    );

    // Subscribe to incoming objects
    for (final subscription in subscriptions) {
      final sub = subscription.objectStream.listen(
        _handleMediaObject,
        onError: (error) => _logger.e('Object stream error: $error'),
        onDone: () => _logger.i('Object stream closed'),
      );
      _objectSubscriptions.add(sub);
    }

    // Start event processing timer
    _eventTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      _nativePlayer?.processEvents();
    });

    _isInitialized = true;
    _logger.i('Native player initialized');
  }

  void _handleMediaObject(MoQObject object) {
    final trackName = String.fromCharCodes(object.trackName);
    final isVideo = trackName.contains('video');

    debugPrint('NativeMoQPlayer: Received object on track $trackName: '
        'groupId=${object.groupId}, objectId=${object.objectId}, '
        'payloadSize=${object.payload?.length ?? 0}');

    if (object.status != ObjectStatus.normal || object.payload == null) {
      if (object.status == ObjectStatus.endOfTrack) {
        _logger.i('Received end of track for $trackName');
        _nativePlayer?.endStream();
      }
      return;
    }

    _objectsReceived++;
    _bytesReceived += object.payload!.length;

    // For video, implement mid-group join detection and skip logic
    if (isVideo) {
      if (!_handleVideoGroupTracking(object)) {
        // Skip this frame - we're waiting for a valid starting point
        return;
      }
    }

    // Decode moq-mi format
    final frame = _mediaDecoder.decode(object);
    if (frame == null) {
      debugPrint('NativeMoQPlayer: Failed to decode frame');
      return;
    }

    if (frame.type == MediaFrameType.videoH264) {
      _videoFramesReceived++;
      _writeVideoFrame(frame);
    } else if (frame.type == MediaFrameType.audioOpus ||
               frame.type == MediaFrameType.audioAac) {
      _audioFramesReceived++;
      _writeAudioFrame(frame);
    }
  }

  /// Handle video group tracking for mid-stream join detection
  /// Returns true if the frame should be processed, false if it should be skipped
  bool _handleVideoGroupTracking(MoQObject object) {
    final groupId = object.groupId;
    final objectId = object.objectId;

    // First video object ever received
    if (_currentVideoGroupId == null) {
      _currentVideoGroupId = groupId;

      // Check if we joined mid-group (objectId != 0)
      if (objectId != Int64.ZERO) {
        _joinedVideoMidGroup = true;
        _skippedVideoFrames++;
        _logger.w('Detected mid-group join: groupId=$groupId, objectId=$objectId. '
            'Skipping P-frames until next group with keyframe at objectId=0...');
        return false; // Skip this frame - keyframe is at objectId=0 which we missed
      } else {
        // We joined at the start of a group - great!
        _foundValidVideoStart = true;
        _logger.i('Joined at group start: groupId=$groupId, objectId=0');
        return true;
      }
    }

    // Check if this is a new group
    if (groupId != _currentVideoGroupId) {
      _logger.i('New video group detected: $groupId (was $_currentVideoGroupId)');
      _currentVideoGroupId = groupId;

      // New group - check if we're at objectId=0
      if (objectId == Int64.ZERO) {
        if (_joinedVideoMidGroup && !_foundValidVideoStart) {
          _logger.i('Found valid starting point! groupId=$groupId, objectId=0. '
              'Skipped $_skippedVideoFrames frames from partial group.');
          // Reset decoder state to start fresh with this keyframe
          _mediaDecoder.reset();
        }
        _foundValidVideoStart = true;
        _joinedVideoMidGroup = false;
        return true;
      } else {
        // New group but not at objectId=0 - shouldn't happen normally
        _logger.w('New group $groupId but objectId=$objectId (not 0). '
            'Continuing to wait for group with objectId=0...');
        _skippedVideoFrames++;
        return false;
      }
    }

    // Same group - check if we have a valid start
    if (_foundValidVideoStart) {
      return true; // Process normally
    } else {
      // Still waiting for valid start - skip this P-frame
      _skippedVideoFrames++;
      debugPrint('NativeMoQPlayer: Skipping video frame #$_skippedVideoFrames '
          '(groupId=$groupId, objectId=$objectId) - waiting for keyframe');
      return false;
    }
  }

  void _writeVideoFrame(MediaFrame frame) {
    if (_videoMuxer == null || _nativePlayer == null) return;

    // Initialize muxer with first keyframe's codec config
    if (!_videoMuxer!.isInitReady && frame.codecConfig != null) {
      _videoMuxer!.setAvcDecoderConfig(frame.codecConfig!);

      // Write initialization segment to buffer
      final initSegment = _videoMuxer!.initSegment;
      if (initSegment != null) {
        _writeToBuffer(initSegment);
        _hasWrittenInit = true;
        _logger.i('Wrote video init segment: ${initSegment.length} bytes');
      }
    }

    if (_videoMuxer!.isInitReady) {
      // Create and write media segment
      final mediaSegment = _videoMuxer!.createMediaSegment(frame);
      _writeToBuffer(mediaSegment);
    }
  }

  void _writeAudioFrame(MediaFrame frame) {
    if (_audioMuxer == null || _nativePlayer == null) return;

    // Don't write audio-only - wait for video to provide init segment
    // Audio and video fMP4 init segments are incompatible when concatenated
    // The video muxer will handle both once we have a keyframe
    if (!_hasWrittenInit) {
      _logger.d('Skipping audio frame - waiting for video keyframe');
      return;
    }

    // Write audio media segment (only after video init was written)
    // Note: This won't work properly without a combined muxer
    // For now, we focus on video-only playback
    // final mediaSegment = _audioMuxer!.createMediaSegment(frame);
    // _writeToBuffer(mediaSegment);
  }

  void _writeToBuffer(Uint8List data) {
    if (_nativePlayer == null || data.isEmpty) return;

    final written = _nativePlayer!.writeData(data);
    _bytesWrittenToBuffer += written;

    if (written < data.length) {
      _logger.w('Buffer full: wrote $written of ${data.length} bytes');
    }

    // Auto-start playback after first data is written
    if (!_isPlaying && _hasWrittenInit && _bytesWrittenToBuffer > 1024) {
      _startPlayback();
    }
  }

  void _startPlayback() {
    if (_isPlaying || _nativePlayer == null) return;

    final success = _nativePlayer!.play();
    if (success) {
      _isPlaying = true;
      _logger.i('Started native playback');
    } else {
      _logger.e('Failed to start native playback');
    }
  }

  /// Start playback
  ///
  /// Note: Actual playback starts automatically when data is written to the buffer.
  /// Calling play() before data is available will just log a message.
  Future<void> play() async {
    if (!_isInitialized) {
      throw StateError('Player not initialized');
    }

    // Don't call native play() until we have data - mpv would block waiting
    if (_hasWrittenInit && _bytesWrittenToBuffer > 1024) {
      _startPlayback();
    } else {
      _logger.i('Waiting for media data before starting playback (will auto-start)');
    }
  }

  /// Pause playback
  Future<void> pause() async {
    _nativePlayer?.pause();
    _isPlaying = false;
  }

  /// Resume playback
  Future<void> resume() async {
    _nativePlayer?.resume();
    _isPlaying = true;
  }

  /// Stop playback
  Future<void> stop() async {
    _nativePlayer?.stop();
    _isPlaying = false;
  }

  /// Get buffer statistics
  MediaPlayerStats? getStats() => _nativePlayer?.getStats();

  /// Check if initialized
  bool get isInitialized => _isInitialized;

  /// Check if playing
  bool get isPlaying => _nativePlayer?.isPlaying ?? false;

  /// Get statistics
  int get objectsReceived => _objectsReceived;
  int get bytesReceived => _bytesReceived;
  int get bytesWrittenToBuffer => _bytesWrittenToBuffer;
  int get videoFramesReceived => _videoFramesReceived;
  int get audioFramesReceived => _audioFramesReceived;

  /// Dispose resources
  Future<void> dispose() async {
    _logger.i('Disposing native player');

    _eventTimer?.cancel();

    for (final sub in _objectSubscriptions) {
      await sub.cancel();
    }
    _objectSubscriptions.clear();

    _nativePlayer?.dispose();
    _nativePlayer = null;

    _videoMuxer = null;
    _audioMuxer = null;

    _isInitialized = false;
    _isPlaying = false;
    _hasWrittenInit = false;

    // Reset group tracking state
    _currentVideoGroupId = null;
    _joinedVideoMidGroup = false;
    _foundValidVideoStart = false;
    _skippedVideoFrames = 0;
  }
}
