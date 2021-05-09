import 'package:at_persistence_root_server/at_persistence_root_server.dart';
import 'package:at_persistence_root_server/src/redis_connection_manager.dart';

//this can be part of test harness
Future<void> main() async {
  var connectionManager = RedisConnectionManager.getInstance();
  var result = await connectionManager.init('localhost', 6379, 'auth_123');
  print(result);
  var usedSize = RedisConnectionManager.getInstance().pool!.getUsedSize();
  var pooledSize = RedisConnectionManager.getInstance().pool!.getPooledSize();

  print('used connection ${connectionManager.pool!.getUsedSize()} ');
  print('pooled connection ${connectionManager.pool!.getPooledSize()}');
  assert(usedSize == 0);
  assert(pooledSize == 5);
  print('***');

  var usedConnection = [];
  for (var i = 0; i < 3; i++) {
    var curConn = await connectionManager.getConnection();
    usedConnection.add(curConn);
  }
  usedSize = RedisConnectionManager.getInstance().pool!.getUsedSize();
  pooledSize = RedisConnectionManager.getInstance().pool!.getPooledSize();
  print('used connection ${usedSize} ');
  print('pooled connection ${pooledSize}');
  assert(usedSize == 3);
  assert(pooledSize == 2);
  print('***');

  usedConnection.forEach(
      (c) => RedisConnectionManager.getInstance().releaseConnection(c));
  usedSize = RedisConnectionManager.getInstance().pool!.getUsedSize();
  pooledSize = RedisConnectionManager.getInstance().pool!.getPooledSize();
  print('used connection ${usedSize} ');
  print('pooled connection ${pooledSize}');
  assert(usedSize == 0);
  assert(pooledSize == 5);
  print('***');

  var redisKS = RedisKeystore();
  var value = await redisKS.get('ping');
  assert('pong' == value);

  RedisConnectionManager.getInstance().pool!.releaseAllConnections();
  usedSize = RedisConnectionManager.getInstance().pool!.getUsedSize();
  pooledSize = RedisConnectionManager.getInstance().pool!.getPooledSize();
  print('used connection ${usedSize} ');
  print('pooled connection ${pooledSize}');
  assert(usedSize == 0);
  assert(pooledSize == 0);
}
