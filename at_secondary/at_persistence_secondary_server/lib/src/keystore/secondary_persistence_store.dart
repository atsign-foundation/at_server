import 'package:at_persistence_secondary_server/src/keystore/secondary_keystore_manager.dart';
import 'package:at_persistence_secondary_server/src/keystore/secondary_persistence_manager.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';

abstract class SecondaryPersistenceStore {

  SecondaryKeyStore getSecondaryKeyStore();

  PersistenceManager getPersistenceManager();

  SecondaryKeyStoreManager getSecondaryKeyStoreManager();

}