import 'package:at_persistence_secondary_server/src/keystore/hive_manager.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_secondary_keystore.dart';

class SecondaryPersistenceStore {
  late HiveSecondaryKeyStore _hiveKeystore;
  HivePersistenceManager? _hivePersistenceManager;
  String? _atSign;

  SecondaryPersistenceStore(String? atSign) {
    _atSign = atSign;
    _init();
  }

  HiveSecondaryKeyStore? getSecondaryKeyStore() {
    return _hiveKeystore;
  }

  HivePersistenceManager? getHivePersistenceManager() {
    return _hivePersistenceManager;
  }

  void _init() {
    _hiveKeystore = HiveSecondaryKeyStore();
    _hivePersistenceManager = HivePersistenceManager(_atSign);
    _hiveKeystore.persistenceManager = _hivePersistenceManager;
    // Wire the back-reference up-front so HivePersistenceManager.scheduleKeyExpireTask
    // doesn't have to resolve at tick time.
    _hivePersistenceManager!.keyStoreForExpireTask = _hiveKeystore;
  }
}
