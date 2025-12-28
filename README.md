# MoQ Flutter

Media over QUIC (MoQ) Flutter client implementation per [draft-ietf-moq-transport-14](https://datatracker.ietf.org/doc/draft-ietf-moq-transport/14/).

## Project Structure

```
lib/
├── main.dart                     # Application entry point
├── moq/                          # MoQ protocol implementation
│   ├── client/                   # MoQ client
│   │   └── moq_client.dart        # Main client with subscription handling
│   ├── protocol/                 # Protocol messages and types
│   │   ├── moq_messages.dart     # Core message types and enums
│   │   ├── moq_wire_format.dart  # Varint encoding/decoding
│   │   ├── moq_messages_control.dart      # Control messages
│   │   ├── moq_messages_control_extra.dart # Additional control messages
│   │   └── moq_messages_data.dart         # Data messages (objects)
│   └── transport/                # Transport layer abstraction
│       └── moq_transport.dart    # MoQ transport interface
├── media/                        # Media playback
│   ├── moq_video_player.dart     # Video player service
│   └── moq_video_providers.dart  # Riverpod video player providers
├── models/                       # Data models
├── providers/                    # Riverpod state providers
│   └── moq_providers.dart
├── screens/                      # UI screens
│   └── moq_home_screen.dart
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
- Comprehensive test coverage for wire format (44 tests passing)

### Test Coverage

- **Wire Format Tests**: 44/44 passing
  - Varint encoding/decoding (32-bit and 64-bit)
  - Tuple encoding/decoding
  - Location encoding/decoding
  - Message parser

- **Control Message Tests**: Round-trip serialization for all control messages
- **Data Message Tests**: Object datagram, subgroup header, subgroup object

## TODO

- Complete QUIC FFI bindings (quiche or msquic) for transport layer
- Implement data stream handling (SUBGROUP_HEADER, OBJECT_DATAGRAM reception)
- Implement FETCH for past objects
- Implement PUBLISH/PUBLISH_OK for server mode
- Implement namespace discovery (SUBSCRIBE_NAMESPACE, PUBLISH_NAMESPACE)
- Add error handling and reconnection logic
- Add integration tests for full client/server flow
- Improve test coverage for control and data messages
- Add performance benchmarks for serialization

## References

- [draft-ietf-moq-transport-14](https://datatracker.ietf.org/doc/draft-ietf-moq-transport/14/)
- [MoQ Working Group](https://datatracker.ietf.org/wg/moq/about/)
