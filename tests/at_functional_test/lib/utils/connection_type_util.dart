import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_utils/at_utils.dart';
import 'package:at_functional_test/conf/config_util.dart';


class ConnectionTypeUtil {
  /// Reads the connection type from the YAML configuration and maps it to the `ConnectionType` enum.
  static ConnectionType getConnectionType(String serverConfigKey) {
    // Read the connection type from the YAML
    String? connectionTypeString =
        ConfigUtil.getYaml()![serverConfigKey]['firstAtSignConnectionType'];

    // Map the string to the ConnectionType enum
    switch (connectionTypeString?.toLowerCase()) {
      case 'websocket':
        return ConnectionType.webSocket;
      case 'socket':
      default:
        return ConnectionType.socket; // Default to socket if no match or null
    }
  }
}
