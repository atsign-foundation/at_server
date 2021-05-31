import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive/hive_keystore.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive/hive_manager.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_keystore_manager.dart';
import 'package:at_persistence_secondary_server/src/keystore/elastic_keystore.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_persistence_manager.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';

class SecondaryPersistenceStore {
  HiveKeystore _hiveKeystore;
  HivePersistenceManager _hivePersistenceManager;
  SecondaryKeyStoreManager _secondaryKeyStoreManager;
  String _atSign;

  SecondaryPersistenceStore(String atSign) {
    _atSign = atSign;
    _init();
  }

  SecondaryKeyStore getSecondaryKeyStore() {
    return _hiveKeystore;
  }

  PersistenceManager getPersistenceManager() {
    return _hivePersistenceManager;
  }

  IndexableKeyStore getIndexKeyStore(String url) {
    return ElasticKeyStore(url);
  }

  SecondaryKeyStoreManager getSecondaryKeyStoreManager() {
    return _secondaryKeyStoreManager;
  }

  void _init() {
    _hiveKeystore = HiveKeystore();
    _hivePersistenceManager = HivePersistenceManager(_atSign);
    _hiveKeystore.persistenceManager = _hivePersistenceManager;
    _secondaryKeyStoreManager = SecondaryKeyStoreManager();
    _secondaryKeyStoreManager.keyStore = _hiveKeystore;
  }
}
