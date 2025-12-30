import 'dart:async';
import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:logger/logger.dart';
import '../protocol/moq_messages.dart';
import '../protocol/moq_data_parser.dart';
import '../transport/moq_transport.dart';

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
          if (!_setupCompleter!.isCompleted) {
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
          if (!_setupCompleter!.isCompleted) {
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
    final setupMessage = ClientSetupMessage(
      supportedVersions: versions,
      // TODO: Add setup parameters
    );

    await _transport.send(setupMessage.serialize());
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

    for (final sub in _subscriptions.values) {
      await sub.close();
    }
    _subscriptions.clear();
    _trackAliases.clear();

    _connectionStateController.add(false);
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
    try {
      final (message, bytesRead) = MoQControlMessageParser.parse(data);

      if (message != null) {
        _processControlMessage(message);
      }
    } catch (e) {
      _logger.e('Failed to process incoming data: $e');
    }
  }

  /// Handle incoming data stream chunk (SUBGROUP_HEADER + objects)
  void _handleDataStreamChunk(DataStreamChunk chunk) {
    var parser = _dataStreamParsers[chunk.streamId];

    if (parser == null) {
      // New stream - create parser
      parser = MoQDataStreamParser(logger: _logger);
      _dataStreamParsers[chunk.streamId] = parser;
    }

    // Parse the chunk - may return header and/or objects
    final objects = parser.parseChunk(chunk.data);

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

  /// Deliver a parsed object to the appropriate subscription
  void _deliverObject(SubgroupHeader header, SubgroupObject obj) {
    // Find track info by alias
    final trackInfo = _trackAliases[header.trackAlias];
    if (trackInfo == null) {
      _logger.w('Received object for unknown track alias: ${header.trackAlias}');
      return;
    }

    // Find matching subscription
    for (final sub in _subscriptions.values) {
      if (_tracksMatch(sub, trackInfo)) {
        final moqObject = MoQObject(
          trackNamespace: trackInfo.namespace,
          trackName: trackInfo.name,
          groupId: header.groupId,
          subgroupId: header.subgroupId,
          objectId: obj.objectId ?? Int64(0),
          publisherPriority: obj.publisherPriority,
          forwardingPreference: ObjectForwardingPreference.subgroup,
          status: obj.status ?? ObjectStatus.normal,
          extensionHeaders: obj.extensionHeaders,
          payload: obj.payload,
        );
        sub._objectController.add(moqObject);
        _logger.d('Delivered object ${obj.objectId} to subscription ${sub.id}');
        return;
      }
    }

    _logger.w('No subscription found for track alias: ${header.trackAlias}');
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
      case MoQMessageType.publish:
        _handlePublish(message as PublishMessage);
        break;
      case MoQMessageType.subscribe:
        _handleSubscribeRequest(message as SubscribeMessage);
        break;
      case MoQMessageType.unsubscribe:
        _handleUnsubscribeRequest(message as UnsubscribeMessage);
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

      // Register track alias
      _trackAliases[message.trackAlias] = TrackInfo(
        namespace: subscription.trackNamespace,
        name: subscription.trackName,
      );

      _logger.i('Subscription successful: ${message.trackAlias}');
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
      announcement.complete(parameters: message.parameters);
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

  // Parameters returned by server
  List<KeyValuePair>? serverParameters;

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
  void complete({List<KeyValuePair>? parameters}) {
    if (_responseCompleter.isCompleted) return;
    serverParameters = parameters;
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
/// }
class SubgroupHeaderMessage {
  final Int64 trackAlias;
  final Int64 groupId;
  final Int64 subgroupId;
  final int publisherPriority;

  SubgroupHeaderMessage({
    required this.trackAlias,
    required this.groupId,
    required this.subgroupId,
    required this.publisherPriority,
  });

  Uint8List serialize() {
    final trackAliasBytes = MoQWireFormat.encodeVarint64(trackAlias);
    final groupIdBytes = MoQWireFormat.encodeVarint64(groupId);
    final subgroupIdBytes = MoQWireFormat.encodeVarint64(subgroupId);

    // Stream type (0x10) + track alias + group id + subgroup id + priority (1 byte)
    final streamType = MoQWireFormat.encodeVarint(0x10);
    final buffer = Uint8List(
      streamType.length +
      trackAliasBytes.length +
      groupIdBytes.length +
      subgroupIdBytes.length +
      1
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

    return buffer;
  }
}
