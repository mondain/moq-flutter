import 'dart:async';
import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:logger/logger.dart';
import '../protocol/moq_messages.dart';
import '../protocol/moq_data_parser.dart';
import '../transport/moq_transport.dart';
import '../packager/moq_mi_packager.dart';

/// MoQ Client implementation per draft-ietf-moq-transport-14
class MoQClient {
  final MoQTransport _transport;
  final Logger _logger;

  // Client state
  bool _isConnected = false;
  int _selectedVersion = 0;
  Int64 _nextRequestId = Int64(0); // Client uses even IDs starting from 0

  // Setup completer
  Completer<void>? _setupCompleter;

  // Active subscriptions
  final _subscriptions = <Int64, MoQSubscription>{};

  // Active namespace announcements (for publishing)
  final _namespaceAnnouncements = <Int64, MoQNamespaceAnnouncement>{};

  // Active namespace subscriptions (for discovery)
  final _namespaceSubscriptions = <Int64, MoQNamespaceSubscription>{};

  // Active fetches
  final _activeFetches = <Int64, MoQFetch>{};

  // Incoming publish requests (server mode)
  final _incomingPublishController = StreamController<MoQPublishRequest>.broadcast();
  final _pendingPublishRequests = <Int64, MoQPublishRequest>{};

  // Incoming subscribe requests (publisher mode)
  final _incomingSubscribeController = StreamController<MoQSubscribeRequest>.broadcast();
  final _pendingSubscribeRequests = <Int64, MoQSubscribeRequest>{};
  final _activePublisherSubscriptions = <Int64, MoQSubscribeRequest>{}; // Accepted subscriptions

  // Track aliases mapping
  final _trackAliases = <Int64, TrackInfo>{};

  // Data stream parsers (stream_id -> parser)
  final _dataStreamParsers = <int, MoQDataStreamParser>{};

  // Data stream subscription
  StreamSubscription<DataStreamChunk>? _dataStreamSubscription;

  // Datagram subscription
  StreamSubscription<Uint8List>? _datagramSubscription;

  // Control message buffer for incomplete messages
  final _controlBuffer = <int>[];

  // Message controllers
  final _messageController = StreamController<MoQMessage>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();
  final _goawayController = StreamController<GoawayEvent>.broadcast();

  // Setup parameters received from server
  final List<KeyValuePair> _serverSetupParameters = [];
  int _maxSubscriptionId = 0;
  int _maxTrackAlias = 0;

  // Request ID increment (by 2 for each request)
  Int64 _getNextRequestId() {
    final id = _nextRequestId;
    _nextRequestId += Int64(2);
    return id;
  }

  /// Get next request ID (for video player and other extensions)
  Int64 getNextRequestId() => _getNextRequestId();

  /// Get the underlying transport (for advanced usage)
  MoQTransport get transport => _transport;

  MoQClient({
    required MoQTransport transport,
    Logger? logger,
  })  : _transport = transport,
        _logger = logger ?? Logger();

  /// Connection state
  bool get isConnected => _isConnected;
  Stream<bool> get connectionStateStream => _connectionStateController.stream;

  /// Stream of all incoming messages
  Stream<MoQMessage> get messageStream => _messageController.stream;

  /// Get the selected protocol version
  int get selectedVersion => _selectedVersion;

  /// Get server setup parameters
  List<KeyValuePair> get serverSetupParameters => List.unmodifiable(_serverSetupParameters);

  /// Get max subscription ID from server
  int get maxSubscriptionId => _maxSubscriptionId;

  /// Get max track alias from server
  int get maxTrackAlias => _maxTrackAlias;

  /// Stream of incoming PUBLISH requests (server mode)
  ///
  /// Listen to this stream to receive PUBLISH requests from publishers.
  /// Use [acceptPublish] or [rejectPublish] to respond.
  Stream<MoQPublishRequest> get incomingPublishRequests => _incomingPublishController.stream;

  /// Stream of incoming SUBSCRIBE requests (publisher mode)
  ///
  /// Listen to this stream to receive SUBSCRIBE requests from subscribers/relays.
  /// Use [acceptSubscribe] or [rejectSubscribe] to respond.
  Stream<MoQSubscribeRequest> get incomingSubscribeRequests => _incomingSubscribeController.stream;

  /// Get active publisher subscriptions (tracks being published to subscribers)
  Map<Int64, MoQSubscribeRequest> get activePublisherSubscriptions =>
      Map.unmodifiable(_activePublisherSubscriptions);

  /// Get active subscriber subscriptions (tracks we're subscribed to)
  Map<Int64, MoQSubscription> get subscriptions =>
      Map.unmodifiable(_subscriptions);

  /// Stream of GOAWAY events
  ///
  /// Listen to this stream to receive GOAWAY messages from the server.
  /// When received, the client should gracefully close and optionally
  /// reconnect to the new URI if provided.
  Stream<GoawayEvent> get goawayEvents => _goawayController.stream;

  /// Connect to a MoQ server
  Future<void> connect(String host, int port,
      {List<int>? supportedVersions, Map<String, String>? options}) async {
    if (_isConnected) {
      _logger.w('Already connected');
      return;
    }

    _logger.i('Connecting to $host:$port');

    // Setup completer for waiting on SERVER_SETUP
    _setupCompleter = Completer<void>();

    // Listen for incoming control data
    try {
      _transport.incomingData.listen(
        _handleIncomingData,
        onError: (error) {
          _logger.e('Transport error: $error');
          if (_setupCompleter != null && !_setupCompleter!.isCompleted) {
            _setupCompleter!.completeError(
              MoQException(errorCode: -1, reason: 'Transport error: $error'),
            );
          }
        },
        onDone: () {
          _logger.i('Transport closed');
          _isConnected = false;
          if (!_connectionStateController.isClosed) {
            _connectionStateController.add(false);
          }
          if (_setupCompleter != null && !_setupCompleter!.isCompleted) {
            _setupCompleter!.completeError(
              MoQException(errorCode: -1, reason: 'Transport closed'),
            );
          }
        },
      );

      // Listen for incoming data streams (SUBGROUP_HEADER + objects)
      _dataStreamSubscription = _transport.incomingDataStreams.listen(
        _handleDataStreamChunk,
        onError: (error) {
          _logger.e('Data stream error: $error');
        },
      );

      // Listen for incoming datagrams (OBJECT_DATAGRAM messages)
      _datagramSubscription = _transport.incomingDatagrams.listen(
        _handleDatagram,
        onError: (error) {
          _logger.e('Datagram error: $error');
        },
      );
    } catch (e) {
      _logger.e('Failed to listen to transport: $e');
      _setupCompleter!.completeError(
        MoQException(errorCode: -1, reason: 'Failed to listen: $e'),
      );
      rethrow;
    }

    // Connect to transport
    try {
      await _transport.connect(host, port, options: options);
    } catch (e) {
      _setupCompleter!.completeError(
        MoQException(errorCode: -1, reason: 'Failed to connect: $e'),
      );
      rethrow;
    }

    // Send CLIENT_SETUP message
    // Draft versions use 0xff000000 + draft number format per spec section 9.3.1
    // Draft-14 = 0xff00000E (confirmed by moqt.js reference implementation)
    final versions = supportedVersions ?? [0xff00000e]; // Draft-14

    // MAX_REQUEST_ID parameter is required per FB reference implementation
    // Value of 128 matches moqt.js MOQ_MAX_REQUEST_ID_NUM
    final setupMessage = ClientSetupMessage(
      supportedVersions: versions,
      parameters: [
        KeyValuePair.varint(SetupParameterType.maxRequestId, 128),
      ],
    );

    final setupBytes = setupMessage.serialize();
    _logger.d('CLIENT_SETUP bytes (${setupBytes.length}): ${setupBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
    await _transport.send(setupBytes);
    _logger.d('Sent CLIENT_SETUP with versions: $versions');

    // Wait for SERVER_SETUP response (with timeout)
    try {
      await _setupCompleter!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('SERVER_SETUP response timeout');
        },
      );
    } catch (e) {
      _logger.e('Setup failed: $e');
      await disconnect();
      rethrow;
    }

    _isConnected = true;
    _connectionStateController.add(true);
    _logger.i('Connected successfully (version: $_selectedVersion)');
  }

  /// Disconnect from the server
  Future<void> disconnect() async {
    if (!_isConnected) return;

    _logger.i('Disconnecting');

    // Complete setup completer if still pending
    if (_setupCompleter != null && !_setupCompleter!.isCompleted) {
      _setupCompleter!.completeError(
        MoQException(errorCode: -1, reason: 'Connection closed during setup'),
      );
    }
    _setupCompleter = null;

    // Send GOAWAY if needed
    // TODO: Implement proper GOAWAY

    await _transport.disconnect();
    _isConnected = false;

    // Cancel data stream subscription
    await _dataStreamSubscription?.cancel();
    _dataStreamSubscription = null;
    _dataStreamParsers.clear();

    // Cancel datagram subscription
    await _datagramSubscription?.cancel();
    _datagramSubscription = null;

    for (final sub in _subscriptions.values) {
      await sub.close();
    }
    _subscriptions.clear();
    _trackAliases.clear();

    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(false);
    }
  }

  /// Subscribe to a track
  Future<SubscribeResult> subscribe(
    List<Uint8List> trackNamespace,
    Uint8List trackName, {
    FilterType filterType = FilterType.largestObject,
    Location? startLocation,
    Int64? endGroup,
    int subscriberPriority = 128,
    GroupOrder groupOrder = GroupOrder.none,
    bool forward = true,
  }) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    final requestId = _getNextRequestId();

    _logger.i('Subscribing to track: ${String.fromCharCodes(trackName)}');

    final subscribeMessage = SubscribeMessage(
      requestId: requestId,
      trackNamespace: trackNamespace,
      trackName: trackName,
      subscriberPriority: subscriberPriority,
      groupOrder: groupOrder,
      forward: forward ? 1 : 0,
      filterType: filterType,
      startLocation: startLocation,
      endGroup: endGroup,
    );

    await _transport.send(subscribeMessage.serialize());

    // Create subscription object (will be completed when SUBSCRIBE_OK arrives)
    final subscription = MoQSubscription(
      client: this,
      id: requestId,
      trackNamespace: trackNamespace,
      trackName: trackName,
    );

    _subscriptions[requestId] = subscription;

    // Wait for SUBSCRIBE_OK or SUBSCRIBE_ERROR
    return await subscription.waitForResponse();
  }

  /// Update an existing subscription
  Future<void> updateSubscription(
    Int64 subscriptionId, {
    Location? startLocation,
    Int64? endGroup,
    int? subscriberPriority,
    bool? forward,
  }) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    final subscription = _subscriptions[subscriptionId];
    if (subscription == null) {
      throw ArgumentError('Subscription not found: $subscriptionId');
    }

    final requestId = _getNextRequestId();

    final updateMessage = SubscribeUpdateMessage(
      requestId: requestId,
      subscriptionRequestId: subscriptionId,
      startLocation: startLocation ?? subscription.currentStart,
      endGroup: endGroup ?? subscription.currentEndGroup,
      subscriberPriority: subscriberPriority ?? subscription.priority,
      forward: (forward ?? subscription.forward) ? 1 : 0,
    );

    await _transport.send(updateMessage.serialize());

    // Update subscription state
    if (startLocation != null) {
      subscription.currentStart = startLocation;
    }
    if (endGroup != null) {
      subscription.currentEndGroup = endGroup;
    }
    if (subscriberPriority != null) {
      subscription.priority = subscriberPriority;
    }
    if (forward != null) {
      subscription.forward = forward;
    }
  }

  /// Unsubscribe from a track
  Future<void> unsubscribe(Int64 subscriptionId) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    final unsubscribeMessage = UnsubscribeMessage(requestId: subscriptionId);
    await _transport.send(unsubscribeMessage.serialize());

    final subscription = _subscriptions.remove(subscriptionId);
    if (subscription != null) {
      await subscription.close();
    }
  }

  /// Announce a namespace for publishing
  ///
  /// This sends PUBLISH_NAMESPACE and waits for PUBLISH_NAMESPACE_OK.
  /// Returns the request ID for this namespace announcement.
  Future<Int64> announceNamespace(
    List<Uint8List> trackNamespace, {
    List<KeyValuePair>? parameters,
  }) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    final requestId = _getNextRequestId();

    _logger.i('Announcing namespace: ${trackNamespace.map((n) => String.fromCharCodes(n)).join("/")}');

    final message = PublishNamespaceMessage(
      requestId: requestId,
      trackNamespace: trackNamespace,
      parameters: parameters ?? [],
    );

    await _transport.send(message.serialize());

    // Create announcement object (will be completed when PUBLISH_NAMESPACE_OK arrives)
    final announcement = MoQNamespaceAnnouncement(
      client: this,
      requestId: requestId,
      trackNamespace: trackNamespace,
    );

    _namespaceAnnouncements[requestId] = announcement;

    // Wait for response
    await announcement.waitForResponse();

    return requestId;
  }

  /// Subscribe to a namespace for discovery
  ///
  /// This sends SUBSCRIBE_NAMESPACE and waits for SUBSCRIBE_NAMESPACE_OK.
  /// Returns a MoQNamespaceSubscription for tracking incoming PUBLISH_NAMESPACE
  /// and PUBLISH messages.
  Future<MoQNamespaceSubscription> subscribeNamespace(
    List<Uint8List> trackNamespacePrefix, {
    List<KeyValuePair>? parameters,
  }) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    final requestId = _getNextRequestId();

    _logger.i('Subscribing to namespace: ${trackNamespacePrefix.map((n) => String.fromCharCodes(n)).join("/")}');

    final message = SubscribeNamespaceMessage(
      requestId: requestId,
      trackNamespacePrefix: trackNamespacePrefix,
      parameters: parameters ?? [],
    );

    await _transport.send(message.serialize());

    // Create subscription object (will be completed when SUBSCRIBE_NAMESPACE_OK arrives)
    final subscription = MoQNamespaceSubscription(
      client: this,
      requestId: requestId,
      trackNamespacePrefix: trackNamespacePrefix,
    );

    _namespaceSubscriptions[requestId] = subscription;

    // Wait for response
    await subscription.waitForResponse();

    return subscription;
  }

  /// Unsubscribe from a namespace
  Future<void> unsubscribeNamespace(List<Uint8List> trackNamespacePrefix) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    _logger.i('Unsubscribing from namespace: ${trackNamespacePrefix.map((n) => String.fromCharCodes(n)).join("/")}');

    final message = UnsubscribeNamespaceMessage(
      trackNamespacePrefix: trackNamespacePrefix,
    );

    await _transport.send(message.serialize());

    // Remove matching subscription
    _namespaceSubscriptions.removeWhere((_, sub) {
      if (sub.trackNamespacePrefix.length != trackNamespacePrefix.length) {
        return false;
      }
      for (int i = 0; i < sub.trackNamespacePrefix.length; i++) {
        if (!_bytesEqual(sub.trackNamespacePrefix[i], trackNamespacePrefix[i])) {
          return false;
        }
      }
      return true;
    });
  }

  /// Fetch past objects from a track (standalone fetch)
  ///
  /// Retrieves objects from [startLocation] to [endLocation] (inclusive).
  /// Use this when you need objects that were already published.
  ///
  /// Per draft-14 Section 9.16, FETCH is for retrieving past objects,
  /// while SUBSCRIBE is for receiving new objects.
  Future<FetchResult> fetch(
    List<Uint8List> trackNamespace,
    Uint8List trackName, {
    required Location startLocation,
    required Location endLocation,
    int subscriberPriority = 128,
    GroupOrder groupOrder = GroupOrder.none,
    List<KeyValuePair>? parameters,
  }) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    final requestId = _getNextRequestId();

    _logger.i('Fetching from track: ${String.fromCharCodes(trackName)} '
        'range ${startLocation.group}:${startLocation.object} to '
        '${endLocation.group}:${endLocation.object}');

    final message = FetchMessage.standalone(
      requestId: requestId,
      trackNamespace: trackNamespace,
      trackName: trackName,
      startLocation: startLocation,
      endLocation: endLocation,
      subscriberPriority: subscriberPriority,
      groupOrder: groupOrder,
      parameters: parameters ?? [],
    );

    await _transport.send(message.serialize());

    // Create fetch object (will be completed when FETCH_OK arrives)
    final fetch = MoQFetch(
      client: this,
      requestId: requestId,
      fetchType: FetchType.standalone,
      trackNamespace: trackNamespace,
      trackName: trackName,
      startLocation: startLocation,
      requestedEndLocation: endLocation,
    );

    _activeFetches[requestId] = fetch;

    // Wait for FETCH_OK or FETCH_ERROR
    return await fetch.waitForResponse();
  }

  /// Fetch past objects relative to an active subscription (relative joining fetch)
  ///
  /// Retrieves [groupCount] groups back from the subscription's current position.
  /// The fetch range will be contiguous with the subscription.
  ///
  /// For example, if the subscription is at group 100 and groupCount is 5,
  /// the fetch will retrieve groups 95-99.
  Future<FetchResult> joiningFetchRelative(
    Int64 subscriptionRequestId, {
    required int groupCount,
    int subscriberPriority = 128,
    GroupOrder groupOrder = GroupOrder.none,
    List<KeyValuePair>? parameters,
  }) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    final requestId = _getNextRequestId();

    _logger.i('Joining fetch (relative): subscription ${subscriptionRequestId}, '
        '$groupCount groups back');

    final message = FetchMessage.relativeJoining(
      requestId: requestId,
      joiningRequestId: subscriptionRequestId,
      joiningStart: Int64(groupCount),
      subscriberPriority: subscriberPriority,
      groupOrder: groupOrder,
      parameters: parameters ?? [],
    );

    await _transport.send(message.serialize());

    final fetch = MoQFetch(
      client: this,
      requestId: requestId,
      fetchType: FetchType.relativeJoining,
      joiningRequestId: subscriptionRequestId,
      joiningStart: Int64(groupCount),
    );

    _activeFetches[requestId] = fetch;

    return await fetch.waitForResponse();
  }

  /// Fetch past objects with absolute start location (absolute joining fetch)
  ///
  /// Retrieves objects from [startLocation] to the subscription's current position.
  /// The fetch range will be contiguous with the subscription.
  Future<FetchResult> joiningFetchAbsolute(
    Int64 subscriptionRequestId, {
    required Location startLocation,
    int subscriberPriority = 128,
    GroupOrder groupOrder = GroupOrder.none,
    List<KeyValuePair>? parameters,
  }) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    final requestId = _getNextRequestId();

    // Encode start location as a single Int64 for the message
    // This is the raw group value; the spec uses it differently
    final joiningStart = startLocation.group;

    _logger.i('Joining fetch (absolute): subscription ${subscriptionRequestId}, '
        'from group ${startLocation.group}');

    final message = FetchMessage.absoluteJoining(
      requestId: requestId,
      joiningRequestId: subscriptionRequestId,
      joiningStart: joiningStart,
      subscriberPriority: subscriberPriority,
      groupOrder: groupOrder,
      parameters: parameters ?? [],
    );

    await _transport.send(message.serialize());

    final fetch = MoQFetch(
      client: this,
      requestId: requestId,
      fetchType: FetchType.absoluteJoining,
      joiningRequestId: subscriptionRequestId,
      joiningStart: joiningStart,
      startLocation: startLocation,
    );

    _activeFetches[requestId] = fetch;

    return await fetch.waitForResponse();
  }

  /// Cancel an active fetch
  ///
  /// Sends FETCH_CANCEL to stop receiving objects from the specified fetch.
  Future<void> cancelFetch(Int64 requestId) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    final fetch = _activeFetches.remove(requestId);
    if (fetch == null) {
      _logger.w('No active fetch found for request: $requestId');
      return;
    }

    _logger.i('Canceling fetch: $requestId');

    final message = FetchCancelMessage(requestId: requestId);
    await _transport.send(message.serialize());

    fetch.cancel();
  }

  /// Open a data stream for publishing objects
  ///
  /// Returns a stream ID that can be used with streamWrite and streamFinish.
  Future<int> openDataStream() async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    return await _transport.openStream();
  }

  /// Write subgroup header to a stream
  ///
  /// Per MoQ spec, each subgroup stream starts with SUBGROUP_HEADER (0x10).
  Future<void> writeSubgroupHeader(
    int streamId, {
    required Int64 trackAlias,
    required Int64 groupId,
    required Int64 subgroupId,
    required int publisherPriority,
  }) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    // Build subgroup header
    final header = SubgroupHeaderMessage(
      trackAlias: trackAlias,
      groupId: groupId,
      subgroupId: subgroupId,
      publisherPriority: publisherPriority,
    );

    await _transport.streamWrite(streamId, header.serialize());
    _logger.d('Wrote subgroup header to stream $streamId');
  }

  /// Write a media object to a stream
  Future<void> writeObject(
    int streamId, {
    required Int64 objectId,
    required Uint8List payload,
    ObjectStatus status = ObjectStatus.normal,
  }) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    // Build object payload
    // Format: object_id (varint) + object_status (varint) + payload
    final objectIdBytes = MoQWireFormat.encodeVarint64(objectId);
    final statusBytes = MoQWireFormat.encodeVarint(status.value);

    final data = Uint8List(objectIdBytes.length + statusBytes.length + payload.length);
    int offset = 0;
    data.setAll(offset, objectIdBytes);
    offset += objectIdBytes.length;
    data.setAll(offset, statusBytes);
    offset += statusBytes.length;
    data.setAll(offset, payload);

    await _transport.streamWrite(streamId, data);
    _logger.d('Wrote object $objectId (${payload.length} bytes) to stream $streamId');
  }

  /// Write subgroup header with extension headers to a stream
  ///
  /// This is used for moq-mi and other LOC-based packaging formats
  /// that carry metadata in extension headers.
  Future<void> writeSubgroupHeaderWithExtensions(
    int streamId, {
    required Int64 trackAlias,
    required Int64 groupId,
    required Int64 subgroupId,
    required int publisherPriority,
    required List<KeyValuePair> extensionHeaders,
  }) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    final header = SubgroupHeaderMessage(
      trackAlias: trackAlias,
      groupId: groupId,
      subgroupId: subgroupId,
      publisherPriority: publisherPriority,
      extensionHeaders: extensionHeaders,
    );

    await _transport.streamWrite(streamId, header.serialize());
    _logger.d('Wrote subgroup header with ${extensionHeaders.length} extension headers to stream $streamId');
  }

  /// Write a media object with extension headers to a stream
  ///
  /// This is used for moq-mi and other LOC-based packaging formats
  /// that carry per-object metadata in extension headers.
  Future<void> writeObjectWithExtensions(
    int streamId, {
    required Int64 objectId,
    required Uint8List payload,
    ObjectStatus status = ObjectStatus.normal,
    required List<KeyValuePair> extensionHeaders,
  }) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    // Build object with extension headers
    // Format: object_id (varint) + object_status (varint) + num_headers (varint) + headers + payload
    final objectIdBytes = MoQWireFormat.encodeVarint64(objectId);
    final statusBytes = MoQWireFormat.encodeVarint(status.value);
    final numHeadersBytes = MoQWireFormat.encodeVarint(extensionHeaders.length);

    // Calculate extension headers size
    int extensionSize = 0;
    final headerParts = <Uint8List>[];
    for (final header in extensionHeaders) {
      final typeBytes = MoQWireFormat.encodeVarint(header.type);
      headerParts.add(typeBytes);
      extensionSize += typeBytes.length;
      if (header.value != null) {
        final lenBytes = MoQWireFormat.encodeVarint(header.value!.length);
        headerParts.add(lenBytes);
        headerParts.add(header.value!);
        extensionSize += lenBytes.length + header.value!.length;
      } else {
        final lenBytes = MoQWireFormat.encodeVarint(0);
        headerParts.add(lenBytes);
        extensionSize += lenBytes.length;
      }
    }

    final data = Uint8List(
      objectIdBytes.length +
      statusBytes.length +
      numHeadersBytes.length +
      extensionSize +
      payload.length
    );

    int offset = 0;
    data.setAll(offset, objectIdBytes);
    offset += objectIdBytes.length;
    data.setAll(offset, statusBytes);
    offset += statusBytes.length;
    data.setAll(offset, numHeadersBytes);
    offset += numHeadersBytes.length;
    for (final part in headerParts) {
      data.setAll(offset, part);
      offset += part.length;
    }
    data.setAll(offset, payload);

    await _transport.streamWrite(streamId, data);
    _logger.d('Wrote object $objectId with ${extensionHeaders.length} extension headers (${payload.length} bytes) to stream $streamId');
  }

  /// Finish a data stream
  Future<void> finishDataStream(int streamId) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    await _transport.streamFinish(streamId);
    _logger.d('Finished data stream $streamId');
  }

  /// Cancel a namespace announcement
  Future<void> cancelNamespace(List<Uint8List> trackNamespace, {int statusCode = 0, String reason = ''}) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    final message = PublishNamespaceDoneMessage(
      trackNamespace: trackNamespace,
      statusCode: statusCode,
      reason: ReasonPhrase(reason),
    );

    await _transport.send(message.serialize());
    _logger.i('Cancelled namespace: ${trackNamespace.map((n) => String.fromCharCodes(n)).join("/")}');
  }

  void _handleIncomingData(Uint8List data) {
    _logger.d('_handleIncomingData: ${data.length} bytes (control stream)');
    if (data.isEmpty) return;

    // Add new data to buffer
    _controlBuffer.addAll(data);

    // Process all complete messages in buffer
    while (_controlBuffer.isNotEmpty) {
      final bufferData = Uint8List.fromList(_controlBuffer);

      try {
        // Parse as control message
        // Note: Data streams (SUBGROUP_HEADER) now come via incomingDataStreams,
        // not through the control stream, so no need to detect them here.
        final (message, bytesRead) = MoQControlMessageParser.parse(bufferData);

        if (message != null && bytesRead > 0) {
          // Remove parsed bytes from buffer
          _controlBuffer.removeRange(0, bytesRead);
          _logger.d('Parsed message: type=${message.type}, bytesRead=$bytesRead, remaining=${_controlBuffer.length}');

          _processControlMessage(message);
          _logger.d('Processed control message: ${message.type}');
        } else if (bytesRead == 0) {
          // Need more data
          _logger.d('Incomplete message, waiting for more data (buffer: ${_controlBuffer.length} bytes)');
          break;
        } else {
          // Unknown message, skip the parsed bytes
          _controlBuffer.removeRange(0, bytesRead);
          _logger.w('Skipped unknown message, bytesRead=$bytesRead');
        }
      } on FormatException catch (e) {
        // Check if it's an incomplete message error
        if (e.message.contains('Incomplete') || e.message.contains('need')) {
          _logger.d('Incomplete message: $e, waiting for more data');
          break; // Wait for more data
        }
        // Other format errors - skip a byte and try again
        _logger.e('Format error: $e, skipping byte');
        if (_controlBuffer.isNotEmpty) {
          _controlBuffer.removeAt(0);
        }
      } catch (e, stack) {
        _logger.e('Failed to process incoming data: $e');
        _logger.e('Stack: $stack');
        // Skip a byte and try again
        if (_controlBuffer.isNotEmpty) {
          _controlBuffer.removeAt(0);
        }
      }
    }
  }

  /// Handle incoming data stream chunk (SUBGROUP_HEADER + objects)
  void _handleDataStreamChunk(DataStreamChunk chunk) {
    _logger.d('Data stream chunk: streamId=${chunk.streamId}, ${chunk.data.length} bytes, complete=${chunk.isComplete}');

    var parser = _dataStreamParsers[chunk.streamId];

    if (parser == null) {
      // New stream - create parser
      parser = MoQDataStreamParser(logger: _logger);
      _dataStreamParsers[chunk.streamId] = parser;
      _logger.d('Created new parser for stream ${chunk.streamId}');
    }

    // Parse the chunk - may return header and/or objects
    final objects = parser.parseChunk(chunk.data);
    _logger.d('Parsed ${objects.length} objects from stream ${chunk.streamId}');

    // If we have a header and objects, deliver them
    if (parser.hasHeader) {
      for (final obj in objects) {
        _deliverObject(parser.header!, obj);
      }
    }

    // Clean up if stream is complete
    if (chunk.isComplete) {
      _dataStreamParsers.remove(chunk.streamId);
      _logger.d('Data stream ${chunk.streamId} complete');
    }
  }

  /// Handle incoming datagram (OBJECT_DATAGRAM message)
  void _handleDatagram(Uint8List data) {
    if (data.isEmpty) return;

    try {
      // Parse as OBJECT_DATAGRAM
      final datagram = ObjectDatagram.deserialize(data);

      _logger.d('Received datagram: trackAlias=${datagram.trackAlias}, '
          'group=${datagram.groupId}, object=${datagram.objectId}, '
          'payload=${datagram.payload?.length ?? 0} bytes');

      // Route to subscription using the same media type logic as stream objects
      _deliverDatagram(datagram);
    } catch (e, stack) {
      _logger.e('Failed to parse datagram: $e');
      _logger.d('Stack: $stack');
    }
  }

  /// Deliver a parsed datagram to the appropriate subscription
  void _deliverDatagram(ObjectDatagram datagram) {
    // First, try to determine media type from moq-mi extension headers
    MoqMiMediaType? mediaType;
    for (final extHeader in datagram.extensionHeaders) {
      if (extHeader.type == MoqMiExtensionHeaders.mediaType &&
          extHeader.value != null &&
          extHeader.value!.isNotEmpty) {
        try {
          mediaType = MoqMiMediaType.fromValue(extHeader.value![0]);
        } catch (e) {
          _logger.w('Failed to parse media type: $e');
        }
        break;
      }
    }

    // Determine if this is video or audio based on media type
    final bool isVideo = mediaType == MoqMiMediaType.videoH264Avcc;
    final bool isAudio = mediaType == MoqMiMediaType.audioOpusBitstream ||
        mediaType == MoqMiMediaType.audioAacLcMpeg4;

    // Find the subscription that matches the media type
    MoQSubscription? targetSubscription;

    if (isVideo || isAudio) {
      // Use moq-mi media type to find the correct subscription
      for (final sub in _subscriptions.values) {
        final trackNameStr = String.fromCharCodes(sub.trackName);
        if (isVideo && trackNameStr.contains('video')) {
          targetSubscription = sub;
          break;
        } else if (isAudio && trackNameStr.contains('audio')) {
          targetSubscription = sub;
          break;
        }
      }
    }

    // Fallback: if media type routing didn't work, try trackAlias
    if (targetSubscription == null) {
      final matchingByAlias = _subscriptions.values
          .where((sub) => sub.assignedTrackAlias == datagram.trackAlias)
          .toList();

      if (matchingByAlias.length == 1) {
        targetSubscription = matchingByAlias.first;
      } else if (matchingByAlias.isNotEmpty) {
        targetSubscription = matchingByAlias.first;
        _logger.d('Multiple subscriptions share trackAlias ${datagram.trackAlias}, using first');
      }
    }

    if (targetSubscription == null) {
      _logger.w('No matching subscription for datagram (trackAlias=${datagram.trackAlias}, mediaType=$mediaType)');
      return;
    }

    // Convert datagram to MoQObject and deliver
    final moqObject = MoQObject(
      trackNamespace: targetSubscription.trackNamespace,
      trackName: targetSubscription.trackName,
      groupId: datagram.groupId,
      objectId: datagram.objectId ?? Int64(0),
      publisherPriority: datagram.publisherPriority,
      forwardingPreference: ObjectForwardingPreference.datagram,
      status: datagram.status ?? ObjectStatus.normal,
      extensionHeaders: datagram.extensionHeaders,
      payload: datagram.payload,
    );
    targetSubscription._objectController.add(moqObject);
    _logger.d('Delivered ${isVideo ? "video" : isAudio ? "audio" : "unknown"} datagram ${datagram.objectId} to subscription ${targetSubscription.id}');
  }

  /// Deliver a parsed object to the appropriate subscription
  ///
  /// Uses moq-mi extension headers to determine media type (video/audio)
  /// and routes to the correct subscription. This approach is more robust
  /// than relying on server-provided trackAlias which may be incorrect.
  void _deliverObject(SubgroupHeader header, SubgroupObject obj) {
    // First, try to determine media type from moq-mi extension headers
    // This is the FB approach - use media type for routing, not trackAlias
    MoqMiMediaType? mediaType;
    for (final extHeader in obj.extensionHeaders) {
      if (extHeader.type == MoqMiExtensionHeaders.mediaType &&
          extHeader.value != null &&
          extHeader.value!.isNotEmpty) {
        try {
          mediaType = MoqMiMediaType.fromValue(extHeader.value![0]);
        } catch (e) {
          _logger.w('Failed to parse media type: $e');
        }
        break;
      }
    }

    // Determine if this is video or audio based on media type
    final bool isVideo = mediaType == MoqMiMediaType.videoH264Avcc;
    final bool isAudio = mediaType == MoqMiMediaType.audioOpusBitstream ||
        mediaType == MoqMiMediaType.audioAacLcMpeg4;

    // Find the subscription that matches the media type
    MoQSubscription? targetSubscription;

    if (isVideo || isAudio) {
      // Use moq-mi media type to find the correct subscription
      for (final sub in _subscriptions.values) {
        final trackNameStr = String.fromCharCodes(sub.trackName);
        if (isVideo && trackNameStr.contains('video')) {
          targetSubscription = sub;
          break;
        } else if (isAudio && trackNameStr.contains('audio')) {
          targetSubscription = sub;
          break;
        }
      }
    }

    // Fallback: if media type routing didn't work, try trackAlias
    if (targetSubscription == null) {
      final matchingByAlias = _subscriptions.values
          .where((sub) => sub.assignedTrackAlias == header.trackAlias)
          .toList();

      if (matchingByAlias.length == 1) {
        targetSubscription = matchingByAlias.first;
      } else if (matchingByAlias.isNotEmpty) {
        // Multiple subscriptions with same alias - use first one
        // The MoqMediaPipeline will filter by media type anyway
        targetSubscription = matchingByAlias.first;
        _logger.d('Multiple subscriptions share trackAlias ${header.trackAlias}, using first');
      }
    }

    if (targetSubscription == null) {
      _logger.w('No matching subscription for object (trackAlias=${header.trackAlias}, mediaType=$mediaType)');
      return;
    }

    // Deliver the object to the target subscription
    final moqObject = MoQObject(
      trackNamespace: targetSubscription.trackNamespace,
      trackName: targetSubscription.trackName,
      groupId: header.groupId,
      subgroupId: header.subgroupId,
      objectId: obj.objectId ?? Int64(0),
      publisherPriority: obj.publisherPriority,
      forwardingPreference: ObjectForwardingPreference.subgroup,
      status: obj.status ?? ObjectStatus.normal,
      extensionHeaders: obj.extensionHeaders,
      payload: obj.payload,
    );
    targetSubscription._objectController.add(moqObject);
    _logger.d('Delivered ${isVideo ? "video" : isAudio ? "audio" : "unknown"} object ${obj.objectId} to subscription ${targetSubscription.id}');
  }

  /// Check if subscription matches track info
  bool _tracksMatch(MoQSubscription sub, TrackInfo trackInfo) {
    // Compare namespace
    if (sub.trackNamespace.length != trackInfo.namespace.length) {
      return false;
    }
    for (int i = 0; i < sub.trackNamespace.length; i++) {
      if (!_bytesEqual(sub.trackNamespace[i], trackInfo.namespace[i])) {
        return false;
      }
    }
    // Compare track name
    return _bytesEqual(sub.trackName, trackInfo.name);
  }

  /// Compare two byte arrays for equality
  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _processControlMessage(MoQControlMessage message) {
    switch (message.type) {
      case MoQMessageType.serverSetup:
        _handleServerSetup(message as ServerSetupMessage);
        break;
      case MoQMessageType.subscribeOk:
        _handleSubscribeOk(message as SubscribeOkMessage);
        break;
      case MoQMessageType.subscribeError:
        _handleSubscribeError(message as SubscribeErrorMessage);
        break;
      case MoQMessageType.publishDone:
        _handlePublishDone(message as PublishDoneMessage);
        break;
      case MoQMessageType.goaway:
        _handleGoaway(message as GoawayMessage);
        break;
      case MoQMessageType.publishNamespaceOk:
        _handlePublishNamespaceOk(message as PublishNamespaceOkMessage);
        break;
      case MoQMessageType.publishNamespaceError:
        _handlePublishNamespaceError(message as PublishNamespaceErrorMessage);
        break;
      case MoQMessageType.subscribeNamespaceOk:
        _handleSubscribeNamespaceOk(message as SubscribeNamespaceOkMessage);
        break;
      case MoQMessageType.subscribeNamespaceError:
        _handleSubscribeNamespaceError(message as SubscribeNamespaceErrorMessage);
        break;
      case MoQMessageType.publish:
        _handlePublish(message as PublishMessage);
        break;
      case MoQMessageType.subscribe:
        _handleSubscribeRequest(message as SubscribeMessage);
        break;
      case MoQMessageType.unsubscribe:
        _handleUnsubscribeRequest(message as UnsubscribeMessage);
        break;
      case MoQMessageType.fetchOk:
        _handleFetchOk(message as FetchOkMessage);
        break;
      case MoQMessageType.fetchError:
        _handleFetchError(message as FetchErrorMessage);
        break;
      default:
        _logger.w('Unhandled message type: ${message.type}');
    }
  }

  void _handleServerSetup(ServerSetupMessage message) {
    _selectedVersion = message.selectedVersion;
    _logger.i('Server selected version: $_selectedVersion');

    // Store setup parameters
    _serverSetupParameters.clear();
    _serverSetupParameters.addAll(message.parameters);

    // Process server setup parameters
    _processServerSetupParameters(message.parameters);

    // Complete the setup future
    if (_setupCompleter != null && !_setupCompleter!.isCompleted) {
      _setupCompleter!.complete();
    }
  }

  void _processServerSetupParameters(List<KeyValuePair> parameters) {
    for (final param in parameters) {
      switch (param.type) {
        case 0x0001: // max_subscribe_id
          if (param.value != null && param.value!.isNotEmpty) {
            final (maxSubId, _) = MoQWireFormat.decodeVarint(param.value!, 0);
            _maxSubscriptionId = maxSubId;
            _logger.d('Server max_subscription_id: $maxSubId');
          }
          break;
        case 0x0002: // max_track_alias
          if (param.value != null && param.value!.isNotEmpty) {
            final (maxAlias, _) = MoQWireFormat.decodeVarint(param.value!, 0);
            _maxTrackAlias = maxAlias;
            _logger.d('Server max_track_alias: $maxAlias');
          }
          break;
        case 0x0003: // supported_versions
          if (param.value != null && param.value!.isNotEmpty) {
            final (versions, _) = MoQWireFormat.decodeTuple(param.value!, 0);
            final versionList = versions.map((v) => '0x${v.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}').join(', ');
            _logger.d('Server supported versions: [$versionList]');
          }
          break;
        default:
          _logger.d('Unknown setup parameter type: 0x${param.type.toRadixString(16)}');
      }
    }
  }

  void _handleSubscribeOk(SubscribeOkMessage message) {
    final subscription = _subscriptions[message.requestId];
    if (subscription != null) {
      subscription.complete(
        trackAlias: message.trackAlias,
        expires: message.expires,
        groupOrder: message.groupOrder,
        contentExists: message.contentExists == 1,
        largestLocation: message.largestLocation,
      );

      // Store track alias in the subscription for direct lookup
      subscription.assignedTrackAlias = message.trackAlias;

      // Also register in track aliases map (may have collisions if server reuses aliases)
      final trackNameStr = String.fromCharCodes(subscription.trackName);
      _logger.i('SUBSCRIBE_OK: requestId=${message.requestId}, trackAlias=${message.trackAlias}, trackName=$trackNameStr');

      _trackAliases[message.trackAlias] = TrackInfo(
        namespace: subscription.trackNamespace,
        name: subscription.trackName,
      );

      _logger.i('Subscription successful for $trackNameStr: trackAlias=${message.trackAlias}');
    }
  }

  void _handleSubscribeError(SubscribeErrorMessage message) {
    final subscription = _subscriptions[message.requestId];
    if (subscription != null) {
      subscription.fail(
        errorCode: message.errorCode,
        reason: message.errorReason.reason,
      );
      _subscriptions.remove(message.requestId);
      _logger.e('Subscription failed: ${message.errorCode} - ${message.errorReason.reason}');
    }
  }

  void _handlePublishDone(PublishDoneMessage message) {
    final subscription = _subscriptions[message.requestId];
    if (subscription != null) {
      subscription.closeWithStatus(
        statusCode: message.statusCode,
        streamCount: message.streamCount,
      );
      _subscriptions.remove(message.requestId);
      _logger.i('Publish done: ${message.requestId}');
    }
  }

  void _handleGoaway(GoawayMessage message) {
    _logger.w('Received GOAWAY from server');
    if (message.newUri != null) {
      _logger.i('Server provided new URI: ${message.newUri}');
    }

    // Create and emit GOAWAY event
    final event = GoawayEvent(
      newUri: message.newUri,
    );
    _goawayController.add(event);

    // Mark as disconnecting - the application should handle reconnection
    _isConnected = false;
    _connectionStateController.add(false);
  }

  void _handlePublishNamespaceOk(PublishNamespaceOkMessage message) {
    final announcement = _namespaceAnnouncements[message.requestId];
    if (announcement != null) {
      // Per draft-14, PUBLISH_NAMESPACE_OK has no parameters
      announcement.complete();
      _logger.i('Namespace announcement successful: ${announcement.namespacePath}');
    } else {
      _logger.w('Received PUBLISH_NAMESPACE_OK for unknown request: ${message.requestId}');
    }
  }

  void _handlePublishNamespaceError(PublishNamespaceErrorMessage message) {
    final announcement = _namespaceAnnouncements[message.requestId];
    if (announcement != null) {
      announcement.fail(
        errorCode: message.errorCode,
        reason: message.errorReason.reason,
      );
      _namespaceAnnouncements.remove(message.requestId);
      _logger.e('Namespace announcement failed: ${message.errorCode} - ${message.errorReason.reason}');
    }
  }

  void _handleSubscribeNamespaceOk(SubscribeNamespaceOkMessage message) {
    final subscription = _namespaceSubscriptions[message.requestId];
    if (subscription != null) {
      subscription.complete();
      _logger.i('Namespace subscription successful: ${subscription.namespacePrefixPath}');
    } else {
      _logger.w('Received SUBSCRIBE_NAMESPACE_OK for unknown request: ${message.requestId}');
    }
  }

  void _handleFetchOk(FetchOkMessage message) {
    final fetch = _activeFetches[message.requestId];
    if (fetch != null) {
      fetch.complete(
        groupOrder: message.groupOrder,
        endOfTrack: message.isEndOfTrack,
        endLocation: message.endLocation,
        parameters: message.parameters,
      );
      _logger.i('Fetch successful: ${message.requestId}');
    } else {
      _logger.w('Received FETCH_OK for unknown request: ${message.requestId}');
    }
  }

  void _handleFetchError(FetchErrorMessage message) {
    final fetch = _activeFetches[message.requestId];
    if (fetch != null) {
      fetch.fail(
        errorCode: message.errorCode,
        reason: message.errorReason.reason,
      );
      _activeFetches.remove(message.requestId);
      _logger.e('Fetch failed: ${message.errorCode} - ${message.errorReason.reason}');
    } else {
      _logger.w('Received FETCH_ERROR for unknown request: ${message.requestId}');
    }
  }

  void _handleSubscribeNamespaceError(SubscribeNamespaceErrorMessage message) {
    final subscription = _namespaceSubscriptions[message.requestId];
    if (subscription != null) {
      subscription.fail(
        errorCode: message.errorCode,
        reason: message.errorReason.reason,
      );
      _namespaceSubscriptions.remove(message.requestId);
      _logger.e('Namespace subscription failed: ${message.errorCode} - ${message.errorReason.reason}');
    }
  }

  void _handlePublish(PublishMessage message) {
    _logger.i('Received PUBLISH request: ${message.namespacePath}/${message.trackNameString}');

    final request = MoQPublishRequest(
      client: this,
      requestId: message.requestId,
      trackNamespace: message.trackNamespace,
      trackName: message.trackName,
      trackAlias: message.trackAlias,
      groupOrder: message.groupOrder,
      contentExists: message.contentExists,
      largestLocation: message.largestLocation,
      forward: message.forward,
      parameters: message.parameters,
    );

    _pendingPublishRequests[message.requestId] = request;
    _incomingPublishController.add(request);
  }

  /// Accept a PUBLISH request (server mode)
  ///
  /// Sends PUBLISH_OK to the publisher to accept the subscription.
  Future<void> acceptPublish(
    Int64 requestId, {
    required int forward,
    required int subscriberPriority,
    required GroupOrder groupOrder,
    required FilterType filterType,
    Location? startLocation,
    Int64? endGroup,
    List<KeyValuePair>? parameters,
  }) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    final request = _pendingPublishRequests.remove(requestId);
    if (request == null) {
      _logger.w('No pending PUBLISH request for ID: $requestId');
      return;
    }

    final publishOk = PublishOkMessage(
      requestId: requestId,
      forward: forward,
      subscriberPriority: subscriberPriority,
      groupOrder: groupOrder,
      filterType: filterType,
      startLocation: startLocation,
      endGroup: endGroup,
      parameters: parameters ?? [],
    );

    await _transport.send(publishOk.serialize());

    // Register track alias for incoming data
    _trackAliases[request.trackAlias] = TrackInfo(
      namespace: request.trackNamespace,
      name: request.trackName,
    );

    _logger.i('Accepted PUBLISH request: $requestId');
  }

  /// Reject a PUBLISH request (server mode)
  ///
  /// Sends PUBLISH_ERROR to the publisher to reject the subscription.
  Future<void> rejectPublish(
    Int64 requestId, {
    required int errorCode,
    required String reason,
  }) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    _pendingPublishRequests.remove(requestId);

    final publishError = PublishErrorMessage(
      requestId: requestId,
      errorCode: errorCode,
      errorReason: ReasonPhrase(reason),
    );

    await _transport.send(publishError.serialize());
    _logger.i('Rejected PUBLISH request: $requestId - $reason');
  }

  void _handleSubscribeRequest(SubscribeMessage message) {
    final namespacePath = message.trackNamespace
        .map((e) => String.fromCharCodes(e))
        .join('/');
    final trackName = String.fromCharCodes(message.trackName);
    _logger.i('Received SUBSCRIBE request: $namespacePath/$trackName');

    final request = MoQSubscribeRequest(
      client: this,
      requestId: message.requestId,
      trackNamespace: message.trackNamespace,
      trackName: message.trackName,
      subscriberPriority: message.subscriberPriority,
      groupOrder: message.groupOrder,
      forward: message.forward,
      filterType: message.filterType,
      startLocation: message.startLocation,
      endGroup: message.endGroup,
      parameters: message.parameters,
    );

    _pendingSubscribeRequests[message.requestId] = request;
    _incomingSubscribeController.add(request);
  }

  void _handleUnsubscribeRequest(UnsubscribeMessage message) {
    _logger.i('Received UNSUBSCRIBE for request: ${message.requestId}');

    // Remove from active subscriptions
    final subscription = _activePublisherSubscriptions.remove(message.requestId);
    if (subscription != null) {
      _logger.i('Removed active subscription: ${message.requestId}');
    }
  }

  /// Accept a SUBSCRIBE request (publisher mode)
  ///
  /// Sends SUBSCRIBE_OK to the subscriber to confirm the subscription.
  Future<void> acceptSubscribe(
    Int64 requestId, {
    required Int64 trackAlias,
    required Int64 expires,
    required GroupOrder groupOrder,
    required bool contentExists,
    Location? largestLocation,
    List<KeyValuePair>? parameters,
  }) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    final request = _pendingSubscribeRequests.remove(requestId);
    if (request == null) {
      _logger.w('No pending SUBSCRIBE request for ID: $requestId');
      return;
    }

    final subscribeOk = SubscribeOkMessage(
      requestId: requestId,
      trackAlias: trackAlias,
      expires: expires,
      groupOrder: groupOrder,
      contentExists: contentExists ? 1 : 0,
      largestLocation: largestLocation,
      parameters: parameters ?? [],
    );

    await _transport.send(subscribeOk.serialize());

    // Track active subscription
    _activePublisherSubscriptions[requestId] = request;

    // Register track alias
    _trackAliases[trackAlias] = TrackInfo(
      namespace: request.trackNamespace,
      name: request.trackName,
    );

    _logger.i('Accepted SUBSCRIBE request: $requestId with alias $trackAlias');
  }

  /// Reject a SUBSCRIBE request (publisher mode)
  ///
  /// Sends SUBSCRIBE_ERROR to the subscriber to reject the subscription.
  Future<void> rejectSubscribe(
    Int64 requestId, {
    required int errorCode,
    required String reason,
  }) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    _pendingSubscribeRequests.remove(requestId);

    final subscribeError = SubscribeErrorMessage(
      requestId: requestId,
      errorCode: errorCode,
      errorReason: ReasonPhrase(reason),
    );

    await _transport.send(subscribeError.serialize());
    _logger.i('Rejected SUBSCRIBE request: $requestId - $reason');
  }

  /// Send PUBLISH_DONE to indicate publishing has completed for a subscription
  ///
  /// This notifies subscribers that no more objects will be published.
  Future<void> sendPublishDone(
    Int64 requestId, {
    required int statusCode,
    Int64? streamCount,
    String? reason,
  }) async {
    if (!_isConnected) {
      throw StateError('Not connected');
    }

    final publishDone = PublishDoneMessage(
      requestId: requestId,
      statusCode: statusCode,
      streamCount: streamCount ?? Int64(0),
      errorReason: reason != null ? ReasonPhrase(reason) : null,
    );

    await _transport.send(publishDone.serialize());
    _activePublisherSubscriptions.remove(requestId);
    _logger.i('Sent PUBLISH_DONE for subscription: $requestId');
  }

  void dispose() {
    disconnect();
    _messageController.close();
    _connectionStateController.close();
    _incomingPublishController.close();
    _incomingSubscribeController.close();
    _goawayController.close();
    _transport.dispose();
  }
}

/// Subscription result
class SubscribeResult {
  final Int64 trackAlias;
  final Int64 expires;
  final GroupOrder groupOrder;
  final bool contentExists;
  final Location? largestLocation;

  const SubscribeResult({
    required this.trackAlias,
    required this.expires,
    required this.groupOrder,
    required this.contentExists,
    this.largestLocation,
  });
}

/// Active subscription
class MoQSubscription {
  final MoQClient client;
  final Int64 id;
  final List<Uint8List> trackNamespace;
  final Uint8List trackName;

  /// Track alias assigned by server in SUBSCRIBE_OK
  Int64? assignedTrackAlias;

  final Completer<SubscribeResult> _responseCompleter =
      Completer<SubscribeResult>();

  // Current subscription state
  Location currentStart = Location.zero();
  Int64 currentEndGroup = Int64(0);
  int priority = 128;
  bool forward = true;

  final _objectController = StreamController<MoQObject>.broadcast();
  bool _isClosed = false;

  MoQSubscription({
    required this.client,
    required this.id,
    required this.trackNamespace,
    required this.trackName,
  });

  /// Wait for SUBSCRIBE_OK response
  Future<SubscribeResult> waitForResponse() => _responseCompleter.future;

  /// Complete the subscription with successful response
  void complete({
    required Int64 trackAlias,
    required Int64 expires,
    required GroupOrder groupOrder,
    required bool contentExists,
    Location? largestLocation,
  }) {
    if (_responseCompleter.isCompleted) return;

    _responseCompleter.complete(SubscribeResult(
      trackAlias: trackAlias,
      expires: expires,
      groupOrder: groupOrder,
      contentExists: contentExists,
      largestLocation: largestLocation,
    ));
  }

  /// Fail the subscription
  void fail({required int errorCode, required String reason}) {
    if (_responseCompleter.isCompleted) return;

    _responseCompleter.completeError(
      MoQException(errorCode: errorCode, reason: reason),
    );
  }

  /// Close subscription with status
  void closeWithStatus({required int statusCode, required Int64 streamCount}) {
    _isClosed = true;
    // TODO: Notify about completion status
    close();
  }

  /// Stream of objects for this subscription
  Stream<MoQObject> get objectStream => _objectController.stream;

  /// Check if subscription is active
  bool get isActive => !_isClosed;

  /// Close the subscription
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    await _objectController.close();
  }

  void dispose() {
    close();
  }
}

/// Track info for alias mapping
class TrackInfo {
  final List<Uint8List> namespace;
  final Uint8List name;

  TrackInfo({
    required this.namespace,
    required this.name,
  });
}

/// MoQ exception
class MoQException implements Exception {
  final int errorCode;
  final String reason;

  MoQException({
    required this.errorCode,
    required this.reason,
  });

  @override
  String toString() => 'MoQException(code: $errorCode, reason: $reason)';
}

/// Base message class for UI layer
abstract class MoQMessage {
  MoQMessageType get type;
}

/// Namespace announcement for publishing
class MoQNamespaceAnnouncement {
  final MoQClient client;
  final Int64 requestId;
  final List<Uint8List> trackNamespace;

  final Completer<void> _responseCompleter = Completer<void>();

  MoQNamespaceAnnouncement({
    required this.client,
    required this.requestId,
    required this.trackNamespace,
  });

  /// Get namespace as a string path
  String get namespacePath {
    return trackNamespace
        .map((e) => String.fromCharCodes(e))
        .join('/');
  }

  /// Wait for PUBLISH_NAMESPACE_OK response
  Future<void> waitForResponse() => _responseCompleter.future;

  /// Complete the announcement with successful response
  /// Per draft-14 section 9.24, PUBLISH_NAMESPACE_OK has no parameters
  void complete() {
    if (_responseCompleter.isCompleted) return;
    _responseCompleter.complete();
  }

  /// Fail the announcement
  void fail({required int errorCode, required String reason}) {
    if (_responseCompleter.isCompleted) return;
    _responseCompleter.completeError(
      MoQException(errorCode: errorCode, reason: reason),
    );
  }
}

/// Namespace subscription for discovery
class MoQNamespaceSubscription {
  final MoQClient client;
  final Int64 requestId;
  final List<Uint8List> trackNamespacePrefix;

  final Completer<void> _responseCompleter = Completer<void>();

  MoQNamespaceSubscription({
    required this.client,
    required this.requestId,
    required this.trackNamespacePrefix,
  });

  /// Get namespace prefix as a string path
  String get namespacePrefixPath {
    return trackNamespacePrefix
        .map((e) => String.fromCharCodes(e))
        .join('/');
  }

  /// Wait for SUBSCRIBE_NAMESPACE_OK response
  Future<void> waitForResponse() => _responseCompleter.future;

  /// Complete the subscription with successful response
  void complete() {
    if (_responseCompleter.isCompleted) return;
    _responseCompleter.complete();
  }

  /// Fail the subscription
  void fail({required int errorCode, required String reason}) {
    if (_responseCompleter.isCompleted) return;
    _responseCompleter.completeError(
      MoQException(errorCode: errorCode, reason: reason),
    );
  }

  /// Unsubscribe from this namespace
  Future<void> unsubscribe() async {
    await client.unsubscribeNamespace(trackNamespacePrefix);
  }
}

/// Incoming PUBLISH request (server mode)
///
/// Represents a PUBLISH request from a publisher that wants to send data.
/// Use [accept] or [reject] to respond to the request.
class MoQPublishRequest {
  final MoQClient client;
  final Int64 requestId;
  final List<Uint8List> trackNamespace;
  final Uint8List trackName;
  final Int64 trackAlias;
  final GroupOrder groupOrder;
  final bool contentExists;
  final Location? largestLocation;
  final int forward;
  final List<KeyValuePair> parameters;

  MoQPublishRequest({
    required this.client,
    required this.requestId,
    required this.trackNamespace,
    required this.trackName,
    required this.trackAlias,
    required this.groupOrder,
    required this.contentExists,
    this.largestLocation,
    required this.forward,
    this.parameters = const [],
  });

  /// Get namespace as a string path
  String get namespacePath {
    return trackNamespace
        .map((e) => String.fromCharCodes(e))
        .join('/');
  }

  /// Get track name as a string
  String get trackNameString => String.fromCharCodes(trackName);

  /// Accept this PUBLISH request
  ///
  /// Sends PUBLISH_OK to the publisher.
  Future<void> accept({
    int forward = 1,
    int subscriberPriority = 128,
    GroupOrder? groupOrder,
    FilterType filterType = FilterType.largestObject,
    Location? startLocation,
    Int64? endGroup,
    List<KeyValuePair>? parameters,
  }) async {
    await client.acceptPublish(
      requestId,
      forward: forward,
      subscriberPriority: subscriberPriority,
      groupOrder: groupOrder ?? this.groupOrder,
      filterType: filterType,
      startLocation: startLocation,
      endGroup: endGroup,
      parameters: parameters,
    );
  }

  /// Reject this PUBLISH request
  ///
  /// Sends PUBLISH_ERROR to the publisher.
  Future<void> reject({
    int errorCode = 0,
    String reason = 'Rejected',
  }) async {
    await client.rejectPublish(
      requestId,
      errorCode: errorCode,
      reason: reason,
    );
  }
}

/// Incoming SUBSCRIBE request (publisher mode)
///
/// Represents a SUBSCRIBE request from a subscriber/relay that wants to receive data.
/// Use [accept] or [reject] to respond to the request.
class MoQSubscribeRequest {
  final MoQClient client;
  final Int64 requestId;
  final List<Uint8List> trackNamespace;
  final Uint8List trackName;
  final int subscriberPriority;
  final GroupOrder groupOrder;
  final int forward;
  final FilterType filterType;
  final Location? startLocation;
  final Int64? endGroup;
  final List<KeyValuePair> parameters;

  // Track alias assigned when accepted
  Int64? _assignedTrackAlias;

  MoQSubscribeRequest({
    required this.client,
    required this.requestId,
    required this.trackNamespace,
    required this.trackName,
    required this.subscriberPriority,
    required this.groupOrder,
    required this.forward,
    required this.filterType,
    this.startLocation,
    this.endGroup,
    this.parameters = const [],
  });

  /// Get assigned track alias (after acceptance)
  Int64? get trackAlias => _assignedTrackAlias;

  /// Get namespace as a string path
  String get namespacePath {
    return trackNamespace
        .map((e) => String.fromCharCodes(e))
        .join('/');
  }

  /// Get track name as a string
  String get trackNameString => String.fromCharCodes(trackName);

  /// Accept this SUBSCRIBE request
  ///
  /// Sends SUBSCRIBE_OK to the subscriber.
  Future<void> accept({
    required Int64 trackAlias,
    Int64? expires,
    GroupOrder? groupOrder,
    bool contentExists = false,
    Location? largestLocation,
    List<KeyValuePair>? parameters,
  }) async {
    _assignedTrackAlias = trackAlias;
    await client.acceptSubscribe(
      requestId,
      trackAlias: trackAlias,
      expires: expires ?? Int64(0),
      groupOrder: groupOrder ?? this.groupOrder,
      contentExists: contentExists,
      largestLocation: largestLocation,
      parameters: parameters,
    );
  }

  /// Reject this SUBSCRIBE request
  ///
  /// Sends SUBSCRIBE_ERROR to the subscriber.
  Future<void> reject({
    int errorCode = 0,
    String reason = 'Rejected',
  }) async {
    await client.rejectSubscribe(
      requestId,
      errorCode: errorCode,
      reason: reason,
    );
  }
}

/// GOAWAY event from server
///
/// Indicates the server is closing the connection and optionally
/// provides a new URI to reconnect to.
class GoawayEvent {
  /// New URI to reconnect to (if provided by server)
  final String? newUri;

  GoawayEvent({this.newUri});

  /// Whether a new URI was provided for migration
  bool get hasMigrationUri => newUri != null && newUri!.isNotEmpty;
}

/// Subgroup header message for data streams
///
/// Per draft-ietf-moq-transport-14, each subgroup stream starts with:
/// SUBGROUP_HEADER (0x10) {
///   Track Alias (i),
///   Group ID (i),
///   Subgroup ID (i),
///   Publisher Priority (8),
///   [Number of Extension Headers (i),
///   Extension Headers (..) ...,]
/// }
class SubgroupHeaderMessage {
  final Int64 trackAlias;
  final Int64 groupId;
  final Int64 subgroupId;
  final int publisherPriority;
  final List<KeyValuePair> extensionHeaders;

  SubgroupHeaderMessage({
    required this.trackAlias,
    required this.groupId,
    required this.subgroupId,
    required this.publisherPriority,
    this.extensionHeaders = const [],
  });

  Uint8List serialize() {
    final trackAliasBytes = MoQWireFormat.encodeVarint64(trackAlias);
    final groupIdBytes = MoQWireFormat.encodeVarint64(groupId);
    final subgroupIdBytes = MoQWireFormat.encodeVarint64(subgroupId);

    // Calculate extension headers size
    final numHeadersBytes = MoQWireFormat.encodeVarint(extensionHeaders.length);
    int extensionSize = numHeadersBytes.length;
    final headerParts = <Uint8List>[];
    for (final header in extensionHeaders) {
      final typeBytes = MoQWireFormat.encodeVarint(header.type);
      headerParts.add(typeBytes);
      extensionSize += typeBytes.length;
      if (header.value != null) {
        final lenBytes = MoQWireFormat.encodeVarint(header.value!.length);
        headerParts.add(lenBytes);
        headerParts.add(header.value!);
        extensionSize += lenBytes.length + header.value!.length;
      } else {
        final lenBytes = MoQWireFormat.encodeVarint(0);
        headerParts.add(lenBytes);
        extensionSize += lenBytes.length;
      }
    }

    // Stream type (0x10) + track alias + group id + subgroup id + priority (1 byte) + extension headers
    final streamType = MoQWireFormat.encodeVarint(0x10);
    final buffer = Uint8List(
      streamType.length +
      trackAliasBytes.length +
      groupIdBytes.length +
      subgroupIdBytes.length +
      1 +
      extensionSize
    );

    int offset = 0;
    buffer.setAll(offset, streamType);
    offset += streamType.length;
    buffer.setAll(offset, trackAliasBytes);
    offset += trackAliasBytes.length;
    buffer.setAll(offset, groupIdBytes);
    offset += groupIdBytes.length;
    buffer.setAll(offset, subgroupIdBytes);
    offset += subgroupIdBytes.length;
    buffer[offset] = publisherPriority & 0xFF;
    offset += 1;

    // Write extension headers
    buffer.setAll(offset, numHeadersBytes);
    offset += numHeadersBytes.length;
    for (final part in headerParts) {
      buffer.setAll(offset, part);
      offset += part.length;
    }

    return buffer;
  }
}

/// Result of a successful fetch
class FetchResult {
  final GroupOrder groupOrder;
  final bool endOfTrack;
  final Location endLocation;
  final List<KeyValuePair> parameters;

  const FetchResult({
    required this.groupOrder,
    required this.endOfTrack,
    required this.endLocation,
    this.parameters = const [],
  });
}

/// Active fetch request
///
/// Tracks a FETCH request and provides a stream of objects.
class MoQFetch {
  final MoQClient client;
  final Int64 requestId;
  final FetchType fetchType;

  // Standalone fetch fields
  final List<Uint8List>? trackNamespace;
  final Uint8List? trackName;
  final Location? startLocation;
  final Location? requestedEndLocation;

  // Joining fetch fields
  final Int64? joiningRequestId;
  final Int64? joiningStart;

  // Response data
  GroupOrder? _groupOrder;
  bool? _endOfTrack;
  Location? _endLocation;
  List<KeyValuePair>? _parameters;

  final Completer<FetchResult> _responseCompleter = Completer<FetchResult>();
  final _objectController = StreamController<MoQObject>.broadcast();
  bool _isCanceled = false;
  bool _isComplete = false;

  MoQFetch({
    required this.client,
    required this.requestId,
    required this.fetchType,
    this.trackNamespace,
    this.trackName,
    this.startLocation,
    this.requestedEndLocation,
    this.joiningRequestId,
    this.joiningStart,
  });

  /// Get track namespace as path string (for standalone fetch)
  String get namespacePath {
    if (trackNamespace == null) return '';
    return trackNamespace!.map((e) => String.fromCharCodes(e)).join('/');
  }

  /// Get track name as string (for standalone fetch)
  String get trackNameString {
    if (trackName == null) return '';
    return String.fromCharCodes(trackName!);
  }

  /// Wait for FETCH_OK response
  Future<FetchResult> waitForResponse() => _responseCompleter.future;

  /// Stream of objects for this fetch
  Stream<MoQObject> get objectStream => _objectController.stream;

  /// Actual end location from FETCH_OK
  Location? get endLocation => _endLocation;

  /// Actual group order from FETCH_OK
  GroupOrder? get groupOrder => _groupOrder;

  /// Whether this fetch covers the end of the track
  bool get isEndOfTrack => _endOfTrack ?? false;

  /// Whether fetch is active
  bool get isActive => !_isCanceled && !_isComplete;

  /// Complete the fetch with successful response
  void complete({
    required GroupOrder groupOrder,
    required bool endOfTrack,
    required Location endLocation,
    List<KeyValuePair>? parameters,
  }) {
    if (_responseCompleter.isCompleted) return;

    _groupOrder = groupOrder;
    _endOfTrack = endOfTrack;
    _endLocation = endLocation;
    _parameters = parameters;

    _responseCompleter.complete(FetchResult(
      groupOrder: groupOrder,
      endOfTrack: endOfTrack,
      endLocation: endLocation,
      parameters: parameters ?? [],
    ));
  }

  /// Fail the fetch
  void fail({required int errorCode, required String reason}) {
    if (_responseCompleter.isCompleted) return;

    _responseCompleter.completeError(
      MoQException(errorCode: errorCode, reason: reason),
    );
  }

  /// Cancel the fetch
  void cancel() {
    _isCanceled = true;
    if (!_responseCompleter.isCompleted) {
      _responseCompleter.completeError(
        MoQException(errorCode: -1, reason: 'Fetch cancelled'),
      );
    }
    _objectController.close();
  }

  /// Mark fetch as complete (all objects received)
  void markComplete() {
    _isComplete = true;
    _objectController.close();
  }

  void dispose() {
    _objectController.close();
  }
}
