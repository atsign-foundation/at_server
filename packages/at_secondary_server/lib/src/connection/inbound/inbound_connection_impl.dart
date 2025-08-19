import 'dart:io';

import 'package:at_secondary/src/connection/base_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/connection/inbound/inbound_message_listener.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/logging_util.dart';
import 'package:at_server_spec/at_server_spec.dart';

import 'connection_util.dart';
import 'dummy_inbound_connection.dart';

class InboundConnectionImpl<T extends Socket> extends BaseSocketConnection
    implements InboundConnection {
  @override
  bool? isMonitor = false;

  /// This contains the value of the atsign initiated the connection
  @override
  String? initiatedBy;

  InboundConnectionPool? owningPool;

  late InboundRateLimiter rateLimiter;
  late InboundIdleChecker idleChecker;

  InboundConnectionImpl(T socket, String? sessionId, {this.owningPool})
      : super(socket) {
    metaData = InboundConnectionMetadata()
      ..sessionID = sessionId
      ..created = DateTime.now().toUtc()
      ..isCreated = true;

    AtSecondaryContext? secondaryContext =
        AtSecondaryServerImpl.getInstance().serverContext;
    // In test harnesses, secondary context may not yet have been set, in which case create a default AtSecondaryContext instance
    secondaryContext ??= AtSecondaryContext();

    idleChecker = InboundIdleChecker(secondaryContext, this, owningPool);
    rateLimiter = InboundRateLimiter();

    logger.info(logger.getAtConnectionLogMessage(
        metaData,
        'New connection ('
        'this side: ${underlying.address}:${underlying.port}'
        ' remote side: ${underlying.remoteAddress}:${underlying.remotePort}'
        ')'));

    socket.done.onError((error, stackTrace) {
      logger
          .info('socket.done.onError called with $error. Calling this.close()');
      close();
    });
  }

  /// Returns true if the underlying socket is not null and socket's remote address and port match.
  @override
  bool equals(InboundConnection connection) {
    // An InboundConnectionImpl can never be equal to a DummyInboundConnection.
    if (connection is DummyInboundConnection) {
      return false;
    }

    // Without the above check, we were getting runtime errors on the next check
    // since DummyInboundConnection.getSocket throws a "not implemented" error

    if (underlying.remoteAddress.address ==
            connection.underlying.remoteAddress.address &&
        underlying.remotePort == connection.underlying.remotePort) {
      return true;
    }

    return false;
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
  void acceptRequests(Function(String, InboundConnection) callback,
      Function(List<int>, InboundConnection) streamCallBack) {
    var listener = InboundMessageListener(this);
    listener.listen(callback, streamCallBack);
  }

  bool? isStream;

  @override
  Future<void> close() async {
    // Over-riding BaseConnection.close() (which calls socket.close()), as may want to keep different
    // behaviours for inbound and outbound connections
    // (Note however that, at time of writing, outbound_connection_impl also calls socket.destroy)

    // Some defensive code just in case we accidentally call close multiple times
    if (metaData.isClosed) {
      return;
    }

    try {
      logger.info(logger.getAtConnectionLogMessage(
          metaData,
          'destroying socket ('
          'this side: ${underlying.address}:${underlying.port}'
          ' remote side: ${underlying.remoteAddress}:${underlying.remotePort}'
          ')'));
      underlying.destroy();
    } catch (_) {
      // Ignore exception on a connection close
      metaData.isStale = true;
    } finally {
      metaData.isClosed = true;
    }
  }

  @override
  Future<void> write(String data) async {
    await super.write(data);
    if (metaData is InboundConnectionMetadata) {
      logger.info(logger.getAtConnectionLogMessage(
          metaData, 'SENT: ${BaseSocketConnection.truncateForLogging(data)}'));
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
}
