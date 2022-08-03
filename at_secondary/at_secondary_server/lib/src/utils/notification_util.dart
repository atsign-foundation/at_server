import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/notification/queue_manager.dart';
import 'package:at_utils/at_utils.dart';

/// Util class for Notifications
class NotificationUtil {
  static var logger = AtSignLogger('NotificationUtil');
  //static final autoNotify = AtSecondaryConfig.autoNotify;

  /// Method to store notification in data store
  /// Accepts fromAtSign, forAtSign, key, Notification and Operation type,
  /// Inbound connection object as arguments. ttl is optional argument
  static Future<String?> storeNotification(
      String? fromAtSign,
      String? forAtSign,
      String? key,
      NotificationType notificationType,
      OperationType? operationType,
      {MessageType messageType = MessageType.key,
      int? ttlMillis,
      String? value,
      NotificationStatus? notificationStatus,
      String? id,
      AtMetaData? atMetaData}) async {
    try {
      if (forAtSign == null) {
        return null;
      }
      forAtSign = AtUtils.formatAtSign(forAtSign);
      fromAtSign = AtUtils.formatAtSign(fromAtSign);
      final notificationBuilder = AtNotificationBuilder()
        ..fromAtSign = fromAtSign
        ..toAtSign = forAtSign
        ..notification = key
        ..type = notificationType
        ..opType = operationType
        ..messageType = messageType
        ..atValue = value
        ..notificationStatus = notificationStatus
        ..atMetaData = atMetaData;
      //setting ttl only when it has a valid value
      if (ttlMillis != null && ttlMillis > 0) {
        notificationBuilder.ttl = ttlMillis;
        notificationBuilder.expiresAt =
            DateTime.now().toUtc().add(Duration(milliseconds: ttlMillis));
      }
      if (id != null && id.isNotEmpty) {
        notificationBuilder.id = id;
      }
      var atNotification = notificationBuilder.build();
      var notificationKeyStore = AtNotificationKeystore.getInstance();
      await notificationKeyStore.put(atNotification.id, atNotification);
      return atNotification.id;
    } catch (exception) {
      logger.severe(
          'exception while storing notification : ${exception.toString()}');
    }
    return null;
  }

  /// Load the notification into the map to notify on server start-up.
  static Future<void> loadNotificationMap() async {
    var _notificationLog = AtNotificationKeystore.getInstance();
    if (_notificationLog.isEmpty()) {
      return;
    }
    var values = await _notificationLog.getValues();
    for (var element in values) {
      //_notificationLog.getValues().forEach((element) {
      // If notifications are sent and not delivered, add to notificationQueue.
      if (element.type == NotificationType.sent) {
        QueueManager.getInstance().enqueue(element);
      }
    }
  }
}
