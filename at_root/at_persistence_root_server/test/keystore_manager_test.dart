import 'package:at_persistence_root_server/src/keystore_manager.dart';
import 'package:at_persistence_root_server/src/redis_keystore.dart';
import 'package:test/test.dart';
import 'package:at_persistence_spec/at_persistence.dart';

void main() {
  group('Keystore manager test', () {
    test('check keystore is redis keystore', () async {
      KeystoreManager manager = KeystoreManagerImpl();
      var keyStore = manager.getKeyStore();
      expect(keyStore is RedisKeystore, true);
    });

    test('check keystore type is root', () async {
      KeystoreManager manager = KeystoreManagerImpl();
      var keyStoreType = manager.getStoreType();
      expect(keyStoreType, StoreType.ROOT);
    });
  });
}
