import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:at_secondary/src/connection/base_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/connection/inbound/inbound_message_listener.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/logging_util.dart';
import 'package:at_server_spec/at_server_spec.dart';

import 'dummy_inbound_connection.dart';

class InboundConnectionImpl<T extends Socket> extends BaseSocketConnection
    implements InboundConnection {
  @override
  bool? isMonitor = false;

  /// This contains the value of the atsign initiated the connection
  @override
  String? initiatedBy;

  InboundConnectionPool? owningPool;

  /// As number of connections increases then the "allowable" idle time
  /// reduces from the 'max' towards the 'min' value.
  late int unauthenticatedMaxAllowableIdleTimeMillis;

  /// As number of connections increases then the "allowable" idle time
  /// reduces from the 'max' towards the 'min' value.
  late int unauthenticatedMinAllowableIdleTimeMillis;

  /// As number of connections increases then the "allowable" idle time
  /// reduces from the 'max' towards the 'min' value.
  late int authenticatedMaxAllowableIdleTimeMillis;

  /// As number of connections increases then the "allowable" idle time
  /// reduces from the 'max' towards the 'min' value.
  late int authenticatedMinAllowableIdleTimeMillis;

  late double lowWaterMarkRatio;
  late bool progressivelyReduceAllowableInboundIdleTime;

  /// The maximum number of requests allowed within the specified time frame.
  @override
  late int maxRequestsPerTimeFrame;

  /// The duration of the time frame within which requests are limited.
  @override
  late int timeFrameInMillis;

  /// A list of timestamps representing the times when requests were made.
  late final Queue<int> requestTimestampQueue;

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

    lowWaterMarkRatio = secondaryContext.inboundConnectionLowWaterMarkRatio;
    progressivelyReduceAllowableInboundIdleTime =
        secondaryContext.progressivelyReduceAllowableInboundIdleTime;

    // As number of connections increases then the "allowable" idle time
    // reduces from the 'max' towards the 'min' value.
    unauthenticatedMaxAllowableIdleTimeMillis =
        secondaryContext.unauthenticatedInboundIdleTimeMillis;
    unauthenticatedMinAllowableIdleTimeMillis =
        secondaryContext.unauthenticatedMinAllowableIdleTimeMillis;

    authenticatedMaxAllowableIdleTimeMillis =
        secondaryContext.authenticatedInboundIdleTimeMillis;
    authenticatedMinAllowableIdleTimeMillis =
        secondaryContext.authenticatedMinAllowableIdleTimeMillis;

    maxRequestsPerTimeFrame = AtSecondaryConfig.maxEnrollRequestsAllowed;
    timeFrameInMillis = AtSecondaryConfig.timeFrameInMills;
    requestTimestampQueue = Queue();
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

    // If we don't know our owning pool, OR we've disabled the new logic, just use old logic
    if (owningPool == null ||
        progressivelyReduceAllowableInboundIdleTime == false) {
      var retVal = _idleForLongerThanMax();
      return retVal;
    }

    // We do know our owning pool, so we'll use fancier logic.
    // Unauthenticated connections should be reaped increasingly aggressively as we approach max connections
    // Authenticated connections should also be reaped as we approach max connections, but a lot less aggressively
    // Ultimately, the caller (e.g. [InboundConnectionManager] decides **whether** to reap or not.
    int? poolMaxConnections = owningPool!.getCapacity();
    int lowWaterMark = (poolMaxConnections! * lowWaterMarkRatio).floor();
    int numConnectionsOverLwm =
        max(owningPool!.getCurrentSize() - lowWaterMark, 0);

    // We're past the low water mark. Let's use some fancier logic to mark connections invalid increasingly aggressively.
    double idleTimeReductionFactor =
        1 - (numConnectionsOverLwm / (poolMaxConnections - lowWaterMark));
    if (!metaData.isAuthenticated && !metaData.isPolAuthenticated) {
      // For **unauthenticated** connections, we deem invalid if idle time is greater than
      // ((maxIdleTime - minIdleTime) * (1 - numConnectionsOverLwm / (maxConnections - connectionsLowWaterMark))) + minIdleTime
      //
      // i.e. as the current number of connections grows past low-water-mark, the tolerated idle time reduces
      // Given: Max connections of 50, lwm of 25, max idle time of 605 seconds, min idle time of 5 seconds
      // When: current == 25, idle time allowable = (605-5) * (1 - 0/25) + 5 i.e. 600 * 1.0 + 5 i.e. 605
      // When: current == 40, idle time allowable = (605-5) * (1 - 15/25) + 5 i.e. 600 * 0.4 + 5 i.e. 245
      // When: current == 49, idle time allowable = (605-5) * (1 - 24/25) + 5 i.e. 600 * 0.04 + 5 i.e. 24 + 5 i.e. 29
      // When: current == 50, idle time allowable = (605-5) * (1 - 25/25) + 5 i.e. 600 * 0.0 + 5 i.e. 0 + 5 i.e. 5
      //
      // Given: Max connections of 50, lwm of 10, max idle time of 605 seconds, min idle time of 5 seconds
      // When: current == 10, idle time allowable = (605-5) * (1 - (10-10)/(50-10)) + 5 i.e. 600 * (1 - 0/40) + 5 i.e. 605
      // When: current == 20, idle time allowable = (605-5) * (1 - (20-10)/(50-10)) + 5 i.e. 600 * (1 - 10/40) + 5 i.e. 455
      // When: current == 30, idle time allowable = (605-5) * (1 - (30-10)/(50-10)) + 5 i.e. 600 * (1 - 20/40) + 5 i.e. 305
      // When: current == 40, idle time allowable = (605-5) * (1 - (40-10)/(50-10)) + 5 i.e. 600 * (1 - 30/40) + 5 i.e. 155
      // When: current == 49, idle time allowable = (605-5) * (1 - (49-10)/(50-10)) + 5 i.e. 600 * (1 - 39/40) + 5 i.e. 600 * .025 + 5 i.e. 20
      // When: current == 50, idle time allowable = (605-5) * (1 - (50-10)/(50-10)) + 5 i.e. 600 * (1 - 40/40) + 5 i.e. 600 * 0 + 5 i.e. 5
      int allowableIdleTime = calcAllowableIdleTime(
          idleTimeReductionFactor,
          unauthenticatedMinAllowableIdleTimeMillis,
          unauthenticatedMaxAllowableIdleTimeMillis);
      var actualIdleTime = _getIdleTimeMillis();
      var retVal = actualIdleTime > allowableIdleTime;
      return retVal;
    } else {
      // For authenticated connections
      // TODO (1) if the connection has a request in progress, we should never mark it as invalid
      // (2) otherwise, we will mark as invalid using same algorithm as above, but using authenticatedMinAllowableIdleTimeMillis
      int allowableIdleTime = calcAllowableIdleTime(
          idleTimeReductionFactor,
          authenticatedMinAllowableIdleTimeMillis,
          authenticatedMaxAllowableIdleTimeMillis);
      var actualIdleTime = _getIdleTimeMillis();
      var retVal = actualIdleTime > allowableIdleTime;
      return retVal;
    }
  }

  int calcAllowableIdleTime(double idleTimeReductionFactor,
          int minAllowableIdleTimeMillis, int maxAllowableIdleTimeMillis) =>
      (((maxAllowableIdleTimeMillis - minAllowableIdleTimeMillis) *
                  idleTimeReductionFactor) +
              minAllowableIdleTimeMillis)
          .floor();

  /// Get the idle time of the inbound connection since last write operation
  int _getIdleTimeMillis() {
    var lastAccessedTime = metaData.lastAccessed;
    // if lastAccessedTime is not set, use created time
    lastAccessedTime ??= metaData.created;
    var currentTime = DateTime.now().toUtc();
    return currentTime.difference(lastAccessedTime!).inMilliseconds;
  }

  /// Returns true if the client's idle time is greater than configured idle time.
  /// false otherwise
  bool _idleForLongerThanMax() {
    var idleTimeMillis = _getIdleTimeMillis();
    if (metaData.isAuthenticated || metaData.isPolAuthenticated) {
      return idleTimeMillis > authenticatedMaxAllowableIdleTimeMillis;
    } else {
      return idleTimeMillis > unauthenticatedMaxAllowableIdleTimeMillis;
    }
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
      var address = underlying.remoteAddress;
      var port = underlying.remotePort;
      underlying.destroy();
      logger.finer(logger.getAtConnectionLogMessage(
          metaData, '$address:$port Disconnected'));
      metaData.isClosed = true;
    } on Exception {
      metaData.isStale = true;
      // Ignore exception on a connection close
    } on Error {
      metaData.isStale = true;
      // Ignore error on a connection close
    }
  }

  @override
  void write(String data) {
    super.write(data);
    if (metaData is InboundConnectionMetadata) {
      logger.info(logger.getAtConnectionLogMessage(
          metaData, 'SENT: ${BaseSocketConnection.truncateForLogging(data)}'));
    }
  }

  @override
  bool isRequestAllowed() {
    int currentTimeInMills = DateTime.now().toUtc().millisecondsSinceEpoch;
    _checkAndUpdateQueue(currentTimeInMills);
    if (requestTimestampQueue.length < maxRequestsPerTimeFrame) {
      requestTimestampQueue.addLast(currentTimeInMills);
      return true;
    }
    return false;
  }

  /// Checks and updates the request timestamp queue based on the current time.
  ///
  /// This method removes timestamps from the queue that are older than the specified
  /// time window.
  ///
  /// [currentTimeInMillis] is the current time in milliseconds since epoch.
  void _checkAndUpdateQueue(int currentTimeInMillis) {
    if (requestTimestampQueue.isEmpty) return;
    int calculatedTime = (currentTimeInMillis - requestTimestampQueue.first);
    while (calculatedTime >= timeFrameInMillis) {
      requestTimestampQueue.removeFirst();
      if (requestTimestampQueue.isEmpty) break;
      calculatedTime = (currentTimeInMillis - requestTimestampQueue.first);
    }
  }
}
