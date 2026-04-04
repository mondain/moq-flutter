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

This is a Media over QUIC (MoQ) Flutter client implementing [draft-ietf-moq-transport](https://datatracker.ietf.org/doc/draft-ietf-moq-transport/) with support for both draft-14 and draft-16. A reference publisher app exists at `../moq-pub` for testing.

### Layer Structure

1. **Transport Layer** (`lib/services/quic_transport.dart`, `lib/moq/transport/moq_transport.dart`)
   - `MoQTransport`: Abstract interface for QUIC transport
   - `QuicTransport`: FFI bindings to Rust Quinn library via `moq_quic_*` functions (5ms polling)
   - `WebTransportQuinnTransport`: Alternative transport via `moq_webtransport_*` functions (10ms polling); incomplete (no datagram support)
   - Falls back to stub mode if native library unavailable

2. **Protocol Layer** (`lib/moq/protocol/`)
   - `moq_wire_format.dart`: Varint (32/64-bit), tuple, and location encoding/decoding
   - `moq_messages.dart`: Core message types, enums, and wire format utilities
   - `moq_messages_control.dart`: Control messages (SUBSCRIBE, SETUP, etc.)
   - `moq_messages_control_extra.dart`: Additional control messages (FETCH, PUBLISH_NAMESPACE, etc.)
   - `moq_messages_data.dart`: Data messages (OBJECT_DATAGRAM, SUBGROUP_HEADER)
   - `moq_messages_publish.dart`: Publish-related messages
   - `moq_data_parser.dart`: Stateful incremental parser for SUBGROUP_HEADER + object sequences; handles delta-plus-one object ID encoding and moq-mi extension headers (even type = varint value, odd type = length-prefixed buffer)
   - **Version-Aware Message System**: `MoQVersion` class provides version constants and helper methods (`isDraft16OrLater()`, `usesDeltaKvp()`); `MoQMessageType.fromValue(value, version:)` enables version-aware type dispatch; serialize/deserialize methods accept `{int version}` parameter for draft-specific encoding; KVP encoding uses delta mode for draft-15+ via `encodeKeyValuePairs(params, useDelta: true)`; draft-16 introduces new message types (`RequestOkMessage`, `RequestErrorMessage`, `NamespaceMessage`, `NamespaceDoneMessage`) and parameter type classes (`SubscribeParameterType`, `TrackPropertyType`, `SubscribeOptions`)

3. **Client Layer** (`lib/moq/client/moq_client.dart`)
   - `MoQClient`: Main client handling connection, subscriptions, and namespace announcements
   - Request ID parity: client uses even IDs (0, 2, 4...), server uses odd IDs, incremented by 2
   - Track alias mapping via `_trackAliases: Map<Int64, TrackInfo>`
   - `ReplayStreamController` (`replay_stream.dart`): Buffers last N events (default 60) for late-joining subscribers; delivers buffered events synchronously before live subscription starts
   - `connect()` accepts `targetVersion` parameter for draft-16 ALPN-based negotiation; for draft-16, version is set before CLIENT_SETUP (from ALPN) rather than from SERVER_SETUP response

4. **Publisher Layer** (`lib/moq/publisher/`) - Three publishers with distinct packaging:
   - `MoQPublisher`: Base publisher, raw LOC format, manual group/subgroup management
   - `CmafPublisher`: fMP4/CMAF packaging via `H264Fmp4Muxer`/`OpusFmp4Muxer`, groups on video keyframes, publishes init segment as group 0 object 0 on each media track, handles incoming SUBSCRIBE from relay (per draft-law-moq-carp-00); supports auto-forward publishing mode via PUBLISH messages, honors subscribe filter types (LatestObject, NextGroupStart, AbsoluteStart, AbsoluteRange), sends PUBLISH_DONE to subscribers on stop
   - `MoqMiPublisher`: moq-mi format (draft-cenzano-moq-media-interop-03), raw codec bitstreams with metadata in extension headers, one QUIC stream per video GOP but one stream per audio frame, track naming `{prefix}audio0`/`{prefix}video0`

5. **Catalog Layer** (`lib/moq/catalog/`) per draft-ietf-moq-msf-00 / draft-ietf-moq-cmsf-00
   - `moq_catalog.dart`: MSF/CMSF catalog with flattened track selection params, `deltaUpdate`/`addTracks`/`removeTracks`/`cloneTracks` delta operations, `trackDuration` (VOD), `maxGrpSapStartingType`/`maxObjSapStartingType` (CMSF); backward-compatible parsing of legacy `commonTrackFields` and nested `selectionParams`
   - `moq_catalog_subscriber.dart`: Subscribes to catalog objects and manages track subscriptions
   - `moq_timeline.dart`: Timeline management for playback and seeking

6. **Packager Layer** (`lib/moq/packager/moq_mi_packager.dart`)
   - Generates/parses moq-mi extension headers with codec-specific type codes (0x0A media type, 0x0D AVC extradata, 0x0F Opus metadata, etc.)
   - Tracks sequence IDs and only sends AVC decoder config when it changes

7. **Media Layer** (`lib/moq/media/`, `lib/media/`)
   - Camera/audio capture with platform-specific implementations (Linux: FFmpeg+V4L2/PulseAudio, Android: native MediaCodec via `native_capture_channel.dart`/`MainActivity.kt`, iOS/macOS: AVFoundation)
   - `native_opus_encoder.dart`: Native Opus encoding via opus_dart/opus_flutter FFI (all platforms)
   - `native_h264_encoder.dart`: VideoToolbox H.264 encoding for macOS/iOS
   - fMP4 muxing for H.264 (baseline, ultrafast) and Opus (48kHz, 128kbps)
   - `streaming_playback.dart`: Media decode/playback pipeline routing CMAF/moq-mi streams to players
   - `moq_media_decoder.dart`: Decodes moq-mi (extension headers) and raw LOC (no headers, infers type from track name) to MediaFrames
   - Video player integration with media_kit
   - `lib/moq/media/fmp4/`: CMAF/fMP4 segment packaging (H.264, Opus, AAC muxers)

8. **State Management** (`lib/providers/moq_providers.dart`)
   - Riverpod providers for MoQ client state

### Native Rust Library

The `native/moq_quic/` directory contains a Rust library using Quinn for QUIC transport:
- Compiled automatically during `flutter run` or `flutter build`
- Platform-specific build handled by `tool/build_rust.dart` (Linux: cargo, macOS: lipo universal binary, Android: Gradle, iOS: Xcode)
- Two transport stacks in one library: raw QUIC (`lib.rs`) and WebTransport (`webtransport.rs`)
- `stream_writer.rs`: Non-blocking write queue via mpsc channel per stream
- `media_player.rs`: Embedded mpv player with custom `moqbuffer://` stream protocol and 16MB ring buffer
- Key Cargo deps: `quinn 0.11.9`, `web-transport-quinn 0.11.6`, `libmpv2-sys`, `dashmap`, `parking_lot`
- QUIC transport uses 2MB receive buffer, datagrams enabled (RFC 9221), 30s idle timeout, 4s keepalive
- Datagram buffer capped at 1000 entries before dropping

### Key Protocol Details

**Control messages**: Type-Length-Value format: `type (varint) + length (16-bit) + payload`

**Data streams**: Stream type prefix byte encodes flags via bitfield:
- Bit 0 (LSB): extensions present
- Type >= 0x18: end-of-group
- Types 0x14/0x15/0x1C/0x1D: explicit Subgroup ID
- Types 0x12/0x13/0x1A/0x1B: Subgroup ID = first Object ID

**Draft versions**: `0xff000000 + draft_number`. Draft-14 = `0xff00000e`, Draft-16 = `0xff000010`. `MoQVersion` class provides `isDraft16OrLater()` and `usesDeltaKvp()` helpers.

**Int64 usage**: `package:fixnum` `Int64` is used throughout for group IDs, object IDs, and timestamps to ensure correct 64-bit arithmetic across all platforms.

### Test Infrastructure

**Unit tests** use `MockMoQTransport` (in `test/moq/client/mock_transport.dart`):
- Captures sent messages in `sentControlMessages` and `sentStreamData`
- `onControlMessageSent` callback injects server responses via `Future.microtask()` to simulate async network behavior
- `simulateIncomingControlData` / `simulateIncomingDataStream` trigger receive paths
- Message type matching is done by inspecting the first byte of serialized data (e.g., `data[0] == 0x20` for CLIENT_SETUP)

**Protocol tests**: `wire_format_test.dart`, `control_messages_test.dart`, `control_messages_v16_test.dart`, `data_messages_test.dart`, `data_parser_test.dart`

**Catalog tests**: `moq_catalog_test.dart` (JSON parsing, format field), `moq_catalog_subscriber_test.dart` (subscription flow), `moq_timeline_test.dart` (seeking/playback)

**Publisher tests**: `msf_cmsf_publisher_test.dart` (CMAF publisher behavior, init segments, PUBLISH_DONE)

**Media tests**: `streaming_playback_test.dart` (decode/playback pipeline)

**Client integration tests**: `client_integration_test.dart` (full client lifecycle with MockMoQTransport)

**Live interop tests** (`test/moq/client/live_interop_test.dart`): Connect to real relays for draft-14/16 interop validation. Gated by `MOQ_LIVE_INTEROP=1` env var. Configurable via `MOQ_LIVE_HOST`, `MOQ_LIVE_PORT`, `MOQ_LIVE_VERSION`, `MOQ_LIVE_ALPN`, `MOQ_LIVE_INSECURE`.

**Relay datagram tests** (`test/moq/client/relay_datagram_test.dart`): Validate datagram support at both QUIC transport (`max_datagram_frame_size`) and WebTransport/H3 (`SETTINGS_H3_DATAGRAM`) levels. Gated by `MOQ_DATAGRAM_TEST=1`. Configurable via `MOQ_RELAY_HOST`, `MOQ_RELAY_PORT`, `MOQ_RELAY_PATH`, `MOQ_RELAY_VERSION`, `MOQ_RELAY_INSECURE`, `MOQ_RELAY_ALPN`. Requires native Rust library. The QUIC test connects with `h3` ALPN to check the transport parameter; the WebTransport test performs the full H3 session setup including `WT-Available-Protocols` negotiation and `SETTINGS_H3_DATAGRAM` exchange.

### Reference Specifications

Draft specs and RFCs are stored as `.txt` files in `docs/` for easy parsing. Key specs:
- `draft-ietf-moq-transport-14.txt`: Primary spec (draft-14)
- `draft-ietf-moq-transport-16.txt`: Primary spec (draft-16)
- `draft-cenzano-moq-media-interop-03.txt`: moq-mi packaging spec
- `draft-ietf-moq-msf-00.txt`: MSF - MOQT Streaming Format (supersedes WARP/CARP/catalogformat)
- `draft-ietf-moq-cmsf-00.txt`: CMSF - CMAF Streaming Format (extends MSF)
- `draft-ietf-moq-loc-01.txt`: LOC container spec
- `rfc9221.txt`: QUIC Datagrams (implemented)
- `draft-ietf-moq-catalogformat-01.txt` / `draft-wilaw-moq-catalogformat-02.txt`: Legacy catalog format (superseded by MSF/CMSF)
- `draft-law-moq-carp-00.txt`: Legacy CARP streaming (superseded by CMSF)
