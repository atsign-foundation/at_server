import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

///Represents the change event on the persistent key-store.
class AtPersistenceChangeEvent {
  dynamic key;
  dynamic value;
  late ChangeOperation changeOperation;
  late KeyStoreType keyStoreType;
  static const server = AtServerAnnotation();

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

/// Represents the list of keys of [CommitEntry].
class CompactionSortedList {
  final _list = [];
  static const server = AtServerAnnotation();

  /// Adds the hive key of [CommitEntry] to the list and sort's the keys in descending order.
  void add(int commitEntryKey) {
    _list.add(commitEntryKey);
    _list.sort((a, b) => b.compareTo(a));
  }

  /// Returns the keys to compact.
  List getKeysToCompact() {
    // _list.sublist(1) to retain the latest key and return the remaining.
    var expiredKeys = _list.sublist(1);
    return expiredKeys;
  }

  /// Removes the compacted keys from the list.
  void deleteCompactedKeys(var expiredKeys) {
    _list.removeWhere((element) => expiredKeys.contains(element));
  }

  /// Returns the size of list.
  int getSize() {
    return _list.length;
  }

  @override
  String toString() {
    return 'CompactionSortedList{_list: $_list}';
  }
}
