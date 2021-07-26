import 'package:at_persistence_secondary_server/src/keystore/hive_keystore.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_manager.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_keystore_manager.dart';

class SecondaryPersistenceStore {
  late HiveKeystore _hiveKeystore;
  HivePersistenceManager? _hivePersistenceManager;
  SecondaryKeyStoreManager? _secondaryKeyStoreManager;
  String? _atSign;

  SecondaryPersistenceStore(String? atSign) {
    _atSign = atSign;
    _init();
  }

  HiveKeystore? getSecondaryKeyStore() {
    return _hiveKeystore;
  }

  HivePersistenceManager? getHivePersistenceManager() {
    return _hivePersistenceManager;
  }

  SecondaryKeyStoreManager? getSecondaryKeyStoreManager() {
    return _secondaryKeyStoreManager;
  }

  void _init() {
    _hiveKeystore = HiveKeystore();
    _hivePersistenceManager = HivePersistenceManager(_atSign);
    _hiveKeystore.persistenceManager = _hivePersistenceManager;
    _secondaryKeyStoreManager = SecondaryKeyStoreManager();
    _secondaryKeyStoreManager!.keyStore = _hiveKeystore;
  }
}
