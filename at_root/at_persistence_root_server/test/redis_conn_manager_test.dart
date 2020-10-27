import 'package:at_persistence_root_server/src/keystore_manager.dart';
import 'package:at_persistence_root_server/src/redis_connection_manager.dart';
import 'package:at_persistence_spec/at_persistence.dart';
import 'package:test/test.dart';

void main() {
  group('Redis connection manager test', () {
    test('check connection manager is singleton', () async {
      var manager_1 = RedisConnectionManager.getInstance();
      var manager_2 = RedisConnectionManager.getInstance();
      expect(manager_1 == manager_2, true);
    });

    test('check keystore type is root', () async {
      KeystoreManager manager = KeystoreManagerImpl();
      var keyStoreType = manager.getStoreType();
      expect(keyStoreType, StoreType.ROOT);
    });
  });
}
