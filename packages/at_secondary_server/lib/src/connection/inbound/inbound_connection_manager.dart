import 'dart:io';
import 'package:at_secondary/src/connection/connection_factory.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:uuid/uuid.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';

/// Factory to create and maintain [InboundConnection] using [InboundConnectionPool]
class InboundConnectionManager implements AtConnectionFactory {
  static final InboundConnectionManager _singleton =
      InboundConnectionManager._internal();

  InboundConnectionManager._internal();

  static const int defaultPoolSize = 100;

  bool _isInitialized = false;

  late InboundConnectionPool _pool;

  factory InboundConnectionManager.getInstance() {
    return _singleton;
  }

  /// Creates and adds an [InboundConnectionImpl] to the pool
  /// If the pool is not initialized, initializes the pool with [defaultPoolSize]
  /// @param socket - client socket
  /// @param sessionId - current sessionId
  /// Throws a [InboundConnectionLimitException] if pool doesn't have capacity
  @override
  InboundConnection createSocketConnection(Socket socket, {String? sessionId}) {
    if (!_isInitialized) {
      init(defaultPoolSize);
    }
    if (!hasCapacity()) {
      throw InboundConnectionLimitException(
          'max limit reached on inbound pool');
    }
    sessionId ??= '_${Uuid().v4()}';
    var atConnection =
        InboundConnectionImpl(socket, sessionId, owningPool: _pool);
    _pool.add(atConnection);

    return atConnection;
  }

  /// Creates and adds an [InboundWebSocketConnection] to the pool
  /// If the pool is not initialized, initializes the pool with [defaultPoolSize]
  /// @param socket - client socket
  /// @param sessionId - current sessionId
  /// Throws a [InboundConnectionLimitException] if pool doesn't have capacity
  @override
  InboundConnection createWebSocketConnection(WebSocket socket,
      {String? sessionId}) {
    if (!_isInitialized) {
      init(defaultPoolSize);
    }
    if (!hasCapacity()) {
      throw InboundConnectionLimitException(
          'max limit reached on inbound pool');
    }
    sessionId ??= '_${Uuid().v4()}';

    throw UnimplementedError('not yet implemented');
    // _pool.add(atConnection);
    //
    // return atConnection;
  }

  bool hasCapacity() {
    _pool.clearInvalidConnections();
    return _pool.hasCapacity();
  }

  /// Initialises inbound client pool with a given size.
  /// @param - size - Maximum clients the pool can hold
  void init(int size, {bool isColdInit = true}) {
    _pool = InboundConnectionPool.getInstance();
    _pool.init(size, isColdInit: isColdInit);
    _isInitialized = true;
  }

  /// Closes all the active connections accepted by the secondary
  bool removeAllConnections() {
    return _pool.clearAllConnections();
  }
}
