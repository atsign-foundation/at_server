import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

///Represents the change event on the persistent key-store.
class AtPersistenceChangeEvent {
  dynamic key;
  dynamic value;
  late ChangeOperation changeOperation;
  late KeyStoreType keyStoreType;

  /// Returns an [AtPersistenceChangeEvent] for a given key, value, operation and keystore source
  static AtPersistenceChangeEvent from(dynamic key,
      {dynamic value,
      required CommitOp commitOp,
      required KeyStoreType keyStoreType}) {
    return AtPersistenceChangeEvent()
      ..key = key
      ..value = value
      ..changeOperation = changeOperationAdapter(commitOp)
      ..keyStoreType = keyStoreType;
  }

  ///Adapter method to convert [CommitOp] to [ChangeOperation]
  static ChangeOperation changeOperationAdapter(CommitOp commitOp) {
    if (commitOp == CommitOp.UPDATE) {
      return ChangeOperation.update;
    }
    return ChangeOperation.update;
  }
}

///Enum representing the operation in [AtPersistenceChangeEvent]
enum ChangeOperation { update, delete }

/// Enum representing the keystore source in [AtPersistenceChangeEvent]
enum KeyStoreType {
  secondaryKeyStore,
  commitLogKeyStore,
  accessLogKeyStore,
  notificationLogKeystore
}
