import 'package:at_persistence_secondary_server/src/keystore/hive_keystore.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_manager.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_keystore_manager.dart';

class SecondaryPersistenceStore {
  HiveKeystore _hiveKeystore;
  HivePersistenceManager _hivePersistenceManager;
  SecondaryKeyStoreManager _secondaryKeyStoreManager;
  String _atSign;

  SecondaryPersistenceStore(String atSign) {
    _atSign = atSign;
    _init();
  }

  HiveKeystore getSecondaryKeyStore() {
    return this._hiveKeystore;
  }

  HivePersistenceManager getHivePersistenceManager() {
    return this._hivePersistenceManager;
  }

  SecondaryKeyStoreManager getSecondaryKeyStoreManager() {
    return this._secondaryKeyStoreManager;
  }

  void _init() {
    _hiveKeystore = HiveKeystore(this._atSign);
    _hivePersistenceManager = HivePersistenceManager(this._atSign);
    _hiveKeystore.persistenceManager = _hivePersistenceManager;
    _secondaryKeyStoreManager = SecondaryKeyStoreManager(this._atSign);
    _secondaryKeyStoreManager.keyStore = _hiveKeystore;
  }
}
