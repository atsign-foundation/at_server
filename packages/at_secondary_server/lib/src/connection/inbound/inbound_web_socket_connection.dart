import 'dart:async';
import 'dart:io';

import 'package:at_secondary/src/connection/base_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/connection/inbound/inbound_message_listener.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_secondary/src/utils/logging_util.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_utils.dart';

import 'connection_util.dart';

class InboundWebSocketConnection implements InboundConnection {
  WebSocket ws;

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

  InboundWebSocketConnection(this.ws, String? sessionId, this.owningPool) {
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

    logger.info(
        logger.getAtConnectionLogMessage(metaData, 'New WebSocket ($this)'));

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
  void acceptRequests(Function(String, InboundConnection) callback,
      Function(List<int>, InboundConnection) streamCallBack) {
    var listener = InboundMessageListener(this);
    listener.listen(callback, streamCallBack);
  }

  bool? isStream;

  @override
  Future<void> close() async {
    // Some defensive code just in case we accidentally call close multiple times
    if (metaData.isClosed) {
      logger.info('already closed; returning');
      return;
    }

    metaData.isClosed = true;

    try {
      logger.info(logger.getAtConnectionLogMessage(
          metaData, 'closing WebSocket (readyState ${ws.readyState})'));
      try {
        await ws.close();
      } catch (e) {
        logger.severe('ws.close() exception: $e');
      }
      logger.info(logger.getAtConnectionLogMessage(
          metaData, 'Closed WebSocket (readyState ${ws.readyState})'));
    } catch (_) {
      // Ignore exception on a connection close
      metaData.isStale = true;
    }
  }

  @override
  Future<void> write(String data) async {
    ws.add(data);
    logger.info(logger.getAtConnectionLogMessage(metaData, 'SENT: $data'));
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
