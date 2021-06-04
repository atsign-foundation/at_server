import 'package:at_persistence_secondary_server/src/keystore/secondary_persistence_store.dart';
import 'package:at_utils/at_logger.dart';

class SecondaryPersistenceStoreFactory {
  static final SecondaryPersistenceStoreFactory _singleton =
      SecondaryPersistenceStoreFactory._internal();

  SecondaryPersistenceStoreFactory._internal();

  factory SecondaryPersistenceStoreFactory.getInstance() {
    return _singleton;
  }

  final logger = AtSignLogger('SecondaryPersistenceStoreFactory');

  final Map<String?, SecondaryPersistenceStore> _secondaryPersistenceStoreMap = {};

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