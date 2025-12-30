import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart' show ResolutionPreset;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import '../moq/media/audio_capture.dart';
import '../moq/media/audio_encoder.dart';
import '../moq/media/camera_capture.dart';
import '../moq/media/video_encoder.dart';
import '../moq/publisher/cmaf_publisher.dart';
import '../moq/publisher/moq_publisher.dart';
import '../providers/moq_providers.dart';

/// Client role - what action to take after connecting
enum ClientRole {
  subscriber,
  publisher,
}

/// Main home screen for the MoQ application
class MoQHomeScreen extends ConsumerStatefulWidget {
  const MoQHomeScreen({super.key});

  @override
  ConsumerState<MoQHomeScreen> createState() => _MoQHomeScreenState();
}

class _MoQHomeScreenState extends ConsumerState<MoQHomeScreen> {
  final _hostController = TextEditingController(text: 'localhost');
  final _portController = TextEditingController(text: '8443');
  final _urlController = TextEditingController(text: 'https://localhost:4433/moq');
  final _namespaceController = TextEditingController(text: 'demo');
  final _trackNameController = TextEditingController(text: 'video');
  bool _isLoading = false;
  bool _insecureMode = false;
  TransportType _transportType = TransportType.moqt;
  ClientRole _clientRole = ClientRole.subscriber;
  String _statusMessage = '';
  final bool _useCmafPackaging = true; // Default to CMAF/fMP4 packaging

  // Publisher state
  MoQPublisher? _publisher;
  CmafPublisher? _cmafPublisher;
  bool _isPublishing = false;
  int _publishedFrames = 0;
  int _publishedAudioFrames = 0;

  // Video capture and encoding
  CameraCapture? _cameraCapture;
  H264Encoder? _h264Encoder;
  StreamSubscription<VideoFrame>? _videoFrameSubscription;
  StreamSubscription<H264Frame>? _h264FrameSubscription;

  // Audio capture and encoding
  AudioCapture? _audioCapture;
  OpusEncoder? _opusEncoder;
  StreamSubscription<AudioSamples>? _audioSamplesSubscription;
  StreamSubscription<OpusFrame>? _opusFrameSubscription;

  @override
  void initState() {
    super.initState();
    // Initialize local state from provider
    _transportType = ref.read(transportTypeProvider);
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _urlController.dispose();
    _namespaceController.dispose();
    _trackNameController.dispose();
    super.dispose();
  }

  void _setStatus(String message) {
    if (mounted) {
      setState(() => _statusMessage = message);
    }
  }

  Future<void> _connectAndAct() async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'Connecting...';
    });

    try {
      final client = ref.read(moqClientProvider);

      // Step 1: Connect
      if (_transportType == TransportType.webtransport) {
        final urlStr = _urlController.text;
        final uri = Uri.parse(urlStr);
        final host = uri.host;
        final port = uri.port;
        final path = uri.path;

        _setStatus('Connecting to $host:$port via WebTransport...');
        await client.connect(host, port, options: {
          'insecure': _insecureMode.toString(),
          'path': path,
        });
      } else {
        final host = _hostController.text;
        final port = int.tryParse(_portController.text) ?? 8443;

        _setStatus('Connecting to $host:$port via QUIC...');
        await client.connect(host, port, options: {'insecure': _insecureMode.toString()});
      }

      _setStatus('Connected! Performing ${_clientRole.name} action...');

      // Step 2: Immediately perform role-specific action
      final namespace = _namespaceController.text;
      final trackName = _trackNameController.text;
      final namespaceBytes = [Uint8List.fromList(namespace.codeUnits)];
      final trackNameBytes = Uint8List.fromList(trackName.codeUnits);

      if (_clientRole == ClientRole.subscriber) {
        _setStatus('Subscribing to $namespace/$trackName...');
        final result = await client.subscribe(
          namespaceBytes,
          trackNameBytes,
        );
        _setStatus('Subscribed! Track alias: ${result.trackAlias}');

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Subscribed to $namespace/$trackName (alias: ${result.trackAlias})'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        // Publisher role
        _setStatus('Publishing namespace $namespace...');

        try {
          if (_useCmafPackaging) {
            // Use CMAF/fMP4 packaging (CARP compliant)
            await _startCmafPublishing(client, namespace, trackName);
          } else {
            // Use LOC packaging (raw codec data)
            await _startLocPublishing(client, namespace, trackName);
          }
        } catch (e) {
          _setStatus('Publish failed: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Publish failed: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
          rethrow;
        }
      }
    } catch (e) {
      _setStatus('Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Start publishing with CMAF/fMP4 packaging (CARP compliant)
  Future<void> _startCmafPublishing(dynamic client, String namespace, String trackName) async {
    // Create CMAF publisher
    _cmafPublisher = CmafPublisher(client: client, logger: _logger);

    // Announce namespace with init track
    await _cmafPublisher!.announce([namespace], initTrackName: '0.mp4');

    // Add video track with fMP4 muxer
    const videoTrackName = '1.m4s';
    await _cmafPublisher!.addVideoTrack(
      videoTrackName,
      width: 1280,
      height: 720,
      frameRate: 30,
      timescale: 90000,
      priority: 128,
      trackId: 1,
    );

    // Add audio track with fMP4 muxer
    const audioTrackName = '2.m4s';
    await _cmafPublisher!.addAudioTrack(
      audioTrackName,
      sampleRate: 48000,
      channels: 2,
      bitrate: 128000,
      frameDurationMs: 20,
      priority: 200,
      trackId: 2,
    );

    // Mark audio as ready (Opus doesn't need external config)
    await _cmafPublisher!.setAudioReady(audioTrackName);

    _isPublishing = true;
    _publishedFrames = 0;
    _publishedAudioFrames = 0;
    _setStatus('Initializing CMAF capture...');

    // Initialize video capture and encoding
    await _initializeCmafVideoPublishing(videoTrackName);

    // Initialize audio capture and encoding
    await _initializeCmafAudioPublishing(audioTrackName);

    _setStatus('Publishing CMAF video and audio to $namespace');

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Publishing CMAF video and audio to $namespace'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  /// Start publishing with LOC packaging (raw codec data)
  Future<void> _startLocPublishing(dynamic client, String namespace, String trackName) async {
    // Create publisher
    _publisher = MoQPublisher(client: client);

    // Announce namespace
    await _publisher!.announce([namespace]);

    // Add video track to catalog (H.264/AVC)
    final videoTrackAlias = await _publisher!.addVideoTrack(
      trackName,
      priority: 128,
      codec: 'avc1.42001f', // H.264 Baseline Profile Level 3.1
      width: 1280,
      height: 720,
      framerate: 30,
      bitrate: 2000000,
      updateCatalogNow: false, // Wait to update both tracks
    );

    // Add audio track with Opus codec to catalog
    const audioTrackName = 'audio';
    final audioTrackAlias = await _publisher!.addAudioTrack(
      audioTrackName,
      priority: 200,
      codec: 'opus',
      samplerate: 48000,
      channelConfig: 'stereo',
      bitrate: 128000,
      updateCatalogNow: true, // Update catalog with both tracks
    );

    _isPublishing = true;
    _publishedFrames = 0;
    _publishedAudioFrames = 0;
    _setStatus('Initializing capture...');

    // Initialize video capture and H.264 encoder
    await _initializeVideoPublishing(trackName);

    // Initialize audio capture and Opus encoder
    await _initializeAudioPublishing(audioTrackName);

    _setStatus('Publishing video ($videoTrackAlias) and audio ($audioTrackAlias)');

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Publishing video and audio to $namespace'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  /// Initialize CMAF video capture and publishing
  Future<void> _initializeCmafVideoPublishing(String videoTrackName) async {
    try {
      // Create camera capture
      _cameraCapture = CameraCapture(
        config: CaptureConfig(
          resolution: ResolutionPreset.high,
          enableAudio: false,
        ),
      );
      await _cameraCapture!.initialize();

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

      // Subscribe to video frames from camera
      _videoFrameSubscription = _cameraCapture!.videoFrames.listen((videoFrame) {
        _h264Encoder?.addFrame(videoFrame.data, videoFrame.timestampMs);
      });

      // Subscribe to encoded H.264 frames and publish as CMAF
      _h264FrameSubscription = _h264Encoder!.frames.listen((h264Frame) async {
        if (!_isPublishing || _cmafPublisher == null) return;

        try {
          // Publish H.264 frame wrapped in fMP4
          await _cmafPublisher!.publishVideoFrame(
            videoTrackName,
            h264Frame.data,
            isKeyframe: h264Frame.isKeyframe,
          );

          _publishedFrames++;

          if (_publishedFrames % 30 == 0) {
            if (mounted) {
              setState(() {
                _statusMessage =
                    'Publishing CMAF... $_publishedFrames video, $_publishedAudioFrames audio frames';
              });
            }
          }
        } catch (e) {
          debugPrint('Error publishing CMAF video frame: $e');
        }
      });

      // Start camera capture
      await _cameraCapture!.startCapture();
      _logger.i('CMAF video capture started');
    } catch (e) {
      _logger.e('Failed to initialize CMAF video publishing: $e');
      _startDemoPublishing('demo');
    }
  }

  /// Initialize CMAF audio capture and publishing
  Future<void> _initializeCmafAudioPublishing(String audioTrackName) async {
    // Create platform-specific audio capture
    _audioCapture = AudioCapture(
      config: const AudioCaptureConfig(
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 16,
      ),
    );
    await _audioCapture!.initialize();

    // Create Opus encoder
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

    // Subscribe to audio samples and feed to encoder
    _audioSamplesSubscription = _audioCapture!.audioStream.listen((samples) {
      _opusEncoder?.addSamples(samples);
    });

    // Subscribe to encoded Opus frames and publish as CMAF
    _opusFrameSubscription = _opusEncoder!.frames.listen((opusFrame) async {
      if (!_isPublishing || _cmafPublisher == null) return;

      try {
        // Publish Opus frame wrapped in fMP4
        await _cmafPublisher!.publishAudioFrame(
          audioTrackName,
          opusFrame.data,
        );

        _publishedAudioFrames++;

        if (_publishedAudioFrames % 50 == 0) {
          if (mounted) {
            setState(() {
              _statusMessage =
                  'Publishing CMAF... $_publishedFrames video, $_publishedAudioFrames audio frames';
            });
          }
        }
      } catch (e) {
        debugPrint('Error publishing CMAF audio frame: $e');
      }
    });

    // Start audio capture
    await _audioCapture!.startCapture();
    _logger.i('CMAF audio capture started');
  }

  /// Initialize video capture and H.264 encoding for publishing
  Future<void> _initializeVideoPublishing(String videoTrackName) async {
    try {
      // Create camera capture
      _cameraCapture = CameraCapture(
        config: CaptureConfig(
          resolution: ResolutionPreset.high, // 720p on most devices
          enableAudio: false, // Audio is handled separately
        ),
      );

      // Initialize camera
      await _cameraCapture!.initialize();

      // Create H.264 encoder with matching resolution
      _h264Encoder = H264Encoder(
        config: const H264EncoderConfig(
          width: 1280,
          height: 720,
          frameRate: 30,
          bitrate: 2000000,
          gopSize: 30, // Keyframe every 1 second
          profile: 'baseline',
          preset: 'ultrafast',
          tune: 'zerolatency',
          inputFormat: 'yuv420p',
        ),
      );
      await _h264Encoder!.start();

      // Subscribe to video frames from camera
      _videoFrameSubscription = _cameraCapture!.videoFrames.listen((videoFrame) {
        // Feed frame to H.264 encoder
        _h264Encoder?.addFrame(videoFrame.data, videoFrame.timestampMs);
      });

      // Subscribe to encoded H.264 frames and publish them
      _h264FrameSubscription = _h264Encoder!.frames.listen((h264Frame) async {
        if (!_isPublishing || _publisher == null) return;

        try {
          // Publish H.264 frame to video track
          // Keyframes start new groups
          await _publisher!.publishFrame(
            videoTrackName,
            h264Frame.data,
            newGroup: h264Frame.isKeyframe,
          );

          _publishedFrames++;

          // Update status periodically
          if (_publishedFrames % 30 == 0) {
            if (mounted) {
              setState(() {
                _statusMessage =
                    'Publishing... $_publishedFrames video, $_publishedAudioFrames audio frames';
              });
            }
          }
        } catch (e) {
          debugPrint('Error publishing video frame: $e');
        }
      });

      // Start camera capture
      await _cameraCapture!.startCapture();
      _logger.i('Video capture and H.264 encoding started');
    } catch (e) {
      _logger.e('Failed to initialize video publishing: $e');
      // Fall back to demo publishing if camera fails
      _startDemoPublishing(videoTrackName);
    }
  }

  // Logger for debug output
  final _logger = Logger();

  /// Initialize audio capture and Opus encoding for publishing
  Future<void> _initializeAudioPublishing(String audioTrackName) async {
    // Create platform-specific audio capture
    _audioCapture = AudioCapture(
      config: const AudioCaptureConfig(
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 16,
      ),
    );
    await _audioCapture!.initialize();

    // Create Opus encoder
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

    // Subscribe to audio samples and feed to encoder
    _audioSamplesSubscription = _audioCapture!.audioStream.listen((samples) {
      _opusEncoder?.addSamples(samples);
    });

    // Subscribe to encoded Opus frames and publish them
    _opusFrameSubscription = _opusEncoder!.frames.listen((opusFrame) async {
      if (!_isPublishing || _publisher == null) return;

      try {
        // Publish Opus frame to audio track
        // Each Opus frame is a new group for independent decoding
        await _publisher!.publishFrame(
          audioTrackName,
          opusFrame.data,
          newGroup: true, // Each Opus frame can be independently decoded
        );

        _publishedAudioFrames++;

        // Update status periodically
        if (_publishedAudioFrames % 50 == 0) {
          if (mounted) {
            setState(() {
              _statusMessage =
                  'Publishing... $_publishedFrames video, $_publishedAudioFrames audio frames';
            });
          }
        }
      } catch (e) {
        debugPrint('Error publishing audio frame: $e');
      }
    });

    // Start audio capture
    await _audioCapture!.startCapture();
  }

  void _startDemoPublishing(String trackName) {
    // Start publishing test frames in a background isolate-like pattern
    // This sends simple test payloads to demonstrate the publish flow
    Future<void> publishLoop() async {
      while (_isPublishing && _publisher != null) {
        try {
          // Create a test frame (just timestamp data for demo)
          final now = DateTime.now();
          final payload = Uint8List.fromList(
            'Frame $_publishedFrames at ${now.toIso8601String()}'.codeUnits,
          );

          // Publish as keyframe every 30 frames, otherwise delta
          final isKeyframe = _publishedFrames % 30 == 0;
          await _publisher!.publishFrame(
            trackName,
            payload,
            newGroup: isKeyframe,
          );

          setState(() {
            _publishedFrames++;
            _statusMessage =
                'Publishing... $_publishedFrames video, $_publishedAudioFrames audio frames';
          });

          // Wait 33ms for ~30fps
          await Future.delayed(const Duration(milliseconds: 33));
        } catch (e) {
          if (mounted) {
            setState(() {
              _statusMessage = 'Publish error: $e';
              _isPublishing = false;
            });
          }
          break;
        }
      }
    }

    publishLoop();
  }

  Future<void> _stopPublishing() async {
    _isPublishing = false;

    // Stop video capture and encoding
    await _videoFrameSubscription?.cancel();
    _videoFrameSubscription = null;
    await _h264FrameSubscription?.cancel();
    _h264FrameSubscription = null;

    if (_cameraCapture != null) {
      await _cameraCapture!.stopCapture();
      _cameraCapture!.dispose();
      _cameraCapture = null;
    }

    if (_h264Encoder != null) {
      await _h264Encoder!.stop();
      _h264Encoder!.dispose();
      _h264Encoder = null;
    }

    // Stop audio capture and encoding
    await _audioSamplesSubscription?.cancel();
    _audioSamplesSubscription = null;
    await _opusFrameSubscription?.cancel();
    _opusFrameSubscription = null;

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
    if (_publisher != null) {
      await _publisher!.stop();
      _publisher = null;
    }

    // Stop CMAF publisher
    if (_cmafPublisher != null) {
      await _cmafPublisher!.stop();
      _cmafPublisher = null;
    }

    _setStatus('Publishing stopped');
  }

  Future<void> _disconnect() async {
    try {
      // Stop publishing first if active
      if (_isPublishing) {
        await _stopPublishing();
      }

      final client = ref.read(moqClientProvider);
      await client.disconnect();
      _setStatus('Disconnected');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Disconnected')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Disconnect failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = ref.watch(isConnectedProvider);

    ref.listen<AsyncValue<bool>>(
      connectionStateProvider,
      (_, state) {
        if (state.hasValue && !state.value! && mounted) {
          _setStatus('Connection lost');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Connection lost'),
              backgroundColor: Colors.red,
            ),
          );
        }
      },
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('MoQ Flutter Client'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              // TODO: Open settings
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Connection Status Card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Connection Status',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          isConnected ? Icons.cloud_done : Icons.cloud_off,
                          color: isConnected ? Colors.green : Colors.red,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            isConnected ? 'Connected' : 'Disconnected',
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ),
                      ],
                    ),
                    if (_statusMessage.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        _statusMessage,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey[600],
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Role selector
            Text(
              'Client Role',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            SegmentedButton<ClientRole>(
              segments: const [
                ButtonSegment(
                  value: ClientRole.subscriber,
                  label: Text('Subscribe'),
                  icon: Icon(Icons.download),
                ),
                ButtonSegment(
                  value: ClientRole.publisher,
                  label: Text('Publish'),
                  icon: Icon(Icons.upload),
                ),
              ],
              selected: {_clientRole},
              onSelectionChanged: (isConnected || _isLoading)
                  ? null
                  : (Set<ClientRole> newSelection) {
                      setState(() => _clientRole = newSelection.first);
                    },
            ),
            const SizedBox(height: 16),

            // Transport type selector
            Text(
              'Transport Type',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            SegmentedButton<TransportType>(
              segments: const [
                ButtonSegment(
                  value: TransportType.moqt,
                  label: Text('Raw QUIC'),
                  icon: Icon(Icons.router),
                ),
                ButtonSegment(
                  value: TransportType.webtransport,
                  label: Text('WebTransport'),
                  icon: Icon(Icons.http),
                ),
              ],
              selected: {_transportType},
              onSelectionChanged: (isConnected || _isLoading)
                  ? null
                  : (Set<TransportType> newSelection) {
                      final newType = newSelection.first;
                      setState(() => _transportType = newType);
                      ref.read(transportTypeProvider.notifier).setTransportType(newType);
                    },
            ),
            const SizedBox(height: 16),

            // Connection settings
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Server',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    if (_transportType == TransportType.moqt) ...[
                      TextField(
                        controller: _hostController,
                        decoration: const InputDecoration(
                          labelText: 'Host',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        enabled: !isConnected && !_isLoading,
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _portController,
                        decoration: const InputDecoration(
                          labelText: 'Port',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        keyboardType: TextInputType.number,
                        enabled: !isConnected && !_isLoading,
                      ),
                    ] else ...[
                      TextField(
                        controller: _urlController,
                        decoration: const InputDecoration(
                          labelText: 'WebTransport URL',
                          border: OutlineInputBorder(),
                          hintText: 'https://example.com:4433/moq',
                          isDense: true,
                        ),
                        enabled: !isConnected && !_isLoading,
                      ),
                    ],
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      title: const Text('Skip Certificate Verification'),
                      subtitle: const Text(
                        'For self-signed certificates (insecure)',
                        style: TextStyle(fontSize: 11, color: Colors.orange),
                      ),
                      value: _insecureMode,
                      onChanged: (isConnected || _isLoading)
                          ? null
                          : (value) => setState(() => _insecureMode = value ?? false),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Track configuration
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _clientRole == ClientRole.subscriber
                          ? 'Track to Subscribe'
                          : 'Track to Publish',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _namespaceController,
                      decoration: const InputDecoration(
                        labelText: 'Namespace',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      enabled: !isConnected && !_isLoading,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _trackNameController,
                      decoration: const InputDecoration(
                        labelText: 'Track Name',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      enabled: !isConnected && !_isLoading,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Connect/Disconnect buttons
            FilledButton.icon(
              onPressed: (isConnected || _isLoading) ? null : _connectAndAct,
              icon: _isLoading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(_clientRole == ClientRole.subscriber
                      ? Icons.play_arrow
                      : Icons.publish),
              label: Text(_isLoading
                  ? 'Connecting...'
                  : _clientRole == ClientRole.subscriber
                      ? 'Connect & Subscribe'
                      : 'Connect & Publish'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: isConnected ? _disconnect : null,
              icon: const Icon(Icons.stop),
              label: const Text('Disconnect'),
            ),
          ],
        ),
      ),
    );
  }
}
