# MoQ Flutter

Media over QUIC (MoQ) Flutter client implementation per [draft-ietf-moq-transport-14](https://datatracker.ietf.org/doc/draft-ietf-moq-transport/14/).

## Project Structure

```
lib/
├── main.dart                     # Application entry point
├── moq/                          # MoQ protocol implementation
│   ├── client/                   # MoQ client
│   │   └── moq_client.dart        # Main client with subscription handling
│   ├── media/                    # Media capture and encoding
│   │   ├── audio_capture.dart     # Platform-specific audio capture
│   │   ├── audio_encoder.dart     # Opus audio encoder (FFmpeg)
│   │   ├── camera_capture.dart    # Camera capture abstraction
│   │   ├── linux_capture.dart     # Linux V4L2/FFmpeg video capture
│   │   ├── video_encoder.dart     # H.264 video encoder (FFmpeg)
│   │   ├── media_encoder.dart     # Combined audio/video encoder
│   │   ├── native_capture_channel.dart  # Platform channel for native capture
│   │   └── fmp4/                  # CMAF/fMP4 packaging
│   ├── packager/                 # Media packaging formats
│   │   └── moq_mi_packager.dart   # MoQ Media Interop (moq-mi) packager
│   ├── publisher/                # Publishing support
│   │   ├── cmaf_publisher.dart    # CMAF/fMP4 publisher
│   │   ├── moq_publisher.dart     # LOC publisher
│   │   └── moq_mi_publisher.dart  # MoQ-MI publisher (LOC with extension headers)
│   ├── protocol/                 # Protocol messages and types
│   │   ├── moq_messages.dart     # Core message types and enums
│   │   ├── moq_wire_format.dart  # Varint encoding/decoding
│   │   ├── moq_messages_control.dart      # Control messages
│   │   ├── moq_messages_control_extra.dart # Additional control messages
│   │   ├── moq_messages_data.dart         # Data messages (objects)
│   │   ├── moq_messages_publish.dart      # Publish-related messages
│   │   └── moq_data_parser.dart           # Data stream parser
│   └── transport/                # Transport layer abstraction
│       └── moq_transport.dart    # MoQ transport interface
├── media/                        # Media playback
│   ├── moq_video_player.dart     # Video player service
│   └── moq_video_providers.dart  # Riverpod video player providers
├── models/                       # Data models
├── providers/                    # Riverpod state providers
│   └── moq_providers.dart
├── screens/                      # UI screens
│   ├── connection_screen.dart    # Server connection UI
│   ├── publisher_screen.dart     # Media publishing UI
│   ├── viewer_screen.dart        # Media playback UI
│   └── settings_screen.dart      # Application settings
├── services/                     # Platform-specific services
│   └── quic_transport.dart       # QUIC transport via FFI
├── transport/                    # Transport layer abstraction
│   └── moq_transport.dart
├── utils/                        # Utility functions
└── widgets/                      # Reusable widgets

native/moq_quic/                  # Rust QUIC library (FFI)
├── Cargo.toml
└── src/

test/
└── moq/protocol/                 # Protocol serialization tests
    ├── wire_format_test.dart     # Varint/tuple/location tests
    ├── control_messages_test.dart # Control message tests
    └── data_messages_test.dart    # Data message tests
```

## Build Configuration

The project includes automatic Rust library compilation during the build process:

- **Desktop (Linux/macOS/Windows)**: `tool/build_rust.dart` hook
- **Android**: Gradle tasks in `android/app/build.gradle.kts`
- **iOS**: Xcode build phases via `build/rust_build_ios.sh`
- **Platform-specific scripts**: `build/rust_build_*.sh`

Manual build commands:

- **Linux/macOS/iOS**: via `scripts/build_native.sh`
- **Windows**: `scripts/build_native.bat`

The Rust QUIC library is compiled automatically when running:

```bash
flutter build apk
flutter build ios
flutter run
```

## MoQ Draft-14 Support

This implementation follows [draft-ietf-moq-transport-14](https://datatracker.ietf.org/doc/draft-ietf-moq-transport/14/):

### Implemented Control Messages

- `CLIENT_SETUP` (0x20) / `SERVER_SETUP` (0x21) - Version negotiation
- `SUBSCRIBE` (0x3) - Subscribe to a track
- `SUBSCRIBE_OK` (0x4) / `SUBSCRIBE_ERROR` (0x5) - Subscribe responses
- `SUBSCRIBE_UPDATE` (0x2) - Update existing subscription
- `UNSUBSCRIBE` (0xA) - Unsubscribe from a track
- `GOAWAY` (0x10) - Session termination
- `PUBLISH_DONE` (0xB) - Publish completion

### Additional Control Messages

- `FETCH` (0x16) / `FETCH_OK` (0x18) / `FETCH_ERROR` (0x19) / `FETCH_CANCEL` (0x17)
- `PUBLISH` (0x1D) / `PUBLISH_OK` (0x1E) / `PUBLISH_ERROR` (0x1F)
- `MAX_REQUEST_ID` (0x15)
- `REQUESTS_BLOCKED` (0x1A)
- `TRACK_STATUS` (0xD) / `TRACK_STATUS_OK` (0xE) / `TRACK_STATUS_ERROR` (0xF)
- `SUBSCRIBE_NAMESPACE` (0x11) / `SUBSCRIBE_NAMESPACE_OK` (0x12) / `SUBSCRIBE_NAMESPACE_ERROR` (0x13)
- `UNSUBSCRIBE_NAMESPACE` (0x14)
- `PUBLISH_NAMESPACE` (0x6) / `PUBLISH_NAMESPACE_OK` (0x7) / `PUBLISH_NAMESPACE_ERROR` (0x8)
- `PUBLISH_NAMESPACE_DONE` (0x9) / `PUBLISH_NAMESPACE_CANCEL` (0xC)

### Data Messages

- `OBJECT_DATAGRAM` (0x00) - Object with status indicators
- `SUBGROUP_HEADER` (0x10) - Subgroup metadata
- `FETCH_HEADER` (0x05) - Fetch context header

### Data Model

- **Objects**: Addressable units of media data
- **Groups**: Temporal sequences of objects (join points)
- **Subgroups**: Subdivisions within groups
- **Tracks**: Collections of groups identified by namespace and name
- **Location**: {Group ID, Object ID} tuple
- **Status**: normal, doesNotExist, endOfGroup, endOfTrack

### Subscription Features

- **Filter Types**: Largest Object, Next Group Start, Absolute Start, Absolute Range
- **Group Order**: Ascending, Descending, or Publisher's preference
- **Priorities**: Subscriber and publisher priority (0-255)
- **Forward State**: Control whether objects are forwarded

### Mid-Stream Join Handling

When subscribing to an active stream, the player handles the case where it joins mid-group (missing the keyframe at objectId=0):

- **Detection**: Automatically detects if first video object has objectId != 0
- **Skip Logic**: Discards frames from the partial group (P-frames without preceding keyframe)
- **Recovery**: Waits for next group boundary with objectId=0 to start playback
- **Decoder Reset**: Resets decoder state when valid starting point is found

This ensures clean playback startup even when relays don't properly implement `nextGroupStart` filter type.

### Wire Format

- **Varint Encoding**: Variable-length integer encoding (32-bit and 64-bit)
- **Tuple Encoding**: Array of byte arrays
- **Location Encoding**: Group and object identifiers
- **Message Framing**: Type (varint) + Length (16-bit) + Payload format

### Client Features

- SERVER_SETUP response handling with timeout
- Server parameter processing (max_subscribe_id, max_track_alias, supported_versions)
- Track alias mapping
- Request ID handling (even for client, odd for server)
- Connection lifecycle management

## Dependencies

- **flutter_riverpod**: State management
- **ffi**: Platform-specific FFI bindings for QUIC
- **media_kit**: Video/audio playback
- **media_kit_video**: Video widget
- **media_kit_libs_video**: Native video libraries
- **logger**: Logging
- **fixnum**: 64-bit integer support
- **async**: Async utilities
- **uuid**: UUID generation
- **permission_handler**: Runtime permissions

## Getting Started

### Prerequisites

- Flutter SDK (3.8.1 or higher)
- Rust toolchain (for native QUIC library compilation)
- Android/iOS/Desktop build tools

#### Linux Dependencies

For video playback and capture support on Linux:

```bash
# Ubuntu/Debian
sudo apt update && sudo apt install libmpv-dev mpv ffmpeg pulseaudio-utils v4l-utils

# Fedora
sudo dnf install mpv-devel ffmpeg pulseaudio-utils v4l-utils

# Arch Linux
sudo pacman -S mpv ffmpeg libpulse v4l-utils
```

**Required for media capture:**

- `ffmpeg` - Video capture from V4L2 webcams and H.264/Opus encoding
- `pulseaudio-utils` - Audio capture via `parec` (PulseAudio)
- `v4l-utils` - Webcam device enumeration

#### macOS Dependencies

No additional dependencies required for video playback.

#### Windows Dependencies

The media_kit package includes bundled native libraries. No additional dependencies required.

### Install Dependencies

```bash
flutter pub get
```

### Run Tests

```bash
# Run all tests
flutter test

# Run specific test files
flutter test test/moq/protocol/wire_format_test.dart
flutter test test/moq/protocol/control_messages_test.dart
flutter test test/moq/protocol/data_messages_test.dart
```

### Run Application

```bash
# Run on connected device/emulator
flutter run

# Build for specific platform
flutter build apk          # Android
flutter build ios          # iOS
flutter build linux        # Linux
flutter build macos        # macOS
flutter build windows      # Windows
```

## Media Capture

The application supports publishing live audio and video with platform-specific capture implementations:

### Video Capture

| Platform | Implementation | Details |
|----------|---------------|---------|
| **Linux** | FFmpeg + V4L2 | Captures from `/dev/video*` devices, outputs YUV420P |
| **Android** | camera package | Uses Flutter's camera plugin |
| **iOS/macOS** | AVFoundation | Native capture via Platform Channels |
| **Windows** | Media Foundation | Native capture via Platform Channels |

### Audio Capture

| Platform | Implementation | Details |
|----------|---------------|---------|
| **Linux** | PulseAudio (parec) | Captures via `parec` command |
| **Android** | audio_streamer | Flutter plugin for microphone access |
| **iOS/macOS** | AVFoundation | Native capture via Platform Channels |
| **Windows** | Media Foundation | Native capture via Platform Channels |

### Encoding

- **Video**: H.264 encoding via FFmpeg (baseline profile, ultrafast preset)
- **Audio**: Opus encoding via FFmpeg (48kHz stereo, 128kbps)

### Packaging Formats

- **CMAF/fMP4**: CARP-compliant fragmented MP4 packaging
- **LOC**: Raw codec data packaging (H.264 NALUs, Opus frames)
- **MoQ-MI**: Media Interop format per [draft-cenzano-moq-media-interop-03](https://datatracker.ietf.org/doc/draft-cenzano-moq-media-interop/)
  - LOC-based packaging with extension headers for metadata
  - Video: H.264 AVCC format with PTS/DTS/duration/wallclock metadata
  - Audio: Opus or AAC-LC with PTS/samplerate/channels metadata
  - Track naming: `{prefix}audio0`, `{prefix}video0`

### Publisher Controls

- **Video Mute**: Toggle video track on/off during publishing
- **Audio Mute**: Toggle audio track on/off during publishing

## Current Status

Draft-14 implementation with:

- Full message type definitions for all control and data messages
- Complete wire format utilities (varint, tuple, location encoding/decoding)
- Client with SERVER_SETUP response handling and timeout
- Server parameter processing (max_subscribe_id, max_track_alias, supported_versions)
- Subscription management with full filtering support
- Request ID handling (even for client, odd for server)
- Track alias mapping
- Control message serialization/deserialization
- Data message serialization/deserialization
- Video player integration with media_kit
- State management with Riverpod
- Platform-specific media capture (Linux, Android, iOS, macOS, Windows)
- CMAF/fMP4 and MoQ-MI packaging for MoQ publishing
- Server-side PUBLISH/PUBLISH_OK/PUBLISH_ERROR handling for receiving publish requests
- Publisher-side SUBSCRIBE/SUBSCRIBE_OK/SUBSCRIBE_ERROR handling for relay subscriptions
- GOAWAY message handling with migration URI support
- Complete QUIC FFI bindings via Rust native library (quinn)
- Data stream handling with SUBGROUP_HEADER parser and transport separation
- Namespace discovery with SUBSCRIBE_NAMESPACE/UNSUBSCRIBE_NAMESPACE support
- FETCH client API for past objects (standalone and joining fetches)
- Video/audio mute controls for publishers
- Multi-screen responsive layout
- Comprehensive test coverage for protocol and client

### Test Coverage

- **Wire Format Tests**
  - Varint encoding/decoding (32-bit and 64-bit)
  - Tuple encoding/decoding
  - Location encoding/decoding
  - Message parser

- **Control Message Tests**: Round-trip serialization for all control messages
- **Data Message Tests**: Object datagram, subgroup header, subgroup object
- **Client Integration Tests**
  - Connection flow (CLIENT_SETUP/SERVER_SETUP handshake, timeout, disconnect)
  - Subscription flow (SUBSCRIBE/SUBSCRIBE_OK/SUBSCRIBE_ERROR, unsubscribe)
  - FETCH flow (standalone fetch, FETCH_OK/FETCH_ERROR, cancel)
  - Namespace operations (announceNamespace, subscribeNamespace, unsubscribeNamespace)
  - GOAWAY handling (with and without migration URI)
  - Publisher mode (incoming SUBSCRIBE requests, acceptSubscribe, rejectSubscribe, PUBLISH_DONE)
  - Data stream handling (openDataStream, writeSubgroupHeader)

## Saved Preferences

The application saves user preferences using Flutter's shared_preferences package. To clear saved preferences, delete the app data or uninstall the app.

- Android clear app data via Settings > Apps > MoQ Flutter > Storage > Clear Data
- Linux clear app data by executing: `rm -rf ~/.local/share/moq_flutter/`

## TODO

- Add automatic reconnection logic (GOAWAY handling exists)
- Add performance benchmarks for serialization

## References

- [draft-ietf-moq-transport-14](https://datatracker.ietf.org/doc/draft-ietf-moq-transport/14/)
- [MoQ Working Group](https://datatracker.ietf.org/wg/moq/about/)
- [Dart Language Documentation](https://dart.dev/guides)
- [Flutter Documentation](https://flutter.dev/docs)
- [Publish Sequence](docs/PublishSequence.md)
- [Subscribe Sequence](docs/SubscribeSequence.md)
