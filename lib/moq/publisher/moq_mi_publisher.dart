import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:logger/logger.dart';
import '../client/moq_client.dart';
import '../packager/moq_mi_packager.dart';
import '../protocol/moq_messages.dart';

/// MoQ Media Interop Publisher
///
/// Implements draft-cenzano-moq-media-interop-03 for publishing
/// media with LOC packaging and extension headers.
///
/// This publisher handles:
/// - Track naming (audio0, video0)
/// - Group management (new group at IDR for video, per frame for audio)
/// - Extension header creation for moq-mi
/// - Object publishing with proper sequencing
class MoqMiPublisher {
  final MoQClient _client;
  final Logger _logger;
  final MoqMiPackager _packager = MoqMiPackager();

  // Track state
  Int64? _videoTrackAlias;
  Int64? _audioTrackAlias;
  String? _trackPrefix;
  List<Uint8List>? _namespace;
  bool _isAnnounced = false;

  // Video stream state
  int? _videoStreamId;
  Int64 _videoGroupId = Int64.ZERO;
  Int64 _videoObjectId = Int64.ZERO;
  bool _waitingForKeyframe = true;

  // Audio stream state (group per frame in moq-mi)
  Int64 _audioGroupId = Int64.ZERO;

  // Publisher priority
  final int _videoPriority;
  final int _audioPriority;

  MoqMiPublisher({
    required MoQClient client,
    Logger? logger,
    int videoPriority = 100,
    int audioPriority = 200, // Audio typically higher priority
  })  : _client = client,
        _logger = logger ?? Logger(),
        _videoPriority = videoPriority,
        _audioPriority = audioPriority;

  /// Get whether the publisher is announced
  bool get isAnnounced => _isAnnounced;

  /// Get the underlying client
  MoQClient get client => _client;

  /// Get the packager (for sequence ID access)
  MoqMiPackager get packager => _packager;

  /// Announce namespace and prepare for publishing
  ///
  /// [namespaceParts]: Namespace parts (e.g., ['vc'])
  /// [trackPrefix]: Track name prefix (e.g., '33' results in '33audio0', '33video0')
  Future<void> announce(
    List<String> namespaceParts,
    String trackPrefix,
  ) async {
    if (_isAnnounced) {
      _logger.w('Already announced namespace');
      return;
    }

    _trackPrefix = trackPrefix;
    _namespace =
        namespaceParts.map((p) => Uint8List.fromList(p.codeUnits)).toList();

    try {
      await _client.announceNamespace(_namespace!);
      _isAnnounced = true;
      _logger.i(
          'MoQ-MI namespace announced: ${namespaceParts.join("/")} with prefix: $trackPrefix');

      // Pre-register track aliases (publishers need to know aliases for subscribers)
      _videoTrackAlias = Int64(0);
      _audioTrackAlias = Int64(1);
    } catch (e) {
      _logger.e('Failed to announce namespace: $e');
      rethrow;
    }
  }

  /// Get video track name
  String get videoTrackName => moqMiGetTrackName(_trackPrefix ?? '', false);

  /// Get audio track name
  String get audioTrackName => moqMiGetTrackName(_trackPrefix ?? '', true);

  /// Publish a video frame (H.264 AVCC format)
  ///
  /// [payload]: H.264 AVCC payload (4-byte length prefix NALUs)
  /// [pts]: Presentation timestamp in microseconds
  /// [dts]: Decode timestamp in microseconds
  /// [isKeyframe]: Whether this is an IDR keyframe
  /// [avcDecoderConfig]: AVC decoder configuration record (SPS/PPS) - required for keyframes
  /// [duration]: Frame duration in microseconds
  /// [timebase]: Timebase (default: 1000000 for microseconds)
  Future<void> publishVideoFrame({
    required Uint8List payload,
    required Int64 pts,
    Int64? dts,
    required bool isKeyframe,
    Uint8List? avcDecoderConfig,
    Int64? duration,
    Int64? timebase,
  }) async {
    if (!_isAnnounced) {
      throw StateError('Must announce namespace before publishing');
    }

    final actualDts = dts ?? pts;
    final actualTimebase = timebase ?? Int64(1000000); // microseconds
    final actualDuration = duration ?? Int64(33333); // ~30fps default

    // Keyframe starts a new group (per moq-mi spec)
    if (isKeyframe) {
      // Close previous stream if exists
      if (_videoStreamId != null) {
        try {
          await _client.finishDataStream(_videoStreamId!);
        } catch (e) {
          _logger.w('Error closing previous video stream: $e');
        }
        _videoStreamId = null;
      }

      // Increment group ID for new GOP
      _videoGroupId += Int64(1);
      _videoObjectId = Int64.ZERO;
      _waitingForKeyframe = false;

      // Open new stream for this GOP
      _videoStreamId = await _client.openDataStream();

      // Create extension headers for keyframe (includes extradata)
      final extensionHeaders = _packager.createVideoExtensionHeaders(
        pts: pts,
        dts: actualDts,
        timebase: actualTimebase,
        duration: actualDuration,
        avcDecoderConfig: avcDecoderConfig,
      );

      // Write subgroup header with extension headers
      await _client.writeSubgroupHeaderWithExtensions(
        _videoStreamId!,
        trackAlias: _videoTrackAlias!,
        groupId: _videoGroupId,
        subgroupId: Int64.ZERO,
        publisherPriority: _videoPriority,
        extensionHeaders: extensionHeaders,
      );

      // Write object (first object in group = keyframe)
      await _client.writeObject(
        _videoStreamId!,
        objectId: _videoObjectId,
        payload: payload,
        status: ObjectStatus.normal,
      );

      _videoObjectId += Int64(1);
      _logger.d(
          'Published video keyframe: group=$_videoGroupId, size=${payload.length}');
    } else {
      // Delta frame
      if (_waitingForKeyframe) {
        _logger.d('Dropping delta frame while waiting for keyframe');
        return;
      }

      if (_videoStreamId == null) {
        _logger.w('No active video stream for delta frame');
        return;
      }

      // Create extension headers for delta frame (no extradata)
      final extensionHeaders = _packager.createVideoExtensionHeaders(
        pts: pts,
        dts: actualDts,
        timebase: actualTimebase,
        duration: actualDuration,
      );

      // Write object with extension headers
      await _client.writeObjectWithExtensions(
        _videoStreamId!,
        objectId: _videoObjectId,
        payload: payload,
        status: ObjectStatus.normal,
        extensionHeaders: extensionHeaders,
      );

      _videoObjectId += Int64(1);
      _logger.d(
          'Published video delta: group=$_videoGroupId, obj=${_videoObjectId - Int64(1)}, size=${payload.length}');
    }
  }

  /// Publish an audio frame (Opus format)
  ///
  /// [payload]: Raw Opus packet (per RFC 6716)
  /// [pts]: Presentation timestamp in microseconds
  /// [sampleRate]: Sample rate in Hz (e.g., 48000)
  /// [numChannels]: Number of audio channels
  /// [duration]: Frame duration in microseconds
  /// [timebase]: Timebase (default: 1000000 for microseconds)
  Future<void> publishOpusFrame({
    required Uint8List payload,
    required Int64 pts,
    required int sampleRate,
    required int numChannels,
    Int64? duration,
    Int64? timebase,
  }) async {
    if (!_isAnnounced) {
      throw StateError('Must announce namespace before publishing');
    }

    final actualTimebase = timebase ?? Int64(1000000); // microseconds
    final actualDuration =
        duration ?? Int64((1000000 * 960) ~/ sampleRate); // 20ms default for Opus

    // Audio uses new group per frame (per moq-mi spec)
    _audioGroupId += Int64(1);

    // Create extension headers
    final extensionHeaders = _packager.createOpusExtensionHeaders(
      pts: pts,
      timebase: actualTimebase,
      sampleFreq: Int64(sampleRate),
      numChannels: numChannels,
      duration: actualDuration,
    );

    // Open stream, write header, object, close - one group per frame
    final streamId = await _client.openDataStream();

    await _client.writeSubgroupHeaderWithExtensions(
      streamId,
      trackAlias: _audioTrackAlias!,
      groupId: _audioGroupId,
      subgroupId: Int64.ZERO,
      publisherPriority: _audioPriority,
      extensionHeaders: extensionHeaders,
    );

    await _client.writeObject(
      streamId,
      objectId: Int64.ZERO,
      payload: payload,
      status: ObjectStatus.normal,
    );

    await _client.finishDataStream(streamId);

    _logger.d('Published Opus frame: group=$_audioGroupId, size=${payload.length}');
  }

  /// Publish an audio frame (AAC format)
  ///
  /// [payload]: Raw AAC data block (raw_data_block() per ISO14496-3)
  /// [pts]: Presentation timestamp in microseconds
  /// [sampleRate]: Sample rate in Hz
  /// [numChannels]: Number of audio channels
  /// [duration]: Frame duration in microseconds
  /// [timebase]: Timebase (default: 1000000 for microseconds)
  Future<void> publishAacFrame({
    required Uint8List payload,
    required Int64 pts,
    required int sampleRate,
    required int numChannels,
    Int64? duration,
    Int64? timebase,
  }) async {
    if (!_isAnnounced) {
      throw StateError('Must announce namespace before publishing');
    }

    final actualTimebase = timebase ?? Int64(1000000); // microseconds
    final actualDuration =
        duration ?? Int64((1000000 * 1024) ~/ sampleRate); // 1024 samples typical for AAC

    // Audio uses new group per frame (per moq-mi spec)
    _audioGroupId += Int64(1);

    // Create extension headers
    final extensionHeaders = _packager.createAacExtensionHeaders(
      pts: pts,
      timebase: actualTimebase,
      sampleFreq: Int64(sampleRate),
      numChannels: numChannels,
      duration: actualDuration,
    );

    // Open stream, write header, object, close - one group per frame
    final streamId = await _client.openDataStream();

    await _client.writeSubgroupHeaderWithExtensions(
      streamId,
      trackAlias: _audioTrackAlias!,
      groupId: _audioGroupId,
      subgroupId: Int64.ZERO,
      publisherPriority: _audioPriority,
      extensionHeaders: extensionHeaders,
    );

    await _client.writeObject(
      streamId,
      objectId: Int64.ZERO,
      payload: payload,
      status: ObjectStatus.normal,
    );

    await _client.finishDataStream(streamId);

    _logger.d('Published AAC frame: group=$_audioGroupId, size=${payload.length}');
  }

  /// Stop publishing
  Future<void> stop({String reason = 'Publisher stopped'}) async {
    // Close video stream if active
    if (_videoStreamId != null) {
      try {
        await _client.finishDataStream(_videoStreamId!);
      } catch (e) {
        _logger.w('Error closing video stream: $e');
      }
      _videoStreamId = null;
    }

    // Cancel namespace
    if (_isAnnounced && _namespace != null) {
      try {
        await _client.cancelNamespace(_namespace!, reason: reason);
      } catch (e) {
        _logger.w('Error canceling namespace: $e');
      }
    }

    _isAnnounced = false;
    _waitingForKeyframe = true;
    _videoGroupId = Int64.ZERO;
    _videoObjectId = Int64.ZERO;
    _audioGroupId = Int64.ZERO;
    _packager.reset();

    _logger.i('MoQ-MI Publisher stopped');
  }

  void dispose() {
    stop();
  }
}
