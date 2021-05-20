import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification_redis_keystore.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_utils/at_logger.dart';

class AtNotificationKeyStoreFactory {
  static final AtNotificationKeyStoreFactory _singleton =
      AtNotificationKeyStoreFactory._internal();

  AtNotificationKeyStoreFactory._internal();

  factory AtNotificationKeyStoreFactory.getInstance() {
    return _singleton;
  }

  var logger = AtSignLogger('AtNotificationKeyStoreFactory');

  var _notificationKeystore;

  Future<void> init(String keyStore,
      {String storagePath,
      String boxName,
      String redisUrl,
      String password}) async {
    switch (keyStore.toLowerCase()) {
      case 'redis':
        await AtNotificationRedisKeystore.getInstance()
            .init(redisUrl, password);
        _notificationKeystore = AtNotificationRedisKeystore.getInstance();
        break;

      case 'hive':
        await AtNotificationKeystore.getInstance().init(storagePath, boxName);
        _notificationKeystore = AtNotificationKeystore.getInstance();
        break;
    }
  }

  SecondaryKeyStore getNotificationKeyStore() {
    return _notificationKeystore;
  }
}
