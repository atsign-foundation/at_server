import 'dart:io';
import 'package:at_server_spec/src/connection/at_connection.dart';

abstract class InboundConnection extends AtConnection {
  ///Returns true if remote socket and remote port of this and connection matches
  bool equals(InboundConnection connection);

  bool isMonitor;

  bool isStream;

  /// This contains the value of the atsign initiated the connection
  String initiatedBy;

  void acceptRequests(Function(String, InboundConnection) callback,
      Function(List<int>, InboundConnection) streamCallback);

  Socket receiverSocket;
}
