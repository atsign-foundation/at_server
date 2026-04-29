import 'package:at_persistence_secondary_server/src/keystore/secondary_persistence_store.dart';

/// Per-atSign cache around [SecondaryPersistenceStore]. Construct
/// directly; callers that want process-wide lifecycle of the
/// underlying stores should use [HiveAtPersistenceFactory] instead.
class SecondaryPersistenceStoreFactory {
  SecondaryPersistenceStoreFactory();

  final Map<String?, SecondaryPersistenceStore> _secondaryPersistenceStoreMap =
      {};

  SecondaryPersistenceStore? getSecondaryPersistenceStore(String? atSign) {
    if (!_secondaryPersistenceStoreMap.containsKey(atSign)) {
      var secondaryPersistenceStore = SecondaryPersistenceStore(atSign);
      _secondaryPersistenceStoreMap[atSign] = secondaryPersistenceStore;
    }
    return _secondaryPersistenceStoreMap[atSign];
  }

  Future<void> close() async {
    await Future.forEach(
        _secondaryPersistenceStoreMap.values,
        (SecondaryPersistenceStore secondaryPersistenceStore) =>
            secondaryPersistenceStore.getHivePersistenceManager()?.close());
    _secondaryPersistenceStoreMap.clear();
  }
}
