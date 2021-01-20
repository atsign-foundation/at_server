import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

import 'package:at_persistence_spec/at_persistence_spec.dart';

class SecondaryKeyStoreManager implements KeystoreManager<String, AtData> {
  String _atSign;

  SecondaryKeyStore _keyStore;

  SecondaryKeyStoreManager(this._atSign);

  set keyStore(SecondaryKeyStore value) {
    _keyStore = value;
  }

  @override
  SecondaryKeyStore<String, AtData, AtMetaData> getKeyStore() {
    return _keyStore;
  }

  @override
  StoreType getStoreType() {
    return StoreType.SECONDARY;
  }
}
