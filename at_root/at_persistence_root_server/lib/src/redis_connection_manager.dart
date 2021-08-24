import 'package:at_persistence_root_server/src/redis_connection.dart';
import 'package:at_persistence_root_server/src/redis_connection_pool.dart';
import 'package:at_utils/at_logger.dart';

class RedisConnectionManager {
  RedisConnectionPool? pool;
  AtRedisConfig? _atRedisConfig;
  final logger = AtSignLogger('RedisConnectionManager');
  static final RedisConnectionManager _singleton =
      RedisConnectionManager._internal();

  factory RedisConnectionManager.getInstance() {
    return _singleton;
  }

  RedisConnectionManager._internal();

  Future<bool?> init(String host, int port, String auth) async {
    logger.info('initializing redis connection manager');
    _atRedisConfig = AtRedisConfig();
    _atRedisConfig!.host = host;
    _atRedisConfig!.port = port;
    _atRedisConfig!.auth = auth;
    bool? result;
    if (pool == null) {
      //ensures init pool is not called multiple times
      pool = RedisConnectionPool();
      result = await pool!.init(_atRedisConfig);
      logger.info('connection pool init result $result');
    }
    return result;
  }

  Future<AtRedisConnection> getConnection() async {
    return await pool!.getConnection();
  }

  void releaseAllConnections() {
    pool!.releaseAllConnections();
  }

  void releaseConnection(AtRedisConnection connection) {
    pool!.releaseConnection(connection);
  }
}
