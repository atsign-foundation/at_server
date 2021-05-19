import 'dart:io';
import 'package:at_commons/at_commons.dart';
abstract class InboundConnection extends AtConnection {
  ///Returns true if remote socket and remote port of this and connection matches
  bool equals(InboundConnection connection);

  bool isMonitor;

  /// This contains the value of the atsign initiated the connection
  String initiatedBy;

  void acceptRequests(Function(String, InboundConnection) callback,
      Function(List<int>, InboundConnection) streamCallback);

  Socket receiverSocket;
}
