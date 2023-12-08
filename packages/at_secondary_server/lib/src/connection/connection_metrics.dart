import 'package:at_secondary/src/connection/inbound/connection_util.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';

class ConnectionMetricsImpl implements ConnectionMetrics {
  @override
  int getInboundConnections() {
    return ConnectionUtil.getActiveConnectionSize();
  }

  @override
  int getOutboundConnections() {
    return AtSecondaryServerImpl.getInstance().outboundClientManager.getActiveConnectionSize();
  }
}
