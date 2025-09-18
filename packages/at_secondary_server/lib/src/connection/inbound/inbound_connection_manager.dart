import 'dart:io';
import 'package:at_secondary/src/connection/connection_factory.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_web_socket_connection.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:uuid/uuid.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';

/// Factory to create and maintain [InboundConnection] using [InboundConnectionPool]
class InboundConnectionManager implements AtConnectionFactory {
  final int poolSize;
  late InboundConnectionPool pool;
  final String serverAtSign;
  bool _closed = false;

  bool get closed => _closed;

  InboundConnectionManager(
      {required this.serverAtSign, required this.poolSize}) {
    pool = InboundConnectionPool(serverAtSign: serverAtSign, size: poolSize);
  }

  /// Creates and adds an [InboundConnectionImpl] to the pool
  /// @param socket - client socket
  /// @param sessionId - current sessionId
  /// Throws a [InboundConnectionLimitException] if pool doesn't have capacity
  @override
  InboundConnection createSocketConnection(Socket socket, {String? sessionId}) {
    if (closed) {
      throw StateError('InboundConnectionManager is closed');
    }
    if (!hasCapacity()) {
      throw InboundConnectionLimitException(
          'max limit reached on inbound pool');
    }
    sessionId ??= '_${Uuid().v4()}';
    var atConnection =
        InboundConnectionImpl(socket, sessionId, owningPool: pool);
    pool.add(atConnection);

    return atConnection;
  }

  /// Creates and adds an [InboundWebSocketConnection] to the pool
  /// If the pool is not initialized, initializes the pool with [defaultPoolSize]
  /// @param socket - client socket
  /// @param sessionId - current sessionId
  /// Throws a [InboundConnectionLimitException] if pool doesn't have capacity
  @override
  InboundConnection createWebSocketConnection(WebSocket ws,
      {String? sessionId}) {
    if (closed) {
      throw StateError('InboundConnectionManager is closed');
    }
    if (!hasCapacity()) {
      throw InboundConnectionLimitException(
          'max limit reached on inbound pool');
    }
    sessionId ??= '_${Uuid().v4()}';
    var atConnection = InboundWebSocketConnection(ws, sessionId, pool);
    pool.add(atConnection);

    return atConnection;
  }

  bool hasCapacity() {
    pool.clearInvalidConnections();
    return pool.hasCapacity();
  }

  /// Closes all the active inbound connections, prevents new ones.
  bool close() {
    _closed = true;
    return pool.clearAllConnections();
  }
}
