import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

abstract class NotificationRequest {
  late String request;

  NotificationRequest prepareNotificationReqeust(AtNotification atNotification);
}

class NotificationRequestv1 implements NotificationRequest {
  @override
  late String request;

  @override
  NotificationRequest prepareNotificationReqeust(
      AtNotification atNotification) {
    var notification = NotificationRequestv1();

    notification.request = '${atNotification.notification}';
    var atMetaData = atNotification.atMetadata;
    if (atMetaData != null) {
      if (atMetaData.ttr != null) {
        notification.request =
        'ttr:${atMetaData.ttr}:ccd:${atMetaData.isCascade}:${notification.request}:${atNotification.atValue}';
      }
      if (atMetaData.ttb != null) {
        notification.request = 'ttb:${atMetaData.ttb}:${notification.request}';
      }
      if (atMetaData.ttl != null) {
        notification.request = 'ttl:${atMetaData.ttl}:${notification.request}';
      }
    }
    if (atNotification.ttl != null) {
      notification.request =
      'ttln:${atNotification.ttl}:${notification.request}';
    }
    notification.request =
    'notifier:${atNotification.notifier}:${notification.request}';
    notification.request =
    'messageType:${atNotification.messageType.toString().split('.').last}:${notification.request}';
    if (atNotification.opType != null) {
      notification.request =
      '${atNotification.opType.toString().split('.').last}:${notification.request}';
    }
    return notification;
  }
}

class NotificationRequestv2 extends NotificationRequestv1 {
  @override
  NotificationRequest prepareNotificationReqeust(
      AtNotification atNotification) {
    var notification = super.prepareNotificationReqeust(atNotification);
    notification.request = 'id:${atNotification.id}:${notification.request}';
    return notification;
  }
}
