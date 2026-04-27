import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_server_spec/at_server_spec.dart';

/// A dummy implementation of [InboundConnection] class which returns a dummy inbound connection.
class DummyInboundConnection implements InboundConnection {
  InboundConnectionMetadata metadata = InboundConnectionMetadata();

  @override
  int maxRequestsPerTimeFrame = AtSecondaryConfig.maxEnrollRequestsAllowed;

  @override
  int timeFrameInMillis = AtSecondaryConfig.timeFrameInMillis;

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
  InboundConnectionMetadata get metaData => metadata;

  @override
  dynamic get underlying {
    throw UnimplementedError(
        "DummyInboundConnection.getSocket is not implemented");
  }

  @override
  bool isInValid() {
    return metadata.isClosed;
  }

  String? lastWrittenData;
  @override
  Future<void> write(String data) async {
    lastWrittenData = data;
  }

  @override
  bool? isMonitor;

  @override
  String? initiatedBy;

  bool isStream = false;

  @override
  bool isRequestAllowed() {
    return true;
  }
}
