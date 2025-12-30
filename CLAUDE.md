# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Install dependencies
flutter pub get

# Run all tests
flutter test

# Run specific test file
flutter test test/moq/protocol/wire_format_test.dart

# Run application (builds Rust library automatically)
flutter run

# Build for specific platforms
flutter build apk          # Android
flutter build ios          # iOS
flutter build macos        # macOS
flutter build linux        # Linux
flutter build windows      # Windows

# Build Rust QUIC library manually (macOS creates universal binary)
cd native/moq_quic && cargo build --release

# Analyze code
flutter analyze
```

## Architecture Overview

This is a Media over QUIC (MoQ) Flutter client implementing [draft-ietf-moq-transport-14](https://datatracker.ietf.org/doc/draft-ietf-moq-transport/14/).

### Layer Structure

1. **Transport Layer** (`lib/services/quic_transport.dart`, `lib/moq/transport/moq_transport.dart`)
   - `MoQTransport`: Abstract interface for QUIC transport
   - `QuicTransport`: FFI bindings to Rust Quinn QUIC library (`native/moq_quic/`)
   - Falls back to stub mode if native library unavailable

2. **Protocol Layer** (`lib/moq/protocol/`)
   - `moq_wire_format.dart`: Varint (32/64-bit), tuple, and location encoding/decoding
   - `moq_messages.dart`: Core message types, enums, and wire format utilities
   - `moq_messages_control.dart`: Control messages (SUBSCRIBE, SETUP, etc.)
   - `moq_messages_control_extra.dart`: Additional control messages (FETCH, PUBLISH_NAMESPACE, etc.)
   - `moq_messages_data.dart`: Data messages (OBJECT_DATAGRAM, SUBGROUP_HEADER)
   - `moq_messages_publish.dart`: Publish-related messages

3. **Client Layer** (`lib/moq/client/moq_client.dart`)
   - `MoQClient`: Main client handling connection, subscriptions, and namespace announcements
   - Request ID management (even IDs for client, odd for server)
   - Track alias mapping

4. **Publisher Layer** (`lib/moq/publisher/`)
   - `moq_publisher.dart`: Publishing infrastructure
   - `cmaf_publisher.dart`: CMAF segment publishing

5. **Media Layer** (`lib/moq/media/`, `lib/media/`)
   - Camera/audio capture and encoding
   - fMP4 muxing for H.264 video and Opus audio
   - Video player integration with media_kit

6. **State Management** (`lib/providers/moq_providers.dart`)
   - Riverpod providers for MoQ client state

### Native Rust Library

The `native/moq_quic/` directory contains a Rust library using Quinn for QUIC transport:
- Compiled automatically during `flutter run` or `flutter build`
- Platform-specific build handled by `tool/build_rust.dart`
- Creates universal binary on macOS (arm64 + x86_64)
- Android/iOS builds use platform-specific build phases

### Key Message Types

Control messages use Type-Length-Value format: `type (varint) + length (16-bit) + payload`

- `CLIENT_SETUP` (0x20) / `SERVER_SETUP` (0x21): Version negotiation
- `SUBSCRIBE` (0x3) / `SUBSCRIBE_OK` (0x4) / `SUBSCRIBE_ERROR` (0x5)
- `PUBLISH_NAMESPACE` (0x6) / `PUBLISH_NAMESPACE_OK` (0x7)
- `GOAWAY` (0x10): Session termination

Data streams use stream type prefix:
- `SUBGROUP_HEADER` (0x10): Starts each subgroup stream
- Objects follow with: `object_id (varint) + status (varint) + payload`

### Draft Version Format

Draft versions use `0xff000000 + draft_number`. Draft-14 = `0xff00000e`.
