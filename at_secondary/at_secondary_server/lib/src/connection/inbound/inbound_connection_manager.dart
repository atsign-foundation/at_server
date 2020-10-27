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

  static const int default_pool_size = 10;

  bool _isInitialized = false;

  InboundConnectionPool _pool;

  factory InboundConnectionManager.getInstance() {
    return _singleton;
  }

  /// Creates and adds [InboundConnection] to the pool
  /// If the pool is not initialized, initializes the pool with [default_pool_size]
  /// @param socket - client socket
  /// @param sessionId - current sessionId
  /// Throws a [InboundConnectionLimitException] if pool doesn't have capacity
  @override
  InboundConnection createConnection(Socket socket, {String sessionId}) {
    if (!_isInitialized) {
      init(default_pool_size);
    }
    if (!hasCapacity()) {
      throw InboundConnectionLimitException(
          'max limit reached on inbound pool');
    }
    sessionId ??= '_' + Uuid().v4();
    var atConnection = InboundConnectionImpl(socket, sessionId);
    _add(atConnection);
    return atConnection;
  }

  bool hasCapacity() {
    _pool.clearInvalidConnections();
    return _pool.hasCapacity();
  }

  /// Initialises inbound client pool with a given size.
  /// @param - size - Maximum clients the pool can hold
  void init(int size) {
    _pool = InboundConnectionPool.getInstance();
    _pool.init(size);
    _isInitialized = true;
  }

  bool _add(InboundConnection inboundConnection) {
    _pool.add(inboundConnection);
    return true;
  }

  /// Closes all the active connections accepted by the secondary
  bool removeAllConnections() {
    return _pool.clearAllConnections();
  }
}
