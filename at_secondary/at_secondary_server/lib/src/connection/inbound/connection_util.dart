import 'inbound_connection_pool.dart';

class ConnectionUtil {
  /// Returns true if the [atSign] passed has a stream initiated.
  /// else false
  static bool hasInitiatedStream(String atSign) {
    var connectionsList = InboundConnectionPool.getInstance().getConnections();
    connectionsList.forEach((connection) {
      if (!connection.isInValid() &&
          connection.isStream &&
          connection.initiatedBy == atSign) {
        return true;
      }
      return false;
    });
    return false;
  }

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
