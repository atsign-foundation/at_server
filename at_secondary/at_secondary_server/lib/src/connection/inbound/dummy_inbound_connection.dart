import 'dart:io';
import 'package:at_server_spec/at_server_spec.dart';

/// A dummy implementation of [InboundConnection] class which returns a dummy inbound connection.
class DummyInboundBoundConnection implements InboundConnection {
  static final DummyInboundBoundConnection _singleton =
      DummyInboundBoundConnection._internal();

  factory DummyInboundBoundConnection.getInstance() {
    return _singleton;
  }

  DummyInboundBoundConnection._internal();

  @override
  void acceptRequests(Function(String p1, InboundConnection p2) callback,
      Function(List<int>, InboundConnection) streamCallback) {}

  @override
  void close() {}

  @override
  bool equals(InboundConnection connection) {
    return true;
  }

  @override
  AtConnectionMetaData getMetaData() {
    return null;
  }

  @override
  Socket getSocket() {
    return null;
  }

  @override
  bool isInValid() {
    return false;
  }

  @override
  void write(String data) {}

  @override
  bool isMonitor;

  @override
  String initiatedBy;

  @override
  bool isStream = false;

  @override
  Socket receiverSocket;
}
