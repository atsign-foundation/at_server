import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_utils/at_logger.dart';
import 'package:at_utils/at_utils.dart';
import 'package:uuid/uuid.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_server_spec/at_server_spec.dart';

/// Util class for Notifications
class NotificationUtil {
  static var logger = AtSignLogger('NotificationUtil');
  static final AUTO_NOTIFY = AtSecondaryConfig.autoNotify;

  /// Method to store notification in data store
  /// Accepts fromAtSign, forAtSign, key, Notification and Operation type,
  /// Inbound connection object as arguments. ttl is optional argument
  static Future<void> storeNotification(
      InboundConnection atConnection,
      String fromAtSign,
      String forAtSign,
      String key,
      NotificationType notificationType,
      OperationType operationType,
      {int ttl_ms,
      String value}) async {
    try {
      if (forAtSign == null) {
        return;
      }
      forAtSign = AtUtils.formatAtSign(forAtSign);
      fromAtSign = AtUtils.formatAtSign(fromAtSign);
      var ttl_ms;
      var notificationDateTime = DateTime.now().toUtc();
      var expiresAt = (ttl_ms != null)
          ? DateTime.fromMillisecondsSinceEpoch(
              notificationDateTime.millisecondsSinceEpoch + ttl_ms)
          : null;
      var _notificationId = Uuid().v4();
      var atNotification = AtNotification(
          _notificationId,
          fromAtSign,
          notificationDateTime,
          forAtSign,
          key,
          notificationType,
          operationType,
          expiresAt);
      if (value != null) {
        atNotification.atValue = value;
      }
      var notificationEntry = NotificationEntry([atNotification], []);
      var notificationKeyStore = AtNotificationKeystore.getInstance();
      await notificationKeyStore.put(forAtSign, notificationEntry);
    } catch (exception) {
      logger.severe(
          'exception while sending notification : ${exception.toString()}');
    }
  }

  /// Method to send notification to other secondary server
  /// Accepts Inbound connection object, forAtSign and key as arguments
  static Future<void> sendNotification(
      String forAtSign, InboundConnection atConnection, String key) async {
    var outBoundClient =
        OutboundClientManager.getInstance().getClient(forAtSign, atConnection);
    // Need not connect again if the client's handshake is already done
    if (!outBoundClient.isHandShakeDone) {
      var connectResult = await outBoundClient.connect();
      logger.finer('connect result: ${connectResult}');
    }
    var notifyResult = await outBoundClient.notify(key, handshake: true);
    logger.finer('NotifyResult : $notifyResult');
  }
}
