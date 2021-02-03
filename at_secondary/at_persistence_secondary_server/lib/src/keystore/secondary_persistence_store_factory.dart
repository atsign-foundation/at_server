import 'package:at_persistence_secondary_server/src/conf/at_persistence_secondary_config.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive/secondary_persistence_hive_store.dart';
import 'package:at_persistence_secondary_server/src/keystore/redis/secondary_persistence_redis_store.dart';
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
      if (AtPersistenceSecondaryConfig.keyStore == 'redis') {
        var secondaryPersistenceStore = SecondaryPersistenceRedisStore(atSign);
        _secondaryPersistenceStoreMap[atSign] = secondaryPersistenceStore;
      } else {
        var secondaryPersistenceStore = SecondaryPersistenceHiveStore(atSign);
        _secondaryPersistenceStoreMap[atSign] = secondaryPersistenceStore;
      }
    }
    return _secondaryPersistenceStoreMap[atSign];
  }

  void close() {
    _secondaryPersistenceStoreMap.forEach((key, value) {
      value.getPersistenceManager().close();
    });
  }
}
