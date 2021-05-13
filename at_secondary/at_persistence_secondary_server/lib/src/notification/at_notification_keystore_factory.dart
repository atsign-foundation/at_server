import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/commit_log_redis_keystore.dart';
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

  void init(String keyStore, {String storagePath, String boxName, String redisUrl, String password}) {
    if(keyStore == 'redis') {
      _notificationKeystore  = AtNotificationRedisKeystore.getInstance().init(redisUrl, password);
    } else {
      _notificationKeystore  = AtNotificationKeystore.getInstance().init(storagePath, boxName);
    }
  }

  SecondaryKeyStore getNotificationKeyStore() {
    return _notificationKeystore;
  }


}
