import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_keystore.dart';
import 'package:at_persistence_spec/at_persistence.dart';

class SecondaryKeyStoreManager implements KeystoreManager<String, AtData> {
  static final SecondaryKeyStoreManager _singleton =
      SecondaryKeyStoreManager._internal();

  SecondaryKeyStoreManager._internal();

  factory SecondaryKeyStoreManager.getInstance() {
    return _singleton;
  }

  SecondaryKeyStore _hiveKeystore;

  void init() {
    _hiveKeystore ??= HiveKeystore();
  }

  @override
  SecondaryKeyStore<String, AtData, AtMetaData> getKeyStore() {
    return _hiveKeystore;
  }

  @override
  StoreType getStoreType() {
    return StoreType.SECONDARY;
  }
}
