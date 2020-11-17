import 'inbound_connection_pool.dart';

class ConnectionUtil {
  /// Returns the number of active monitor connections.
  static int getMonitorConnectionSize() {
    var count = 0;
    InboundConnectionPool.getInstance().getConnections().forEach((connection) {
      if (!connection.isInValid() && connection.isMonitor) {
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
