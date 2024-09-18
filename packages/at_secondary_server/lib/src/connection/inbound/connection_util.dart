import 'dart:collection';
import 'dart:math';

import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_server_spec/at_server_spec.dart';

import 'inbound_connection_pool.dart';

// ignore: implementation_imports
import 'package:at_server_spec/src/at_rate_limiter/at_rate_limiter.dart';

class InboundRateLimiter implements AtRateLimiter {
  /// The maximum number of requests allowed within the specified time frame.
  @override
  late int maxRequestsPerTimeFrame;

  /// The duration of the time frame within which requests are limited.
  @override
  late int timeFrameInMillis;

  /// A list of timestamps representing the times when requests were made.
  late final Queue<int> requestTimestampQueue;

  InboundRateLimiter() {
    maxRequestsPerTimeFrame = AtSecondaryConfig.maxEnrollRequestsAllowed;
    timeFrameInMillis = AtSecondaryConfig.timeFrameInMills;
    requestTimestampQueue = Queue();
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

class InboundIdleChecker {
  AtSecondaryContext secondaryContext;
  InboundConnection connection;
  InboundConnectionPool? owningPool;

  InboundIdleChecker(this.secondaryContext, this.connection, this.owningPool) {
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
  }

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

  int calcAllowableIdleTime(double idleTimeReductionFactor,
          int minAllowableIdleTimeMillis, int maxAllowableIdleTimeMillis) =>
      (((maxAllowableIdleTimeMillis - minAllowableIdleTimeMillis) *
                  idleTimeReductionFactor) +
              minAllowableIdleTimeMillis)
          .floor();

  /// Get the idle time of the inbound connection since last write operation
  int _getIdleTimeMillis() {
    var lastAccessedTime = connection.metaData.lastAccessed;
    // if lastAccessedTime is not set, use created time
    lastAccessedTime ??= connection.metaData.created;
    var currentTime = DateTime.now().toUtc();
    return currentTime.difference(lastAccessedTime!).inMilliseconds;
  }

  /// Returns true if the client's idle time is greater than configured idle time.
  /// false otherwise
  bool _idleForLongerThanMax() {
    var idleTimeMillis = _getIdleTimeMillis();
    if (connection.metaData.isAuthenticated ||
        connection.metaData.isPolAuthenticated) {
      return idleTimeMillis > authenticatedMaxAllowableIdleTimeMillis;
    } else {
      return idleTimeMillis > unauthenticatedMaxAllowableIdleTimeMillis;
    }
  }

  bool isInValid() {
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
    if (!connection.metaData.isAuthenticated &&
        !connection.metaData.isPolAuthenticated) {
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
}

class ConnectionUtil {
  /// Returns the number of active monitor connections.
  static int getMonitorConnectionSize() {
    var count = 0;
    InboundConnectionPool.getInstance().getConnections().forEach((connection) {
      if (!connection.isInValid() && connection.isMonitor!) {
        count++;
      }
    });

    return count;
  }

  /// Returns the number of active connections.
  static int getActiveConnectionSize() {
    var count = 0;
    InboundConnectionPool.getInstance().getConnections().forEach((connection) {
      if (!connection.isInValid()) {
        count++;
      }
    });

    return count;
  }

  /// Return total capacity of connection manager of connection pool.
  static int totalConnectionSize() {
    return InboundConnectionPool.getInstance().getConnections().length;
  }
}
