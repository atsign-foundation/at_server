import 'dart:io';

import 'package:at_persistence_root_server/src/redis_connection.dart';
import 'package:redis/redis.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_utils/at_logger.dart';

class RedisConnectionPool {
  final List<AtRedisConnection> _usedConnections = [];
  final List<AtRedisConnection> _pooledConnections = [];
  final int _init_pool_size = 5;
  final int _max_pool_size = 15;
  AtRedisConfig _atRedisConfig;
  final logger = AtSignLogger('RedisConnectionPool');

  Future<bool> init(AtRedisConfig atRedisConfig) async {
    _atRedisConfig = atRedisConfig;
    logger.info('initializing redis connection pool');
    for (var i = 0; i < _init_pool_size; i++) {
      var conn = await create(atRedisConfig);
      _pooledConnections.add(conn);
    }
    logger.info('completed init redis connection pool');
    return true;
  }

  Future<AtRedisConnection> getConnection() async {
    if (_pooledConnections.isEmpty) {
      if (_usedConnections.length < _max_pool_size) {
        _pooledConnections.add(await create(_atRedisConfig));
      } else {
        throw Exception('Redis Max Pool Size reached');
      }
    }
    var connection = _pooledConnections.removeLast();
    _usedConnections.add(connection);
    return connection;
  }

  void releaseConnection(AtRedisConnection connection) {
    _pooledConnections.add(connection);
    _usedConnections.remove(connection);
  }

  Future<AtRedisConnection> create(AtRedisConfig atRedisConfig) async {
    var atRedisConnection = AtRedisConnection();
    var connection = RedisConnection();
    try {
      var command =
          await connection.connect(atRedisConfig.host, atRedisConfig.port);
      if (atRedisConfig.auth != null) {
        await command.send_object(['AUTH', '${atRedisConfig.auth}']);
      }
      atRedisConnection.connection = connection;
      atRedisConnection.command = command;
    } catch (e) {
      if (e is SocketException) {
        logger.severe('SocketException connecting to redis: ${e.message}');
        throw DataStoreException('Redis connection failed',
            vendorErrorCode: e.osError.errorCode, vendorException: e);
      } else if (e is RedisError) {
        logger.severe('Error connecting to redis: ${e.toString()}');
        throw DataStoreException(e.toString());
      }
      throw DataStoreException('Redis connection failed');
    }
    return atRedisConnection;
  }

  int getSize() => _usedConnections.length + _pooledConnections.length;

  int getUsedSize() => _usedConnections.length;

  int getPooledSize() => _pooledConnections.length;

  void releaseAllConnections() {
    _usedConnections.forEach((c) async => await c.close());
    _pooledConnections.forEach((c) async => await c.close());
    _usedConnections.clear();
    _pooledConnections.clear();
  }
}
