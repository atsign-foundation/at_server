import 'dart:async';
import 'dart:io';
import 'package:at_secondary/src/connection/outbound/outbound_connection.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/logging_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';

class OutboundConnectionImpl<T extends Socket>
    extends OutboundSocketConnection {
  @override
  bool authenticated = false;

  final Completer<void> _closed = Completer<void>();

  @override
  Future<void> get closed => _closed.future;

  int get outboundIdleTime {
    if (authenticated) {
      return AtSecondaryServerImpl.getInstance()
          .serverContext!
          .authenticatedOutboundIdleTimeMillis;
    } else {
      return AtSecondaryServerImpl.getInstance()
          .serverContext!
          .unauthenticatedOutboundIdleTimeMillis;
    }
  }

  OutboundConnectionImpl(T socket, String? toAtSign) : super(socket) {
    var sessionId = SecondaryUtil.makeSessionId();
    metaData = OutboundConnectionMetadata()
      ..sessionID = sessionId
      ..toAtSign = toAtSign
      ..created = DateTime.timestamp()
      ..isCreated = true;

    if (logger.isLoggable('info')) {
      logger.info(logger.getAtConnectionLogMessage(
          metaData,
          'New connection ('
          'this side: ${underlying.address}:${underlying.port}'
          ' remote side: ${underlying.remoteAddress}:${underlying.remotePort}'
          ')'));
    }

    socket.done.onError((error, stackTrace) {
      logger
          .info('socket.done.onError called with $error. Calling this.close()');
      close();
    });
  }

  int _getIdleTimeMillis() {
    var lastAccessedTime = metaData.lastAccessed;
    lastAccessedTime ??= metaData.created;
    var currentTime = DateTime.timestamp();
    return currentTime.difference(lastAccessedTime!).inMilliseconds;
  }

  bool _isIdle() {
    return _getIdleTimeMillis() > outboundIdleTime;
  }

  @override
  bool isInValid() {
    return _isIdle() || metaData.isClosed || metaData.isStale;
  }

  @override
  Future<void> close() async {
    // Over-riding BaseConnection.close() (which calls socket.close()), as only want to change
    // behaviour for outbound connections for now, not inbound connections

    // Some defensive code just in case we accidentally call close multiple times
    if (metaData.isClosed) {
      _completeClosed();
      return;
    }

    try {
      var socket = underlying;
      if (logger.isLoggable('info')) {
        logger.info(logger.getAtConnectionLogMessage(
            metaData,
            'destroying socket ('
            'this side: ${underlying.address}:${underlying.port}'
            ' remote side: ${underlying.remoteAddress}:${underlying.remotePort}'
            ')'));
      }
      socket.destroy();
    } catch (_) {
      // Ignore exception on a connection close
      metaData.isStale = true;
    } finally {
      metaData.isClosed = true;
      _completeClosed();
    }
  }

  void _completeClosed() {
    if (!_closed.isCompleted) {
      _closed.complete();
    }
  }

  @override
  Future<void> write(String data) async {
    await super.write(data);
    if (logger.isLoggable('info')) {
      logger.info(logger.getAtConnectionLogMessage(
          metaData, 'SENT: ${sanitiseForLogging(data)}'));
    }
  }
}
