import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';

/// A stream controller that replays buffered events to new listeners.
///
/// This solves the race condition where events arrive before listeners
/// are attached to broadcast streams. When a new listener subscribes,
/// it receives all buffered events before receiving live events.
///
/// Useful for live streaming scenarios where the first keyframe must
/// not be missed even if the player initializes slightly late.
class ReplayStreamController<T> {
  final int _bufferSize;
  final Queue<T> _buffer = Queue<T>();
  final StreamController<T> _controller;
  final List<_ReplaySubscription<T>> _subscriptions = [];
  bool _isClosed = false;

  /// Create a replay stream controller.
  ///
  /// [bufferSize] controls how many events to keep in the replay buffer.
  /// For video streams, this should be large enough to capture at least
  /// one GOP (group of pictures) worth of data.
  ReplayStreamController({int bufferSize = 60})
      : _bufferSize = bufferSize,
        _controller = StreamController<T>.broadcast(sync: true);

  /// Add an event to the stream.
  ///
  /// The event is buffered for replay and also delivered to all
  /// current listeners immediately.
  void add(T event) {
    if (_isClosed) return;

    // Add to replay buffer
    _buffer.addLast(event);
    while (_buffer.length > _bufferSize) {
      _buffer.removeFirst();
    }

    // Deliver to current listeners
    _controller.add(event);
  }

  /// Get a stream that replays buffered events before live events.
  ///
  /// Each call creates a new subscription that first receives all
  /// buffered events, then switches to live events.
  Stream<T> get stream {
    return _ReplayStream<T>(this);
  }

  /// Get the number of buffered events
  int get bufferedCount => _buffer.length;

  /// Get the current buffer contents (for debugging)
  List<T> get bufferedEvents => _buffer.toList();

  /// Close the controller and release resources.
  Future<void> close() async {
    _isClosed = true;
    _buffer.clear();
    for (final sub in _subscriptions) {
      sub._cancel();
    }
    _subscriptions.clear();
    await _controller.close();
  }

  /// Check if the controller is closed
  bool get isClosed => _isClosed;

  void _addSubscription(_ReplaySubscription<T> sub) {
    _subscriptions.add(sub);
  }

  void _removeSubscription(_ReplaySubscription<T> sub) {
    _subscriptions.remove(sub);
  }
}

/// Internal stream implementation that handles replay logic
class _ReplayStream<T> extends Stream<T> {
  final ReplayStreamController<T> _parent;

  _ReplayStream(this._parent);

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final subscription = _ReplaySubscription<T>(
      _parent,
      onData,
      onError,
      onDone,
      cancelOnError ?? false,
    );
    _parent._addSubscription(subscription);
    subscription._start();
    return subscription;
  }
}

/// Internal subscription that handles replay and live events
class _ReplaySubscription<T> implements StreamSubscription<T> {
  final ReplayStreamController<T> _parent;
  void Function(T event)? _onData;
  Function? _onError;
  void Function()? _onDone;
  final bool _cancelOnError;

  StreamSubscription<T>? _liveSubscription;
  bool _isPaused = false;
  bool _isCanceled = false;
  final List<T> _pauseBuffer = [];

  _ReplaySubscription(
    this._parent,
    this._onData,
    this._onError,
    this._onDone,
    this._cancelOnError,
  );

  void _start() {
    if (_isCanceled) return;

    // First, replay all buffered events
    final buffered = _parent._buffer.toList();
    if (buffered.isNotEmpty) {
      debugPrint('ReplayStream: Replaying ${buffered.length} buffered events to new listener');
    }
    for (final event in buffered) {
      if (_isCanceled) return;
      if (_isPaused) {
        _pauseBuffer.add(event);
      } else {
        _onData?.call(event);
      }
    }
    if (buffered.isNotEmpty) {
      debugPrint('ReplayStream: Finished replaying ${buffered.length} events, switching to live');
    }

    // Then subscribe to live events
    _liveSubscription = _parent._controller.stream.listen(
      (event) {
        if (_isPaused) {
          _pauseBuffer.add(event);
        } else {
          _onData?.call(event);
        }
      },
      onError: (error, stackTrace) {
        _onError?.call(error, stackTrace);
      },
      onDone: () {
        _onDone?.call();
      },
      cancelOnError: _cancelOnError,
    );
  }

  void _cancel() {
    _isCanceled = true;
    _liveSubscription?.cancel();
    _liveSubscription = null;
    _pauseBuffer.clear();
  }

  @override
  Future<void> cancel() async {
    _parent._removeSubscription(this);
    _cancel();
  }

  @override
  void onData(void Function(T data)? handleData) {
    _onData = handleData;
  }

  @override
  void onError(Function? handleError) {
    _onError = handleError;
  }

  @override
  void onDone(void Function()? handleDone) {
    _onDone = handleDone;
  }

  @override
  void pause([Future<void>? resumeSignal]) {
    _isPaused = true;
    _liveSubscription?.pause(resumeSignal);
    resumeSignal?.then((_) => resume());
  }

  @override
  void resume() {
    if (!_isPaused) return;
    _isPaused = false;

    // Deliver paused events
    final events = List<T>.from(_pauseBuffer);
    _pauseBuffer.clear();
    for (final event in events) {
      if (_isCanceled || _isPaused) break;
      _onData?.call(event);
    }

    _liveSubscription?.resume();
  }

  @override
  bool get isPaused => _isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) {
    final completer = Completer<E>();
    onDone(() {
      completer.complete(futureValue as E);
    });
    onError((error, stackTrace) {
      completer.completeError(error, stackTrace as StackTrace?);
    });
    return completer.future;
  }
}
