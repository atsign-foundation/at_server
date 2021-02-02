import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_keystore.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_manager.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_keystore_manager.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_persistence_manager.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_persistence_store.dart';

class SecondaryPersistenceHiveStore implements SecondaryPersistenceStore {
  HiveKeystore _hiveKeystore;
  HivePersistenceManager _hivePersistenceManager;
  SecondaryKeyStoreManager _secondaryKeyStoreManager;
  String _atSign;

  SecondaryPersistenceHiveStore(String atSign) {
    _atSign = atSign;
    _init();
  }

  SecondaryKeyStore getSecondaryKeyStore() {
    return this._hiveKeystore;
  }

  PersistenceManager getPersistenceManager() {
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
