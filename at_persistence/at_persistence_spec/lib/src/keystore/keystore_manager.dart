import 'package:at_persistence_spec/src/keystore/keystore.dart';

/// Factory class. Responsible for returning instance of a Key store.
abstract class KeystoreManager<K, V> {
  /// Retrieves an instance of underlying keystore.
  ///
  /// @return An instance of the key store.
  Keystore<K, V> getKeyStore();

  /// Returns enum of type StoreType, that represents type of the key store.
  ///
  /// @return An instance of the key store.
  StoreType getStoreType();
}
