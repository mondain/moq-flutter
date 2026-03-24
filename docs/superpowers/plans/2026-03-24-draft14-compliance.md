# Draft-14 CMSF/CMAF Compliance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring moq-flutter's CmafPublisher to parity with the moqxr reference CLI for draft-14 CMSF/CMAF publishing, catalog format, subscription handling, and lifecycle management.

**Architecture:** Five focused changes across catalog format, init segment publishing, subscription filter enforcement, PUBLISH_DONE lifecycle, and auto-forward publishing mode. Each task is independently testable and can be committed separately. Task 6 (auto-forward) is highest risk and should be executed last.

**Tech Stack:** Dart/Flutter, Rust (native lib unchanged), MoQ Transport draft-14, CMSF/CMAF packaging

**Note on initData:** The existing `_refreshCatalogInitData()` method (cmaf_publisher.dart:512-527) already populates `initData` from the muxer after codec discovery and re-publishes the catalog. No separate task needed for initData embedding -- it is already implemented.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/moq/catalog/moq_catalog.dart` | Modify | Add `format` field, parse on deserialize |
| `lib/moq/publisher/cmaf_publisher.dart` | Modify | Init segment publishing, PUBLISH_DONE, filter enforcement, auto-forward mode |
| `lib/moq/client/moq_client.dart` | Modify | Add `sendPublish()` method for auto-forward (Task 5) |
| `lib/moq/protocol/moq_messages_control_extra.dart` | Read-only | `PublishMessage`/`PublishOkMessage` already exist here |
| `test/moq/catalog/moq_catalog_test.dart` | Modify | Catalog format field tests |
| `test/moq/publisher/msf_cmsf_publisher_test.dart` | Modify | Extend with CmafPublisher behavior tests |

---

### Task 1: Add `format` field to MoQCatalog

moqxr emits `"format": "cmsf"` at the top level of catalog JSON. Our catalog omits this field. Subscribers that check for it will fail to identify the packaging format. The format value must match the selected packaging: `"cmsf"` for CMAF/CMSF, `"loc"` for LOC. The `MoQCatalog.cmaf()` factory should set `format: 'cmsf'` and `MoQCatalog.loc()` should set `format: 'loc'`. The moq-mi publisher does not use MoQCatalog, so no change needed there. The default MoQCatalog constructor accepts an optional `format` for custom use cases.

**Files:**
- Modify: `lib/moq/catalog/moq_catalog.dart:8-109`
- Modify: `test/moq/catalog/moq_catalog_test.dart`

- [ ] **Step 1: Write failing tests for format field**

```dart
test('cmaf catalog includes format field set to cmsf', () {
  final catalog = MoQCatalog.cmaf(
    namespace: 'test',
    tracks: [CatalogTrack(name: 'video0', packaging: 'cmaf', role: 'video')],
  );
  final json = jsonDecode(catalog.toJson()) as Map<String, dynamic>;
  expect(json['format'], equals('cmsf'));
});

test('loc catalog includes format field set to loc', () {
  final catalog = MoQCatalog.loc(
    namespace: 'test',
    tracks: [CatalogTrack(name: 'video', packaging: 'loc', role: 'video')],
  );
  final json = jsonDecode(catalog.toJson()) as Map<String, dynamic>;
  expect(json['format'], equals('loc'));
});

test('default catalog omits format field when not set', () {
  final catalog = MoQCatalog(tracks: [CatalogTrack(name: 'v0')]);
  final json = jsonDecode(catalog.toJson()) as Map<String, dynamic>;
  expect(json.containsKey('format'), isFalse);
});

test('parses format field from JSON', () {
  final json = '{"version":1,"format":"cmsf","tracks":[{"name":"v0"}]}';
  final catalog = MoQCatalog.fromJson(json);
  expect(catalog.format, equals('cmsf'));
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/moq/catalog/moq_catalog_test.dart -v --name "format field"`
Expected: FAIL - `format` field/property does not exist

- [ ] **Step 3: Add `format` field to MoQCatalog**

In `lib/moq/catalog/moq_catalog.dart`:

Add field to class:
```dart
final String? format;
```

Add to constructor: accept optional `this.format`.

Update factories:
- `MoQCatalog.cmaf()`: pass `format: 'cmsf'` to constructor
- `MoQCatalog.loc()`: pass `format: 'loc'` to constructor

Add to `toJson()` (emit before `tracks`, only if non-null):
```dart
if (format != null) 'format': format,
```

Add to `fromJson()`:
```dart
format: json['format'] as String?,
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/moq/catalog/moq_catalog_test.dart -v`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add lib/moq/catalog/moq_catalog.dart test/moq/catalog/moq_catalog_test.dart
git commit -m "Add format field to MoQCatalog for CMSF interop"
```

---

### Task 2: Publish init segment on media tracks (group 0, object 0)

moqxr publishes each media track's init segment (ftyp+moov) as the first object (group 0, object 0) on that track, in addition to embedding `initData` in the catalog. Our CmafPublisher only publishes init via the catalog `initData` field. Subscribers that fetch the media track stream directly will miss the init segment.

Group 0 is safe to use for init because `_currentGroupId` is seeded with a random value via `_randomGroupSeed()` (values up to 2^30), so media groups never start at 0. No changes needed to `_publishMediaSegment()`.

**Files:**
- Modify: `lib/moq/publisher/cmaf_publisher.dart` (add `_publishInitSegments()`, call from `_maybePublishInitSegment()`)
- Modify: `test/moq/publisher/msf_cmsf_publisher_test.dart`

- [ ] **Step 1: Write failing test**

In `test/moq/publisher/msf_cmsf_publisher_test.dart`, add a test that verifies init segment objects are published on each media track. The test must use MockMoQTransport, create a CmafPublisher, configure tracks, simulate the full announce + codec discovery flow (calling `publishVideoFrame` with SPS/PPS data to trigger muxer readiness), then verify that a stream was written with groupId=0 and objectId=0 carrying the init segment bytes:

```dart
test('publishes init segment as group 0 object 0 on media tracks', () async {
  final transport = MockMoQTransport();
  final client = MoQClient(transport: transport);
  final publisher = CmafPublisher(client: client);

  publisher.configureVideoTrack(
    name: 'video0', width: 1280, height: 720, frameRate: 30,
  );
  publisher.configureAudioTrack(name: 'audio0', sampleRate: 48000, channels: 2);

  // Mock: accept PUBLISH_NAMESPACE_OK on control message send
  transport.onControlMessageSent = (data) {
    if (data[0] == 0x06) { // PUBLISH_NAMESPACE
      Future.microtask(() => transport.simulateIncomingControlData(
        PublishNamespaceOkMessage(requestId: Int64(0)).serialize()));
    }
  };

  await publisher.announce(['test']);

  // Publish a keyframe to trigger codec discovery and init segment generation
  final spsNalu = Uint8List.fromList([0x00, 0x00, 0x00, 0x01, 0x67, /* SPS data */]);
  final ppsNalu = Uint8List.fromList([0x00, 0x00, 0x00, 0x01, 0x68, /* PPS data */]);
  final idrNalu = Uint8List.fromList([0x00, 0x00, 0x00, 0x01, 0x65, /* IDR data */]);
  final frameData = Uint8List.fromList([...spsNalu, ...ppsNalu, ...idrNalu]);
  await publisher.publishVideoFrame('video0', frameData, isKeyframe: true);

  // Verify init segment was published on media track at group 0, object 0
  // (Check transport.sentStreamData for a subgroup header with groupId=0)
  final initStreams = transport.sentStreamData
      .where((chunk) => /* parse header for groupId == 0 */)
      .toList();
  expect(initStreams, isNotEmpty,
      reason: 'Init segment should be published as group 0 object 0');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/moq/publisher/msf_cmsf_publisher_test.dart -v --name "init segment"`
Expected: FAIL - no init segment published on media track

- [ ] **Step 3: Add `_publishInitOnMediaTracks()` method to CmafPublisher**

In `lib/moq/publisher/cmaf_publisher.dart`, add method:

```dart
/// Publish init segments as group 0, object 0 on each media track.
/// Matches moqxr behavior: init is available both in catalog initData
/// AND as the first object on each media track stream.
Future<void> _publishInitOnMediaTracks() async {
  for (final config in _trackConfigs.values) {
    final track = _tracks[config.name];
    if (track == null) continue;

    Uint8List? initSegment;
    if (track is CmafVideoTrack && track.muxer.isInitReady) {
      initSegment = track.muxer.initSegment;
    } else if (track is CmafAudioTrack) {
      initSegment = track.muxer.initSegment;
    }

    if (initSegment == null || initSegment.isEmpty) continue;

    final streamId = await _client.openDataStream();
    await _client.writeSubgroupHeader(
      streamId,
      trackAlias: track.alias,
      groupId: Int64.ZERO,
      subgroupId: Int64.ZERO,
      publisherPriority: track.priority,
    );
    await _client.writeObject(
      streamId,
      objectId: Int64.ZERO,
      payload: initSegment,
      status: ObjectStatus.endOfGroup,
    );
    await _client.finishDataStream(streamId);
    _logger.i('Published init segment on ${config.name} '
        '(${initSegment.length} bytes)');
  }
}
```

Call `_publishInitOnMediaTracks()` from `_maybePublishInitSegment()` (around line 505) after `_refreshCatalogInitData()` and before `_publishCatalog()`, so init segments are published on media tracks at the same time as the catalog is updated with initData.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/moq/publisher/msf_cmsf_publisher_test.dart -v --name "init segment"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/moq/publisher/cmaf_publisher.dart test/moq/publisher/msf_cmsf_publisher_test.dart
git commit -m "Publish init segment as group 0 object 0 on each media track"
```

---

### Task 3: Send PUBLISH_DONE on publisher stop

moqxr sends `PUBLISH_DONE` (type 0x0b) with `status=0x00` (TRACK_ENDED per draft-14 Section 9.12) and `stream_count` when publishing completes. Our CmafPublisher's `stop()` method closes streams and cancels the namespace but never sends PUBLISH_DONE to active subscribers. This leaves subscribers hanging without a clean termination signal.

**Files:**
- Modify: `lib/moq/publisher/cmaf_publisher.dart:720-750` (`stop()`)
- Modify: `test/moq/publisher/msf_cmsf_publisher_test.dart`

- [ ] **Step 1: Write failing test**

```dart
test('stop() sends PUBLISH_DONE to all active subscribers', () async {
  final transport = MockMoQTransport();
  final client = MoQClient(transport: transport);
  final publisher = CmafPublisher(client: client);

  // Setup and announce...
  // Simulate a SUBSCRIBE being received and accepted...
  // Record the requestId from the accepted subscription

  await publisher.stop();

  // Verify PUBLISH_DONE was sent: parse sentControlMessages
  // looking for message type 0x0E (PublishDoneMessage type)
  final publishDoneMessages = transport.sentControlMessages
      .where((data) => data[0] == 0x0E)
      .toList();
  expect(publishDoneMessages, isNotEmpty,
      reason: 'PUBLISH_DONE should be sent for each active subscription');

  // Deserialize and verify fields
  final done = PublishDoneMessage.deserialize(publishDoneMessages.first);
  expect(done.statusCode, equals(0)); // TRACK_ENDED
  expect(done.streamCount, greaterThanOrEqualTo(Int64.ZERO));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/moq/publisher/msf_cmsf_publisher_test.dart -v --name "PUBLISH_DONE"`
Expected: FAIL - no PUBLISH_DONE sent

- [ ] **Step 3: Add PUBLISH_DONE to `stop()` and stream counting**

In `lib/moq/publisher/cmaf_publisher.dart`:

Add stream count tracker field:
```dart
int _publishedStreamCount = 0;
```

Increment in `_publishMediaSegment()` after opening each stream:
```dart
_publishedStreamCount++;
```

Modify `stop()` to send PUBLISH_DONE before closing streams:
```dart
Future<void> stop({String reason = 'Publisher stopped'}) async {
  await _subscribeSubscription?.cancel();
  _subscribeSubscription = null;

  // Send PUBLISH_DONE to all active subscribers
  for (final entry in _pendingSubscribes.entries) {
    try {
      await _client.sendPublishDone(
        entry.key,
        statusCode: 0, // TRACK_ENDED
        streamCount: Int64(_publishedStreamCount),
        reason: reason,
      );
    } catch (e) {
      _logger.w('Error sending PUBLISH_DONE for ${entry.key}: $e');
    }
  }

  // ... existing close/cleanup code ...
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/moq/publisher/msf_cmsf_publisher_test.dart -v --name "PUBLISH_DONE"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/moq/publisher/cmaf_publisher.dart test/moq/publisher/msf_cmsf_publisher_test.dart
git commit -m "Send PUBLISH_DONE to subscribers on CmafPublisher stop"
```

---

### Task 4: Enforce subscribe filter types when accepting subscriptions

moqxr checks all four filter types when serving objects:
- `FilterType.nextGroupStart` (0x1): Accept, serve from current position
- `FilterType.largestObject` (0x2): Accept, serve from latest published
- `FilterType.absoluteStart` (0x3): Accept, check if content exists at/beyond start location
- `FilterType.absoluteRange` (0x4): Accept, check content within [start, end] range

Our CmafPublisher accepts all subscriptions but computes `contentExists` and `largestLocation` without considering the filter's start/end constraints. This means SUBSCRIBE_OK responses may have incorrect `contentExists` values.

**Files:**
- Modify: `lib/moq/publisher/cmaf_publisher.dart:291-323` (`_acceptSubscription`)
- Modify: `test/moq/publisher/msf_cmsf_publisher_test.dart`

- [ ] **Step 1: Write failing test**

```dart
test('absoluteStart subscription with future group has contentExists=false', () async {
  final transport = MockMoQTransport();
  final client = MoQClient(transport: transport);
  final publisher = CmafPublisher(client: client);

  // Setup, announce, publish some frames to establish group IDs...

  // Simulate incoming SUBSCRIBE with absoluteStart filter, startGroup=999999
  final subscribeBytes = SubscribeMessage(
    requestId: Int64(1),
    trackNamespace: [Uint8List.fromList('test'.codeUnits)],
    trackName: Uint8List.fromList('video0'.codeUnits),
    subscriberPriority: 128,
    groupOrder: GroupOrder.ascending,
    forward: 1,
    filterType: FilterType.absoluteStart,
    startLocation: Location(group: Int64(999999), object: Int64.ZERO),
    parameters: [],
  ).serialize();
  transport.simulateIncomingControlData(subscribeBytes);

  // Wait for response
  await Future.delayed(Duration(milliseconds: 50));

  // Find SUBSCRIBE_OK in sent messages
  final okMessages = transport.sentControlMessages
      .where((data) => data[0] == 0x04) // SUBSCRIBE_OK
      .toList();
  expect(okMessages, isNotEmpty);

  final ok = SubscribeOkMessage.deserialize(okMessages.last);
  expect(ok.contentExists, equals(0),
      reason: 'No content exists at group 999999');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/moq/publisher/msf_cmsf_publisher_test.dart -v --name "absoluteStart"`
Expected: FAIL - contentExists is true regardless of filter

- [ ] **Step 3: Enhance `_acceptSubscription()` to honor filters**

In `lib/moq/publisher/cmaf_publisher.dart`, update `_acceptSubscription()`:

```dart
Future<void> _acceptSubscription(
  MoQSubscribeRequest request,
  String trackName,
) async {
  final track = _lookupTrack(trackName) ??
      _ensureMediaTrackPlaceholder(trackName,
          priority: _trackConfigs[trackName]?.priority ?? 128);
  if (track == null) {
    throw ArgumentError('Track not found: $trackName');
  }

  try {
    bool contentExists;
    Location? largestLocation;

    switch (request.filterType) {
      case FilterType.absoluteStart:
        final startGroup = request.startLocation?.group ?? Int64.ZERO;
        contentExists = track.currentGroupId > startGroup;
        largestLocation = contentExists
            ? Location(group: track.currentGroupId, object: track.currentObjectId)
            : null;
      case FilterType.absoluteRange:
        final startGroup = request.startLocation?.group ?? Int64.ZERO;
        final endGroup = request.endGroup ?? track.currentGroupId;
        contentExists = track.currentGroupId >= startGroup;
        largestLocation = contentExists
            ? Location(
                group: track.currentGroupId.compareTo(endGroup) <= 0
                    ? track.currentGroupId
                    : endGroup,
                object: track.currentObjectId)
            : null;
      default:
        // FilterType.largestObject, FilterType.nextGroupStart
        contentExists = _contentExistsForTrack(trackName, track);
        largestLocation = contentExists
            ? _largestPublishedLocation(trackName, track)
            : null;
    }

    await _client.acceptSubscribe(
      request.requestId,
      trackAlias: track.alias,
      expires: Int64(0),
      groupOrder: GroupOrder.ascending,
      contentExists: contentExists,
      largestLocation: largestLocation,
    );

    _pendingSubscribes[request.requestId] = request;
    _logger.i('Accepted SUBSCRIBE for $trackName '
        '(alias: ${track.alias}, filter: ${request.filterType})');
  } catch (e) {
    _logger.e('Failed to accept SUBSCRIBE: $e');
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/moq/publisher/msf_cmsf_publisher_test.dart -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/moq/publisher/cmaf_publisher.dart test/moq/publisher/msf_cmsf_publisher_test.dart
git commit -m "Honor subscribe filter types in CmafPublisher"
```

---

### Task 5: Add auto-forward publishing mode via PUBLISH messages

moqxr supports `--forward 1` mode where it proactively sends PUBLISH messages (type 0x1d) for each track after namespace ack, then publishes objects after receiving PUBLISH_OK. Our CmafPublisher only supports the await-subscribe model. Adding auto-forward gives relay compatibility for push-style relays.

**Risk:** This is the highest-risk task. It adds a new outbound method to MoQClient, adds a PUBLISH_OK response handler, and modifies the CmafPublisher constructor. Execute last.

**Files:**
- Modify: `lib/moq/client/moq_client.dart` (add `sendPublish()` method, PUBLISH_OK response handler)
- Read-only: `lib/moq/protocol/moq_messages_control_extra.dart` (`PublishMessage` at line 805 and `PublishOkMessage` at line 1161 already exist)
- Modify: `lib/moq/publisher/cmaf_publisher.dart` (add `autoForward` parameter and `_forwardPublishedTracks()`)
- Modify: `test/moq/publisher/msf_cmsf_publisher_test.dart`

- [ ] **Step 1: Verify `PublishMessage` and `PublishOkMessage` exist in protocol layer**

Confirm classes exist at `lib/moq/protocol/moq_messages_control_extra.dart` lines 805 and 1161. Verify `serialize()` and `deserialize()` methods are implemented and wire format matches draft-14:

PUBLISH (0x1d): `Type(i), Length(i), requestId(i), trackNamespace(tuple), trackName(len+bytes), trackAlias(i), groupOrder(8), contentExists(8), [largestLocation if contentExists], forwardPreference(8), paramCount(i), params...`

- [ ] **Step 2: Write failing test for auto-forward mode**

```dart
test('auto-forward mode sends PUBLISH for each track after announce', () async {
  final transport = MockMoQTransport();
  final client = MoQClient(transport: transport);
  final publisher = CmafPublisher(client: client, autoForward: true);

  publisher.configureVideoTrack(
    name: 'video0', width: 1280, height: 720, frameRate: 30,
  );

  // Mock PUBLISH_NAMESPACE_OK response
  transport.onControlMessageSent = (data) {
    if (data[0] == 0x06) { // PUBLISH_NAMESPACE
      Future.microtask(() => transport.simulateIncomingControlData(
        PublishNamespaceOkMessage(requestId: Int64(0)).serialize()));
    }
    // Mock PUBLISH_OK responses for PUBLISH messages
    if (data[0] == 0x1d) { // PUBLISH
      final msg = PublishMessage.deserialize(data);
      Future.microtask(() => transport.simulateIncomingControlData(
        PublishOkMessage(requestId: msg.requestId, /* ... */).serialize()));
    }
  };

  await publisher.announce(['test']);

  // Verify PUBLISH messages were sent (type byte 0x1d)
  final publishMessages = transport.sentControlMessages
      .where((data) => data[0] == 0x1d)
      .toList();
  expect(publishMessages.length, greaterThanOrEqualTo(2),
      reason: 'Should send PUBLISH for catalog + video0 at minimum');
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/moq/publisher/msf_cmsf_publisher_test.dart -v --name "auto-forward"`
Expected: FAIL - no PUBLISH messages sent, `autoForward` parameter doesn't exist

- [ ] **Step 4: Add `sendPublish()` method to MoQClient**

In `lib/moq/client/moq_client.dart`, add:

```dart
/// Send a PUBLISH message to proactively announce a track for forwarding.
/// Used in auto-forward mode. Returns when PUBLISH_OK is received.
Future<void> sendPublish({
  required List<Uint8List> trackNamespace,
  required Uint8List trackName,
  required Int64 trackAlias,
  GroupOrder groupOrder = GroupOrder.ascending,
  bool contentExists = false,
  Location? largestLocation,
}) async {
  final requestId = _nextRequestId;
  _nextRequestId += Int64(2);

  final message = PublishMessage(
    requestId: requestId,
    trackNamespace: trackNamespace,
    trackName: trackName,
    trackAlias: trackAlias,
    groupOrder: groupOrder,
    contentExists: contentExists ? 1 : 0,
    largestLocation: largestLocation,
    forwardPreference: 1,
    parameters: [],
  );
  await _transport.send(message.serialize(version: _selectedVersion));

  // Store pending publish and wait for PUBLISH_OK
  // (Add completer pattern similar to announceNamespace)
}
```

Also add a handler for incoming PUBLISH_OK (0x1e) messages in the control message dispatcher to complete the pending publish.

- [ ] **Step 5: Add `autoForward` parameter and `_forwardPublishedTracks()` to CmafPublisher**

In `lib/moq/publisher/cmaf_publisher.dart`:

Add constructor parameter:
```dart
CmafPublisher(this._client, {this.autoForward = false});
final bool autoForward;
```

Add method called from `announce()` after catalog publish when `autoForward` is true:
```dart
Future<void> _forwardPublishedTracks() async {
  if (!autoForward) return;

  final ns = _namespace!;
  // Send PUBLISH for catalog track
  final catalogTrack = _tracks[MoQCatalog.catalogTrackName];
  if (catalogTrack != null) {
    await _client.sendPublish(
      trackNamespace: ns,
      trackName: Uint8List.fromList(MoQCatalog.catalogTrackName.codeUnits),
      trackAlias: catalogTrack.alias,
      contentExists: _catalogPublished,
    );
  }

  // Send PUBLISH for each configured media track
  for (final config in _trackConfigs.values) {
    final track = _tracks[config.name];
    if (track == null) continue;
    await _client.sendPublish(
      trackNamespace: ns,
      trackName: Uint8List.fromList(config.name.codeUnits),
      trackAlias: track.alias,
    );
  }

  _logger.i('Forwarded ${_trackConfigs.length + 1} tracks via PUBLISH');
}
```

Call from `announce()` after `_publishCatalog()`:
```dart
if (autoForward) {
  await _forwardPublishedTracks();
} else {
  _startSubscribeHandler();
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `flutter test test/moq/publisher/msf_cmsf_publisher_test.dart -v`
Expected: PASS

- [ ] **Step 7: Run full test suite**

Run: `flutter test`
Expected: All pass (existing tests unaffected since `autoForward` defaults to false)

- [ ] **Step 8: Commit**

```bash
git add lib/moq/client/moq_client.dart lib/moq/publisher/cmaf_publisher.dart \
  test/moq/publisher/msf_cmsf_publisher_test.dart
git commit -m "Add auto-forward publishing mode via PUBLISH messages"
```

---

## Verification

After all tasks are complete:

- [ ] Run full test suite: `flutter test`
- [ ] Run `flutter analyze` to check for issues
- [ ] Test interop with moqxr by subscribing to a moqxr-published stream
- [ ] Test interop by publishing from moq-flutter and subscribing from moqxr (if supported)
