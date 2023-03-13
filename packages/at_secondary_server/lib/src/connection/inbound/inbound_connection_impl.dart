import 'dart:io';
import 'dart:math';

import 'package:at_secondary/src/connection/base_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/connection/inbound/inbound_message_listener.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';

import 'dummy_inbound_connection.dart';

class InboundConnectionImpl extends BaseConnection implements InboundConnection {
  @override
  bool? isMonitor = false;

  /// This contains the value of the atsign initiated the connection
  @override
  String? initiatedBy;

  InboundConnectionPool? owningPool;

  late int maxAllowableInboundIdleTimeMillis;
  late double lowWaterMarkRatio;
  late int unauthenticatedMinAllowableIdleTimeMillis;
  late int authenticatedMinAllowableIdleTimeMillis;
  late bool progressivelyReduceAllowableInboundIdleTime;

  InboundConnectionImpl(Socket? socket, String? sessionId, {this.owningPool}) : super(socket) {
    metaData = InboundConnectionMetadata()
      ..sessionID = sessionId
      ..created = DateTime.now().toUtc()
      ..isCreated = true;

    AtSecondaryContext? secondaryContext = AtSecondaryServerImpl.getInstance().serverContext;
    // In test harnesses, secondary context may not yet have been set, in which case create a default AtSecondaryContext instance
    secondaryContext ??= AtSecondaryContext();
    // We have one value set in config : inboundIdleTimeMillis
    maxAllowableInboundIdleTimeMillis = secondaryContext.inboundIdleTimeMillis;
    lowWaterMarkRatio = secondaryContext.inboundConnectionLowWaterMarkRatio;
    unauthenticatedMinAllowableIdleTimeMillis = secondaryContext.unauthenticatedMinAllowableIdleTimeMillis;

    // minAllowableIdleTimeMillis for authenticated connections should be a lot more generous.
    // if configured inboundIdleTimeMillis is 600,000 then authenticated min allowable will be 120,000
    // if configured inboundIdleTimeMillis is 60,000 then authenticated min allowable will be 30,000
    authenticatedMinAllowableIdleTimeMillis = (maxAllowableInboundIdleTimeMillis / 5).floor();
    progressivelyReduceAllowableInboundIdleTime = secondaryContext.progressivelyReduceAllowableInboundIdleTime;
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

    if (getSocket().remoteAddress.address == connection.getSocket().remoteAddress.address &&
        getSocket().remotePort == connection.getSocket().remotePort) {
      return true;
    }

    return false;
  }

  /// Returning true indicates to the caller that this connection **can** be closed if needed
  @override
  bool isInValid() {
    if (getMetaData().isClosed || getMetaData().isStale) {
      return true;
    }

    // If we don't know our owning pool, OR we've disabled the new logic, just use old logic
    if (owningPool == null || progressivelyReduceAllowableInboundIdleTime == false) {
      var retVal = _idleForLongerThanMax();
      return retVal;
    }

    // We do know our owning pool, so we'll use fancier logic.
    // Unauthenticated connections should be reaped increasingly aggressively as we approach max connections
    // Authenticated connections should also be reaped as we approach max connections, but a lot less aggressively
    // Ultimately, the caller (e.g. [InboundConnectionManager] decides **whether** to reap or not.
    int? poolMaxConnections = owningPool!.getCapacity();
    int lowWaterMark = (poolMaxConnections! * lowWaterMarkRatio).floor();
    int numConnectionsOverLwm = max(owningPool!.getCurrentSize() - lowWaterMark, 0);

    // We're past the low water mark. Let's use some fancier logic to mark connections invalid increasingly aggressively.
    double idleTimeReductionFactor = 1 - (numConnectionsOverLwm / (poolMaxConnections - lowWaterMark));
    if (!getMetaData().isAuthenticated && !getMetaData().isPolAuthenticated) {
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
      int allowableIdleTime = calcAllowableIdleTime(idleTimeReductionFactor, unauthenticatedMinAllowableIdleTimeMillis);
      var actualIdleTime = _getIdleTimeMillis();
      var retVal = actualIdleTime > allowableIdleTime;
      return retVal;
    } else {
      // For authenticated connections
      // TODO (1) if the connection has a request in progress, we should never mark it as invalid
      // (2) otherwise, we will mark as invalid using same algorithm as above, but using authenticatedMinAllowableIdleTimeMillis
      int allowableIdleTime = calcAllowableIdleTime(idleTimeReductionFactor, authenticatedMinAllowableIdleTimeMillis);
      var actualIdleTime = _getIdleTimeMillis();
      var retVal = actualIdleTime > allowableIdleTime;
      return retVal;
    }
  }

  int calcAllowableIdleTime(double idleTimeReductionFactor, int minAllowableIdleTimeMillis) =>
      (((maxAllowableInboundIdleTimeMillis - minAllowableIdleTimeMillis) * idleTimeReductionFactor) + minAllowableIdleTimeMillis).floor();

  /// Get the idle time of the inbound connection since last write operation
  int _getIdleTimeMillis() {
    var lastAccessedTime = getMetaData().lastAccessed;
    // if lastAccessedTime is not set, use created time
    lastAccessedTime ??= getMetaData().created;
    var currentTime = DateTime.now().toUtc();
    return currentTime.difference(lastAccessedTime!).inMilliseconds;
  }

  /// Returns true if the client's idle time is greater than configured idle time.
  /// false otherwise
  bool _idleForLongerThanMax() {
    return _getIdleTimeMillis() > maxAllowableInboundIdleTimeMillis;
  }

  @override
  void acceptRequests(Function(String, InboundConnection) callback, Function(List<int>, InboundConnection) streamCallBack) {
    var listener = InboundMessageListener(this);
    listener.listen(callback, streamCallBack);
  }

  @override
  Socket? receiverSocket;

  bool? isStream;

  @override
  Future<void> close() async {
    // Over-riding BaseConnection.close() (which calls socket.close()), as may want to keep different
    // behaviours for inbound and outbound connections
    // (Note however that, at time of writing, outbound_connection_impl also calls socket.destroy)

    // Some defensive code just in case we accidentally call close multiple times
    if (getMetaData().isClosed) {
      return;
    }

    try {
      var address = getSocket().remoteAddress;
      var port = getSocket().remotePort;
      getSocket().destroy();
      logger.finer('$address:$port Disconnected');
      getMetaData().isClosed = true;
    } on Exception {
      getMetaData().isStale = true;
      // Ignore exception on a connection close
    } on Error {
      getMetaData().isStale = true;
      // Ignore error on a connection close
    }
  }
}
