import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/redis/redis_keystore.dart';
import 'package:at_persistence_secondary_server/src/keystore/redis/redis_manager.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_keystore_manager.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_persistence_manager.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_persistence_store.dart';

class SecondaryPersistenceRedisStore implements SecondaryPersistenceStore {
  RedisKeyStore _redisKeystore;
  RedisPersistenceManager _redisPersistenceManager;
  SecondaryKeyStoreManager _secondaryKeyStoreManager;
  String _atSign;

  SecondaryPersistenceRedisStore(String atSign) {
    _atSign = atSign;
    _init();
  }

  SecondaryKeyStore getSecondaryKeyStore() {
    return this._redisKeystore;
  }

  PersistenceManager getPersistenceManager() {
    return this._redisPersistenceManager;
  }

  SecondaryKeyStoreManager getSecondaryKeyStoreManager() {
    return this._secondaryKeyStoreManager;
  }

  void _init() {
    _redisKeystore = RedisKeyStore(this._atSign);
    _redisPersistenceManager = RedisPersistenceManager(this._atSign);
    _redisKeystore.persistenceManager = _redisPersistenceManager;
    _secondaryKeyStoreManager = SecondaryKeyStoreManager();
    _secondaryKeyStoreManager.keyStore = _redisKeystore;
  }

  @override
  HivePersistenceManager getHivePersistenceManager() {
    // TODO: implement getHivePersistenceManager
    throw UnimplementedError();
  }

  @override
  IndexableKeyStore getIndexKeyStore(String url) {
    return ElasticKeyStore(url);
  }

}
