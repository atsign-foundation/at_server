import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/redis/redis_keystore.dart';
import 'package:at_persistence_secondary_server/src/keystore/redis/redis_manager.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_keystore_manager.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_persistence_manager.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_persistence_store.dart';

class SecondaryPersistenceRedisStore implements SecondaryPersistenceStore {
  RedisKeystore _redisKeystore;
  RedisPersistenceManager _redisPersistenceManager;
  SecondaryKeyStoreManager _secondaryKeyStoreManager;
  String _atSign;

  SecondaryPersistenceRedisStore(String atSign) {
    _atSign = atSign;
    _init();
  }

  @override
  SecondaryKeyStore getSecondaryKeyStore() {
    return _redisKeystore;
  }

  @override
  PersistenceManager getPersistenceManager() {
    return _redisPersistenceManager;
  }

  @override
  SecondaryKeyStoreManager getSecondaryKeyStoreManager() {
    return _secondaryKeyStoreManager;
  }

  void _init() {
    _redisKeystore = RedisKeystore();
    _redisPersistenceManager = RedisPersistenceManager(_atSign);
    _redisKeystore.persistenceManager = _redisPersistenceManager;
    _secondaryKeyStoreManager = SecondaryKeyStoreManager();
    _secondaryKeyStoreManager.keyStore = _redisKeystore;
  }

  @override
  IndexableKeyStore getIndexKeyStore(String url) {
    return ElasticKeyStore(url);
  }
}
