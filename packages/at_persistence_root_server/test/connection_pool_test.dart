import 'package:at_persistence_root_server/src/redis_connection.dart';
import 'package:at_persistence_root_server/src/redis_connection_pool.dart';
import 'package:test/test.dart';

void main() {
  group('Connection pool test', () {
    test('connection pool default pool size', () async {
      var config = AtRedisConfig();
      var mockConnPool = MockRedisConnectionPool();
      await mockConnPool.init(config);
      expect(mockConnPool.getPooledSize(), 5);
    });

    test('connection pool default used size', () async {
      var config = AtRedisConfig();
      var mockConnPool = MockRedisConnectionPool();
      await mockConnPool.init(config);
      expect(mockConnPool.getUsedSize(), 0);
    });

    test('connection pool test total size', () async {
      var config = AtRedisConfig();
      var mockConnPool = MockRedisConnectionPool();
      await mockConnPool.init(config);
      await mockConnPool.getConnection();
      await mockConnPool.getConnection();
      expect(mockConnPool.getSize(), 5);
    });

    test('connection pool test connection', () async {
      var config = AtRedisConfig();
      var mockConnPool = MockRedisConnectionPool();
      await mockConnPool.init(config);
      var atRedisConnection = await mockConnPool.getConnection();
      expect(atRedisConnection, isNotNull);
    });

    test('connection pool test used size', () async {
      var config = AtRedisConfig();
      var mockConnPool = MockRedisConnectionPool();
      await mockConnPool.init(config);
      await mockConnPool.getConnection();
      await mockConnPool.getConnection();
      expect(mockConnPool.getUsedSize(), 2);
      expect(mockConnPool.getPooledSize(), 3);
    });

    test('connection pool test release connection', () async {
      var config = AtRedisConfig();
      var mockConnPool = MockRedisConnectionPool();
      await mockConnPool.init(config);
      await mockConnPool.getConnection();
      var atRedisConnection_2 = await mockConnPool.getConnection();
      mockConnPool.releaseConnection(atRedisConnection_2);
      expect(mockConnPool.getUsedSize(), 1);
      expect(mockConnPool.getPooledSize(), 4);
    });

    test('connection pool test additional connections', () async {
      var config = AtRedisConfig();
      var mockConnPool = MockRedisConnectionPool();
      await mockConnPool.init(config);
      await mockConnPool.getConnection();
      await mockConnPool.getConnection();
      await mockConnPool.getConnection();
      await mockConnPool.getConnection();
      await mockConnPool.getConnection();
      var atRedisConnection_6 = await mockConnPool.getConnection();
      expect(atRedisConnection_6, isNotNull);
      expect(mockConnPool.getPooledSize(), 0);
      expect(mockConnPool.getUsedSize(), 6);
    });
  });
}

class MockRedisConnectionPool extends RedisConnectionPool {
  @override
  Future<AtRedisConnection> create(AtRedisConfig atRedisConfig) async {
    return AtRedisConnection();
  }
}

//class MockRedisConnectionPool extends Mock implements RedisConnectionPool {
//
//}
