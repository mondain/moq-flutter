import 'dart:async';
import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:logger/logger.dart';
import '../protocol/moq_messages.dart';
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

  // Track aliases mapping
  final _trackAliases = <Int64, TrackInfo>{};

  // Message controllers
  final _messageController = StreamController<MoQMessage>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();

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

    // Listen for incoming data first
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
        _connectionStateController.add(false);
        if (!_setupCompleter!.isCompleted) {
          _setupCompleter!.completeError(
            MoQException(errorCode: -1, reason: 'Transport closed'),
          );
        }
      },
    );

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
    // Draft versions use format 0xff00000X where X is draft number
    // Draft-14 = 0xff00000e, Draft-15 = 0xff00000f
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
    _logger.w('Received GOAWAY');
    if (message.newUri != null) {
      _logger.i('New URI: ${message.newUri}');
      // TODO: Implement migration
    }
    // TODO: Close and migrate connection
  }

  void dispose() {
    disconnect();
    _messageController.close();
    _connectionStateController.close();
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
