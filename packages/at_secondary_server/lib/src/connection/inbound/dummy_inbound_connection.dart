import 'dart:io';

import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_server_spec/at_server_spec.dart';

/// A dummy implementation of [InboundConnection] class which returns a dummy inbound connection.
class DummyInboundConnection implements InboundConnection {
  var metadata = InboundConnectionMetadata();

  @override
  void acceptRequests(Function(String p1, InboundConnection p2) callback,
      Function(List<int>, InboundConnection) streamCallback) {}

  @override
  Future<void> close() async {}

  @override
  bool equals(InboundConnection connection) {
    if (connection is DummyInboundConnection) {
      return true;
    }
    return false;
  }

  @override
  AtConnectionMetaData getMetaData() {
    return metadata;
  }

  @override
  Socket getSocket() {
    throw UnimplementedError("DummyInboundConnection.getSocket is not implemented");
  }

  @override
  bool isInValid() {
    return metadata.isClosed;
  }

  String? lastWrittenData;
  @override
  void write(String data) {
    lastWrittenData = data;
  }

  @override
  bool? isMonitor;

  @override
  String? initiatedBy;

  bool isStream = false;

  @override
  Socket? receiverSocket;
}
