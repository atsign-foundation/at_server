import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart' show AtSignLogger;

import 'inbound_connection_pool.dart';

// ignore: implementation_imports, unnecessary_import
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
    timeFrameInMillis = AtSecondaryConfig.timeFrameInMillis;
    requestTimestampQueue = Queue();
  }

  @override
  bool isRequestAllowed() {
    int currentTimeInMills = DateTime.now().millisecondsSinceEpoch;
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
    var currentTime = DateTime.timestamp();
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
    int poolMaxConnections = owningPool!.getCapacity();
    int lowWaterMark = (poolMaxConnections * lowWaterMarkRatio).floor();
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

class InboundCommandValidator {
  static final AtSignLogger logger = AtSignLogger('InboundCommandValidator');

  /// We only need enough of the buffer to identify the verb name (capped at 64
  /// chars below) and the optional subcommand, so for very long commands (e.g.
  /// large `update` values) we cap the decode here to a small prefix instead
  /// of decoding the entire payload twice (validator + listener).
  static const int _maxBytesForValidation = 256;

  static final Utf8Decoder _allowMalformedUtf8 =
      Utf8Decoder(allowMalformed: true);

  /// This function validates a command on a connection. The criteria is the following:
  /// 1. checks if connection is invalid, closing the connection if requires
  /// 2. if verb length is > 64, which doesn't exist, we'll close the connection
  /// 3. verifies verb meets connection type ie: unauthenticated client running update fails
  static void validate(List<int> bytes, AtConnection connection) {
    // If connection is invalid, throws ConnectionInvalidException and closes the connection
    if (connection.isInValid()) {
      throw ConnectionInvalidException(
          'Connection is invalid, closing connection');
    }

    // Decode only the prefix we need to identify the verb and (optionally)
    // its subcommand. This avoids decoding the full buffer when the rest is
    // a value (the listener will decode the full buffer once when isEnd()).
    final prefixLen = bytes.length > _maxBytesForValidation
        ? _maxBytesForValidation
        : bytes.length;
    String command = _allowMalformedUtf8.convert(bytes, 0, prefixLen).trim();
    var isAuthenticated = connection.metaData.isAuthenticated ||
        connection.metaData.isPolAuthenticated;

    // why does scan delimit with a space....
    if (command.contains('scan ') || command.contains('monitor ')) {
      return;
    }

    // First colon splits verb from the rest. For "verb:sub:value" we want
    // "verb" — indexOf + substring avoids allocating the split's List<String>.
    final firstColon = command.indexOf(':');
    final String rawVerb =
        (firstColon == -1 ? command : command.substring(0, firstColon)).trim();

    // covers 2 cases:
    // - any junk with a ':' inside, where we would try to parse the verb
    // - from the firstOrNull call, any junk that looks nothing like a command is removed.
    //
    // this constraint also catches the junk > 64, which we'll catch before trying to parse the verb
    if (rawVerb.length > 64) {
      throw InvalidSyntaxException(
          'Received verb with invalid length, closing connection.');
    }

    // what verb is this?
    final AtVerb? verb = AtVerb.tryParse(rawVerb);
    if (verb == null) {
      String exMsg = 'Received invalid verb that does not match protocol spec';
      logger.severe('$exMsg. rawVerb: $rawVerb command: $command');
      throw InvalidSyntaxException(exMsg);
    }

    // determine auth requirement - may be overridden if verb has subcommands
    bool requiresAuth = verb.requiresAuth;
    if (verb.hasSubcommands) {
      // Subcommand sits between the first and second colons.
      final secondColon = command.indexOf(':', firstColon + 1);
      final String rawSubcommand = (secondColon == -1
              ? command.substring(firstColon + 1)
              : command.substring(firstColon + 1, secondColon))
          .trim();
      final subcommand = Subcommand.tryParse(rawSubcommand);
      requiresAuth = subcommand?.requiresAuth ?? verb.requiresAuth;
    }

    if (requiresAuth && !isAuthenticated) {
      throw UnAuthenticatedException('Command cannot be executed without auth');
    }
  }
}
