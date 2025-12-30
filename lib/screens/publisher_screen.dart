import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' as ui;
import 'package:camera/camera.dart' show ResolutionPreset;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:logger/logger.dart';
import 'package:sizer/sizer.dart';
import '../moq/media/audio_capture.dart';
import '../moq/media/audio_encoder.dart';
import '../moq/media/camera_capture.dart';
import '../moq/media/linux_capture.dart';
import '../moq/media/video_encoder.dart';
import '../moq/publisher/cmaf_publisher.dart';
import '../providers/moq_providers.dart';
import '../widgets/connection_status_card.dart';
import '../widgets/video_preview.dart';
import '../widgets/publishing_controls.dart';

/// Screen for publishing MoQ streams
class PublisherScreen extends ConsumerStatefulWidget {
  final String namespace;
  final String trackName;

  const PublisherScreen({
    super.key,
    required this.namespace,
    required this.trackName,
  });

  @override
  ConsumerState<PublisherScreen> createState() => _PublisherScreenState();
}

class _PublisherScreenState extends ConsumerState<PublisherScreen> {
  final _logger = Logger();

  // Publishing state
  CmafPublisher? _cmafPublisher;
  bool _isPublishing = false;
  bool _isAudioMuted = false;
  int _publishedFrames = 0;
  int _publishedAudioFrames = 0;
  String _statusMessage = '';

  // Video capture and encoding
  VideoCapture? _videoCapture;
  H264Encoder? _h264Encoder;
  StreamSubscription<VideoFrame>? _videoFrameSubscription;
  StreamSubscription<H264Frame>? _h264FrameSubscription;

  // Audio capture and encoding
  AudioCapture? _audioCapture;
  OpusEncoder? _opusEncoder;
  StreamSubscription<AudioSamples>? _audioSamplesSubscription;
  StreamSubscription<OpusFrame>? _opusFrameSubscription;

  // Linux preview frame
  ui.Image? _linuxPreviewImage;
  StreamSubscription<PreviewFrame>? _previewFrameSubscription;

  @override
  void initState() {
    super.initState();
    _startPublishing();
  }

  @override
  void dispose() {
    _stopPublishing();
    super.dispose();
  }

  void _setStatus(String message) {
    if (mounted) {
      setState(() => _statusMessage = message);
    }
  }

  Future<void> _startPublishing() async {
    _isPublishing = true;
    _publishedFrames = 0;
    _publishedAudioFrames = 0;
    if (mounted) setState(() {});

    try {
      final client = ref.read(moqClientProvider);

      // Create CMAF publisher
      _cmafPublisher = CmafPublisher(client: client, logger: _logger);

      // Configure tracks BEFORE announce (with capture parameters)
      // This allows catalog to be published with track info immediately after PUBLISH_NAMESPACE_OK
      _setStatus('Configuring tracks...');
      const videoTrackName = '1.m4s';
      const audioTrackName = '2.m4s';

      _cmafPublisher!.configureVideoTrack(
        videoTrackName,
        width: 1280,
        height: 720,
        frameRate: 30,
        timescale: 90000,
        priority: 128,
        trackId: 1,
      );

      _cmafPublisher!.configureAudioTrack(
        audioTrackName,
        sampleRate: 48000,
        channels: 2,
        bitrate: 128000,
        frameDurationMs: 20,
        priority: 200,
        trackId: 2,
      );

      // Announce namespace - catalog is published immediately after PUBLISH_NAMESPACE_OK
      // Subscribe handler starts automatically
      _setStatus('Announcing namespace...');
      await _cmafPublisher!.announce([widget.namespace], initTrackName: '0.mp4');

      _setStatus('Catalog published, awaiting subscriptions...');

      // Add actual tracks (creates muxers for encoding)
      await _cmafPublisher!.addVideoTrack(
        videoTrackName,
        width: 1280,
        height: 720,
        frameRate: 30,
        timescale: 90000,
        priority: 128,
        trackId: 1,
      );

      await _cmafPublisher!.addAudioTrack(
        audioTrackName,
        sampleRate: 48000,
        channels: 2,
        bitrate: 128000,
        frameDurationMs: 20,
        priority: 200,
        trackId: 2,
      );

      await _cmafPublisher!.setAudioReady(audioTrackName);

      _setStatus('Initializing capture...');

      // Initialize video and audio capture
      await _initializeVideoPublishing(videoTrackName);
      await _initializeAudioPublishing(audioTrackName);

      _setStatus('Publishing to ${widget.namespace}');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Publishing to ${widget.namespace}'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e, stack) {
      _logger.e('Failed to start publishing: $e');
      debugPrint('Stack trace: $stack');
      _isPublishing = false;
      _setStatus('Error: $e');
      if (mounted) setState(() {});
    }
  }

  Future<void> _initializeVideoPublishing(String videoTrackName) async {
    try {
      // Create platform-appropriate video capture
      if (Platform.isLinux) {
        final linuxCapture = LinuxVideoCapture(
          config: CaptureConfig(
            resolution: ResolutionPreset.high,
            enableAudio: false,
          ),
        );
        await linuxCapture.initialize();
        _videoCapture = linuxCapture;
      } else {
        final cameraCapture = CameraCapture(
          config: CaptureConfig(
            resolution: ResolutionPreset.high,
            enableAudio: false,
          ),
        );
        await cameraCapture.initialize();
        _videoCapture = cameraCapture;
      }

      // Create H.264 encoder
      _h264Encoder = H264Encoder(
        config: const H264EncoderConfig(
          width: 1280,
          height: 720,
          frameRate: 30,
          bitrate: 2000000,
          gopSize: 30,
          profile: 'baseline',
          preset: 'ultrafast',
          tune: 'zerolatency',
          inputFormat: 'yuv420p',
        ),
      );
      await _h264Encoder!.start();

      // Subscribe to video frames
      _videoFrameSubscription = _videoCapture!.videoFrames.listen((videoFrame) {
        _h264Encoder?.addFrame(videoFrame.data, videoFrame.timestampMs);
      });

      // Subscribe to encoded frames
      _h264FrameSubscription = _h264Encoder!.frames.listen((h264Frame) async {
        if (!_isPublishing || _cmafPublisher == null) return;

        try {
          await _cmafPublisher!.publishVideoFrame(
            videoTrackName,
            h264Frame.data,
            isKeyframe: h264Frame.isKeyframe,
          );

          _publishedFrames++;
          if (_publishedFrames % 30 == 0 && mounted) {
            setState(() {
              _statusMessage = 'Publishing... $_publishedFrames video, $_publishedAudioFrames audio';
            });
          }
        } catch (e) {
          debugPrint('Error publishing video frame: $e');
        }
      });

      // Start capture
      await _videoCapture!.startCapture();

      // Linux preview
      if (_videoCapture is LinuxVideoCapture) {
        _previewFrameSubscription = (_videoCapture as LinuxVideoCapture).previewFrames.listen(
          (previewFrame) async {
            try {
              final image = await previewFrame.toImage();
              if (mounted) {
                setState(() => _linuxPreviewImage = image);
              }
            } catch (e) {
              debugPrint('Error converting preview frame: $e');
            }
          },
        );
      }

      if (mounted) setState(() {});
    } catch (e) {
      _logger.e('Failed to initialize video: $e');
      if (mounted) setState(() {});
    }
  }

  Future<void> _initializeAudioPublishing(String audioTrackName) async {
    _audioCapture = AudioCapture(
      config: const AudioCaptureConfig(
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 16,
      ),
    );
    await _audioCapture!.initialize();

    _opusEncoder = OpusEncoder(
      config: const OpusEncoderConfig(
        sampleRate: 48000,
        channels: 2,
        bitrate: 128000,
        frameDurationMs: 20,
        application: 'audio',
      ),
    );
    await _opusEncoder!.start();

    _audioSamplesSubscription = _audioCapture!.audioStream.listen((samples) {
      _opusEncoder?.addSamples(samples);
    });

    _opusFrameSubscription = _opusEncoder!.frames.listen((opusFrame) async {
      if (!_isPublishing || _cmafPublisher == null || _isAudioMuted) return;

      try {
        await _cmafPublisher!.publishAudioFrame(audioTrackName, opusFrame.data);
        _publishedAudioFrames++;

        if (_publishedAudioFrames % 50 == 0 && mounted) {
          setState(() {
            _statusMessage = 'Publishing... $_publishedFrames video, $_publishedAudioFrames audio';
          });
        }
      } catch (e) {
        debugPrint('Error publishing audio frame: $e');
      }
    });

    await _audioCapture!.startCapture();
  }

  Future<void> _stopPublishing() async {
    _isPublishing = false;
    _isAudioMuted = false;

    // Stop subscriptions
    await _previewFrameSubscription?.cancel();
    await _videoFrameSubscription?.cancel();
    await _h264FrameSubscription?.cancel();
    await _audioSamplesSubscription?.cancel();
    await _opusFrameSubscription?.cancel();

    _previewFrameSubscription = null;
    _videoFrameSubscription = null;
    _h264FrameSubscription = null;
    _audioSamplesSubscription = null;
    _opusFrameSubscription = null;
    _linuxPreviewImage = null;

    // Stop video
    if (_videoCapture != null) {
      await _videoCapture!.stopCapture();
      _videoCapture!.dispose();
      _videoCapture = null;
    }

    if (_h264Encoder != null) {
      await _h264Encoder!.stop();
      _h264Encoder!.dispose();
      _h264Encoder = null;
    }

    // Stop audio
    if (_audioCapture != null) {
      await _audioCapture!.stopCapture();
      _audioCapture!.dispose();
      _audioCapture = null;
    }

    if (_opusEncoder != null) {
      await _opusEncoder!.stop();
      _opusEncoder!.dispose();
      _opusEncoder = null;
    }

    // Stop publisher
    if (_cmafPublisher != null) {
      await _cmafPublisher!.stop();
      _cmafPublisher = null;
    }
  }

  Future<void> _disconnect() async {
    await _stopPublishing();

    try {
      final client = ref.read(moqClientProvider);
      await client.disconnect();
    } catch (e) {
      debugPrint('Disconnect error: $e');
    }

    if (mounted) {
      context.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Listen for connection loss
    ref.listen<AsyncValue<bool>>(
      connectionStateProvider,
      (_, state) {
        if (state.hasValue && !state.value! && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Connection lost'),
              backgroundColor: Colors.red,
            ),
          );
          context.go('/');
        }
      },
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Publisher'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _disconnect,
        ),
      ),
      body: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Column(
              children: [
                // Video preview
                Card(
                  clipBehavior: Clip.antiAlias,
                  margin: EdgeInsets.all(4.w),
                  child: Column(
                    children: [
                      VideoPreview(
                        videoCapture: _videoCapture,
                        linuxPreviewImage: _linuxPreviewImage,
                        publishedFrames: _publishedFrames,
                      ),
                      PublishingControls(
                        isAudioMuted: _isAudioMuted,
                        videoFrames: _publishedFrames,
                        audioFrames: _publishedAudioFrames,
                        onMuteToggle: () => setState(() => _isAudioMuted = !_isAudioMuted),
                        onStop: _disconnect,
                      ),
                    ],
                  ),
                ),

                // Info
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4.w),
                  child: ConnectionStatusCard(statusMessage: _statusMessage),
                ),

                SizedBox(height: 2.h),

                // Track info
                Padding(
                  padding: EdgeInsets.all(4.w),
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.all(4.w),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Publishing Info',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 13.sp),
                          ),
                          SizedBox(height: 1.h),
                          _buildInfoRow('Namespace', widget.namespace),
                          _buildInfoRow('Video Track', '1.m4s'),
                          _buildInfoRow('Audio Track', '2.m4s'),
                          _buildInfoRow('Resolution', '1280x720 @ 30fps'),
                          _buildInfoRow('Audio', '48kHz stereo Opus'),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 0.5.h),
      child: Row(
        children: [
          Text(
            '$label: ',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11.sp),
          ),
          Expanded(child: Text(value, style: TextStyle(fontSize: 11.sp))),
        ],
      ),
    );
  }
}
