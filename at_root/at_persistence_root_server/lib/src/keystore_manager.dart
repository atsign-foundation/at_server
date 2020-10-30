import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_persistence_root_server/src/redis_keystore.dart';

class KeystoreManagerImpl implements KeystoreManager<String, String> {
  RedisKeystore _redisKeystore;

  KeystoreManagerImpl() {
    _redisKeystore = RedisKeystore();
  }

  @override
  Keystore<String, String> getKeyStore() {
    return _redisKeystore;
  }

  @override
  StoreType getStoreType() {
    return StoreType.ROOT;
  }
}
