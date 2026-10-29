import 'dart:async';
import 'dart:collection';

import 'package:at_commons/at_commons.dart' show ConnectionInvalidException;
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/utils/logging_util.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';

/// A connection that holds back what its peer has not yet read, and can say
/// when it has caught up.
abstract interface class DrainableConnection {
  /// Completes once nothing is waiting to be sent, or the connection has
  /// closed.
  Future<void> get drained;

  /// Counts [length] bytes held for this connection before they are written,
  /// against the same limit as the bytes waiting to be sent. Returns false,
  /// counting nothing, once the connection has closed, or when bytes are
  /// already waiting or held and [length] would take them above the limit,
  /// which closes the connection with the over-limit warning.
  bool hold(int length);

  /// Stops counting [length] bytes that [hold] counted.
  void release(int length);
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
  int _heldBytes = 0;
  bool _closed = false;
  Completer<void>? _drained;
  Future<void>? _transport;

  /// What the transport is bound to.
  Stream<T> get stream => _out.stream;

  /// How many bytes are waiting for the transport.
  int get unsentBytes => _unsentBytes;

  /// How many bytes are held for the connection outside the queue.
  int get heldBytes => _heldBytes;

  /// Whether the transport is bound and not paused, so a write is handed to
  /// it at once.
  bool get takingWrites => _out.hasListener && !_out.isPaused;

  /// What the transport's binding becomes once it ends, or null before the
  /// first [bindOnce].
  Future<void>? get transport => _transport;

  /// Binds the transport on the first call, through [addStream], which may
  /// throw. When the transport stops taking writes, the queue closes and
  /// then [onFailed] runs, or [onEnded] when it ended without an error
  /// before the queue was closed.
  void bindOnce(Future<void> Function(Stream<T> stream) addStream,
      {required void Function(Object error) onFailed,
      required void Function() onEnded}) {
    if (_transport != null) {
      return;
    }
    _transport = addStream(stream).then((_) {
      if (!_closed) {
        close();
        onEnded();
      }
    }, onError: (Object error) {
      close();
      onFailed(error);
    });
  }

  /// Queues [data], [length] bytes long, for [connection]. When bytes are
  /// already waiting or held and [data] would take them above
  /// [maxUnsentBytes], logs one warning through [logger] naming
  /// [connection], closes it through [closeAtLimit] and throws
  /// [ConnectionInvalidException]; it throws that too once the queue has
  /// closed.
  Future<void> write(T data, int length,
      {required InboundConnection connection,
      required AtSignLogger logger,
      required Future<void> Function() closeAtLimit}) async {
    if (_closed) {
      throw ConnectionInvalidException('Connection is invalid');
    }
    if (add(data, length)) {
      return;
    }
    _warnOverLimit(length, connection, logger);
    await closeAtLimit();
    throw ConnectionInvalidException(
        'Connection closed: too many bytes waiting for the client to read');
  }

  /// Counts [length] bytes held for [connection] outside the queue, against
  /// the same limit as those waiting in it. When bytes are already waiting
  /// or held and [length] would take them above [maxUnsentBytes], logs the
  /// one warning through [logger], closes [connection] through
  /// [closeAtLimit] and returns false; returns false without a warning once
  /// the queue has closed.
  bool hold(int length,
      {required InboundConnection connection,
      required AtSignLogger logger,
      required Future<void> Function() closeAtLimit}) {
    if (_closed) {
      return false;
    }
    if (_fits(length)) {
      _heldBytes += length;
      return true;
    }
    _warnOverLimit(length, connection, logger);
    unawaited(closeAtLimit());
    return false;
  }

  /// Stops counting [length] bytes that [hold] counted.
  void release(int length) {
    _heldBytes -= length;
  }

  bool _fits(int length) {
    final int waiting = _unsentBytes + _heldBytes;
    return waiting == 0 || waiting + length <= maxUnsentBytes;
  }

  void _warnOverLimit(
      int length, InboundConnection connection, AtSignLogger logger) {
    final AtConnectionMetaData metaData = connection.metaData;
    final String who = metaData is InboundConnectionMetadata
        ? describeInboundConnection(metaData)
        : 'session ${metaData.sessionID}';
    logger.warning('Closing $who:'
        ' ${_unsentBytes + _heldBytes + length} bytes would be'
        ' waiting for it to read, over the limit of $maxUnsentBytes');
  }

  /// Completes once nothing is waiting, or the queue has closed.
  Future<void> get drained => _waiting.isEmpty
      ? Future<void>.value()
      : (_drained ??= Completer<void>()).future;

  /// Hands [data], [length] bytes long, to the transport, or holds it while
  /// the transport is paused. Returns false, taking nothing, when bytes are
  /// already waiting or held and [data] would take them above
  /// [maxUnsentBytes], or when the queue is closed. A write onto an empty
  /// queue with nothing held is always taken.
  bool add(T data, int length) {
    if (_closed || !_fits(length)) {
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
    while (_waiting.isNotEmpty && !_out.isPaused) {
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

/// The bytes [text] takes as UTF-8, counted without encoding it. An unpaired
/// surrogate counts as the three bytes of the U+FFFD that replaces it.
int utf8Length(String text) {
  int bytes = 0;
  for (int i = 0; i < text.length; i++) {
    final int unit = text.codeUnitAt(i);
    if (unit < 0x80) {
      bytes += 1;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (unit >= 0xD800 &&
        unit <= 0xDBFF &&
        i + 1 < text.length &&
        (text.codeUnitAt(i + 1) & 0xFC00) == 0xDC00) {
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}
