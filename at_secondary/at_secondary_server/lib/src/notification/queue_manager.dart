import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/notification/at_notification_map.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';

class QueueManager {
  static final QueueManager _singleton = QueueManager._internal();

  QueueManager._internal();

  factory QueueManager.getInstance() {
    return _singleton;
  }

  var noOfRetries = AtSecondaryConfig.maxNotificationRetries;

  /// 1. Called by notification manager to queue the notifications.
  /// 2. Makes use of persistent priority queue to queue the notifications
  void enqueue(AtNotification atNotification) {
    if (atNotification.notificationStatus == NotificationStatus.errored &&
        atNotification.retryCount < noOfRetries!) {
      atNotification.retryCount = atNotification.retryCount + 1;
      if (atNotification.priority!.index > 1) {
        var index = atNotification.priority!.index;
        atNotification.priority = NotificationPriority.values[--index];
      }
      atNotification.notificationStatus = NotificationStatus.queued;
    }
    if (atNotification.notificationStatus == NotificationStatus.queued) {
      AtNotificationMap.getInstance().add(atNotification);
    }
  }

  /// Returns an Iterator of AtNotifications.
  Iterator<AtNotification> dequeue(String? atsign) {
    var mapInstance = AtNotificationMap.getInstance();
    return mapInstance.remove(atsign);
  }

  int numQueued(String atSign) {
    return AtNotificationMap.getInstance().numQueued(atSign);
  }
}
