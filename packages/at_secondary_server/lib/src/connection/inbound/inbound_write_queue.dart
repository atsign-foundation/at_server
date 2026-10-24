import 'dart:async';
import 'dart:collection';

/// A connection that holds back what its peer has not yet read, and can say
/// when it has caught up.
abstract interface class DrainableConnection {
  /// Completes once nothing is waiting to be sent, or the connection has
  /// closed.
  Future<void> get drained;
}

/// What an inbound connection has written that its transport has not yet
/// taken. The transport is bound to [stream] once and pauses it while its
/// peer is not reading; whatever is written meanwhile waits here.
class InboundWriteQueue<T> {
  /// A queue holding at most [maxUnsentBytes] waiting behind one write.
  InboundWriteQueue({required this.maxUnsentBytes}) {
    // NOTE pumped from a microtask: inside the transport's own listen or
    // resume callback a write is parked rather than delivered, so the count
    // would drop before the transport has taken it.
    _out = StreamController<T>(
        sync: true,
        onListen: () => scheduleMicrotask(_pump),
        onResume: () => scheduleMicrotask(_pump));
  }

  /// The most bytes that may wait once something is already waiting.
  final int maxUnsentBytes;

  late final StreamController<T> _out;
  final Queue<(T, int)> _waiting = Queue<(T, int)>();
  int _unsentBytes = 0;
  bool _closed = false;
  Completer<void>? _drained;

  /// What the transport is bound to.
  Stream<T> get stream => _out.stream;

  /// How many bytes are waiting for the transport.
  int get unsentBytes => _unsentBytes;

  bool get isClosed => _closed;

  /// Completes once nothing is waiting, or the queue has closed.
  Future<void> get drained => _waiting.isEmpty || _closed
      ? Future<void>.value()
      : (_drained ??= Completer<void>()).future;

  /// Hands [data], [length] bytes long, to the transport, or holds it while
  /// the transport is paused. Returns false, taking nothing, when bytes are
  /// already waiting and [data] would take them above [maxUnsentBytes], or
  /// when the queue is closed. A write onto an empty queue is always taken.
  bool add(T data, int length) {
    if (_closed ||
        (_unsentBytes > 0 && _unsentBytes + length > maxUnsentBytes)) {
      return false;
    }
    _waiting.add((data, length));
    _unsentBytes += length;
    _pump();
    return true;
  }

  /// Drops whatever is waiting and ends [stream] once the transport takes
  /// the end.
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _waiting.clear();
    _unsentBytes = 0;
    _completeDrained();
    unawaited(_out.close());
  }

  void _pump() {
    while (_waiting.isNotEmpty && _out.hasListener && !_out.isPaused) {
      final (T data, int length) = _waiting.removeFirst();
      _unsentBytes -= length;
      _out.add(data);
    }
    if (_waiting.isEmpty) {
      _completeDrained();
    }
  }

  void _completeDrained() {
    final Completer<void>? drained = _drained;
    _drained = null;
    drained?.complete();
  }
}
