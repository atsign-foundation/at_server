import 'dart:async';
import 'dart:io';

import 'package:at_commons/at_commons.dart' show ConnectionInvalidException;
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/connection/inbound/inbound_message_listener.dart';
import 'package:at_secondary/src/connection/inbound/inbound_write_queue.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_secondary/src/utils/logging_util.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_utils.dart';
import 'package:meta/meta.dart';

import 'connection_util.dart';

/// An inbound connection carried over a WebSocket, one text frame per write.
class InboundWebSocketConnection
    implements InboundConnection, DrainableConnection {
  WebSocket ws;

  /// The socket [ws] runs over.
  final Socket socket;

  AtSignLogger logger = AtSignLogger('InboundWebSocketConnection');

  @override
  late InboundConnectionMetadata metaData;

  @override
  bool? isMonitor = false;

  /// This contains the value of the atsign initiated the connection
  @override
  String? initiatedBy;

  InboundConnectionPool? owningPool;

  late InboundRateLimiter rateLimiter;
  late InboundIdleChecker idleChecker;

  late final InboundWriteQueue<String> _writes;

  InboundWebSocketConnection(
      this.ws, this.socket, String? sessionId, this.owningPool) {
    metaData = InboundConnectionMetadata()
      ..sessionID = sessionId
      ..created = DateTime.timestamp()
      ..isCreated = true;

    AtSecondaryContext? secondaryContext =
        AtSecondaryServerImpl.getInstance().serverContext;
    // In test harnesses, secondary context may not yet have been set, in which case create a default AtSecondaryContext instance
    secondaryContext ??= AtSecondaryContext();

    idleChecker = InboundIdleChecker(secondaryContext, this, owningPool);
    rateLimiter = InboundRateLimiter();
    _writes = InboundWriteQueue<String>(
        maxUnsentBytes: secondaryContext.inboundMaxUnsentBytes);

    if (logger.isLoggable('info')) {
      logger.info(
          logger.getAtConnectionLogMessage(metaData, 'New WebSocket ($this)'));
    }

    ws.done.then((doneValue) {
      logger.info('ws.done called. Calling this.close()');
      close();
    }, onError: (error, stackTrace) {
      logger.info('ws.done.onError called with $error. Calling this.close()');
      close();
    });
  }

  /// Returns true if the web sockets are identical
  @override
  bool equals(InboundConnection connection) {
    if (connection is! InboundWebSocketConnection) {
      return false;
    }

    return ws == connection.ws;
  }

  /// Returning true indicates to the caller that this connection **can** be closed if needed
  @override
  bool isInValid() {
    if (metaData.isClosed || metaData.isStale) {
      return true;
    }

    return idleChecker.isInValid();
  }

  @override
  void acceptRequests(Function(String, InboundConnection) callback) {
    var listener = InboundMessageListener(this);
    listener.listen(callback);
  }

  @override
  Future<void> get drained => _writes.drained;

  @override
  bool hold(int length) => _writes.hold(length,
      connection: this, logger: logger, closeAtLimit: _closeUnread);

  @override
  void release(int length) => _writes.release(length);

  /// Marks the connection stale once its WebSocket has stopped taking
  /// writes.
  void _failed(Object error) {
    logger.info('WebSocket stopped taking writes: $error');
    metaData.isStale = true;
  }

  /// How many bytes are waiting for the client to read.
  @visibleForTesting
  int get unsentBytes => _writes.unsentBytes;

  @override
  Future<void> close() async {
    // Some defensive code just in case we accidentally call close multiple times
    if (metaData.isClosed) {
      logger.info('already closed; returning');
      return;
    }

    metaData.isClosed = true;

    try {
      if (logger.isLoggable('info')) {
        logger.info(logger.getAtConnectionLogMessage(
            metaData, 'closing WebSocket (readyState ${ws.readyState})'));
      }
      _writes.close();
      final Future<void>? transport = _writes.transport;
      if (transport == null) {
        await ws.close();
      } else {
        // NOTE ws.close() throws while the write queue is bound, so it waits
        // until the queue's end has reached the WebSocket.
        unawaited(transport.then((_) => ws.close()).catchError(
            (Object e) => logger.severe('ws.close() exception: $e')));
      }
    } catch (e) {
      logger.severe('ws.close() exception: $e');
      metaData.isStale = true;
    }
  }

  /// Closes the connection and destroys its socket at once, sending no close
  /// frame, for a client that has stopped reading.
  Future<void> _closeUnread() async {
    if (metaData.isClosed) {
      return;
    }
    metaData.isClosed = true;
    if (logger.isLoggable('info')) {
      logger.info(logger.getAtConnectionLogMessage(
          metaData, 'destroying the socket of a WebSocket'));
    }
    _writes.close();
    socket.destroy();
  }

  @override
  Future<void> write(String data) async {
    if (isInValid()) {
      throw ConnectionInvalidException('Connection is invalid');
    }
    _writes.bindOnce(ws.addStream, onFailed: _failed, onEnded: close);
    await _writes.write(data, utf8Length(data),
        connection: this, logger: logger, closeAtLimit: _closeUnread);
    metaData.lastAccessed = DateTime.timestamp();
    if (logger.isLoggable('info')) {
      logger.info(logger.getAtConnectionLogMessage(
          metaData, 'SENT: ${sanitiseForLogging(data)}'));
    }
  }

  @override
  int get maxRequestsPerTimeFrame => rateLimiter.maxRequestsPerTimeFrame;

  @override
  set maxRequestsPerTimeFrame(int i) => rateLimiter.maxRequestsPerTimeFrame = i;

  @override
  int get timeFrameInMillis => rateLimiter.timeFrameInMillis;

  @override
  set timeFrameInMillis(int i) => rateLimiter.timeFrameInMillis = i;

  @override
  bool isRequestAllowed() {
    return rateLimiter.isRequestAllowed();
  }

  @override
  get underlying => ws;
}
