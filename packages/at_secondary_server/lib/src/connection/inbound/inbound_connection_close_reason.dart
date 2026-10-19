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
}
