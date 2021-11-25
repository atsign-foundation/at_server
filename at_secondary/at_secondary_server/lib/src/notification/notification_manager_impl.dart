import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification_manager.dart';
import 'package:at_secondary/src/notification/queue_manager.dart';

/// Class implementing [NotificationManagerSpec].
class NotificationManager implements NotificationManagerSpec {
  static final NotificationManager _singleton = NotificationManager._internal();

  NotificationManager._internal();

  factory NotificationManager.getInstance() {
    return _singleton;
  }

  @override
  Future<String?> notify(AtNotification atNotification) async {
    if (atNotification.notifier == null || atNotification.notifier!.isEmpty) {
      throw InvalidSyntaxException('Invalid Request Error');
    }

    if (isNotificationAccepted()) {
      var notificationId = await _storeNotificationInQueue(atNotification);
      return notificationId;
    }
    return null;
  }

  ///Stores the AtNotification Object to Queue.
  ///Returns the AtNotification id.
  Future<String?> _storeNotificationInQueue(
      AtNotification atNotification) async {
    // Adding notification to hive key-store.
    await AtNotificationKeystore.getInstance()
        .put(atNotification.id, atNotification);

    // Adding sent notification to queue.
    if (atNotification.type == NotificationType.sent) {
      var queueManager = QueueManager.getInstance();
      queueManager.enqueue(atNotification);
    }
    return atNotification.id;
  }

  @override
  Future<NotificationStatus?> getStatus(String? notificationId) async {
    var notificationKeyStore = AtNotificationKeystore.getInstance();
    var notificationResponse = await notificationKeyStore.get(notificationId);
    if (notificationResponse != null) {
      if (notificationResponse.isExpired()) {
        notificationResponse.notificationStatus = NotificationStatus.expired;
      }
      return notificationResponse.notificationStatus;
    }
    return null;
  }

  @override
  bool isNotificationAccepted() {
    return true;
  }
}
