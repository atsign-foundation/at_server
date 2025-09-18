import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';

class ConnectionMetricsImpl implements ConnectionMetrics {
  @override
  int getInboundConnections() {
    return AtSecondaryServerImpl.getInstance()
        .inboundConnectionManager
        .pool
        .getActiveConnectionSize();
  }

  @override
  int getOutboundConnections() {
    return AtSecondaryServerImpl.getInstance()
        .outboundClientManager
        .getActiveConnectionSize();
  }
}
