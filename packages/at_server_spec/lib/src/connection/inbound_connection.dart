import 'dart:io';
import 'package:at_server_spec/src/connection/at_connection.dart';
import 'package:at_server_spec/src/rate_limiter/at_rate_limiter.dart';

abstract class InboundConnection extends AtConnection implements AtRateLimiter {
  ///Returns true if remote socket and remote port of this and connection matches
  bool equals(InboundConnection connection);

  bool? isMonitor;

  /// This contains the value of the atsign initiated the connection
  String? initiatedBy;

  void acceptRequests(Function(String, InboundConnection) callback,
      Function(List<int>, InboundConnection) streamCallback);

  Socket? receiverSocket;
}
