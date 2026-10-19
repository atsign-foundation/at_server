import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_server_spec/at_server_spec.dart';

enum InboundConnectionCloseReason {
  clientClosed('client_closed'),
  socketError('socket_error'),
  idleTimeout('idle_timeout'),
  stale('stale'),
  enrollmentRevoked('enrollment_revoked'),
  enrollmentInactive('enrollment_inactive'),
  protocolError('protocol_error'),
  serverShutdown('server_shutdown'),
  serverError('server_error'),
  unknown('unknown');

  final String wireName;

  const InboundConnectionCloseReason(this.wireName);

  static InboundConnectionCloseReason ofInvalid(AtConnection connection) {
    return connection.metaData.isStale ? stale : idleTimeout;
  }

  void markOn(AtConnection? connection) {
    final AtConnectionMetaData? metaData = connection?.metaData;
    if (metaData is InboundConnectionMetadata) {
      metaData.closeReason ??= this;
    }
  }
}
