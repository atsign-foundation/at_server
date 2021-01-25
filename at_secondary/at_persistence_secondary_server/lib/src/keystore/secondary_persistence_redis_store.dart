import 'package:at_persistence_secondary_server/src/keystore/hive_keystore.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_manager.dart';
import 'package:at_persistence_secondary_server/src/keystore/redis_keystore.dart';
import 'package:at_persistence_secondary_server/src/keystore/redis_manager.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_keystore_manager.dart';

class SecondaryPersistenceRedisStore {
  RedisKeyStore _redisKeystore;
  RedisPersistenceManager _redisPersistenceManager;
  SecondaryKeyStoreManager _secondaryKeyStoreManager;
  String _atSign;

  SecondaryPersistenceRedisStore(String atSign) {
    _atSign = atSign;
    _init();
  }

  RedisKeyStore getSecondaryKeyStore() {
    return this._redisKeystore;
  }

  RedisPersistenceManager getRedisPersistenceManager() {
    return this._redisPersistenceManager;
  }

  SecondaryKeyStoreManager getSecondaryKeyStoreManager() {
    return this._secondaryKeyStoreManager;
  }

  void _init() {
    _redisKeystore = RedisKeyStore(this._atSign);
    _redisPersistenceManager = RedisPersistenceManager(this._atSign);
    _redisKeystore.persistenceManager = _redisPersistenceManager;
    _secondaryKeyStoreManager = SecondaryKeyStoreManager(this._atSign);
    _secondaryKeyStoreManager.keyStore = _redisKeystore;
  }
}
