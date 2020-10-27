import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_server_spec/src/server/at_server.dart';

/// Represents the secondary server of the @protocol.
/// Contains methods to start, stop and server the requests.
abstract class AtSecondaryServer implements AtServer {
  /// Sets the executor for the requests to the server
  setExecutor(VerbExecutor executor);

  /// Sets Verb handler to be used by the server
  setVerbHandlerManager(VerbHandlerManager handlerManager);

  /// Returns various connection metrics
  ConnectionMetrics getMetrics();

  /// Sets the server context
  /// @param context - context for this server to start
  setServerContext(AtServerContext context);
}

///
/// Access point to the statistics of an [AtConnection]
///
abstract class ConnectionMetrics {
  /// Returns the number of active connections
  /// 0 if not available.
  int getInboundConnections();

  /// Returns the number of active connections made by the current secondary to another secondary server
  /// 0 if not available.
  int getOutboundConnections();
}
