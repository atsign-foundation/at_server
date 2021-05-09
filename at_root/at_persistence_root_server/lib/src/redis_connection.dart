import 'package:redis/redis.dart';

class AtRedisConnection {
  RedisConnection connection;
  Command command;

  Future<void> close() async {
    return await connection?.close();
  }
}

class AtRedisConfig {
  String host;
  int port;
  String auth;
}
