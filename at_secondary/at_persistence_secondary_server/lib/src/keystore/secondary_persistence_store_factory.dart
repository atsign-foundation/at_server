import 'package:at_persistence_secondary_server/src/keystore/secondary_persistence_store.dart';
import 'package:at_utils/at_logger.dart';

class SecondaryPersistenceStoreFactory {
  static final SecondaryPersistenceStoreFactory _singleton =
      SecondaryPersistenceStoreFactory._internal();

  final bool _debug = false;

  SecondaryPersistenceStoreFactory._internal();

  factory SecondaryPersistenceStoreFactory.getInstance() {
    return _singleton;
  }

  final logger = AtSignLogger('SecondaryPersistenceStoreFactory');

  Map<String, SecondaryPersistenceStore> _secondaryPersistenceStoreMap = {};

  SecondaryPersistenceStore getSecondaryPersistenceStore(String atSign) {
    if (!_secondaryPersistenceStoreMap.containsKey(atSign)) {
      var secondaryPersistenceStore = SecondaryPersistenceStore(atSign);
      _secondaryPersistenceStoreMap[atSign] = secondaryPersistenceStore;
    }
    return _secondaryPersistenceStoreMap[atSign];
  }

  void close() {
    _secondaryPersistenceStoreMap.forEach((key, value) {
      value.getHivePersistenceManager().close();
    });
  }
}
