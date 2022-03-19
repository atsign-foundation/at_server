import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/notification/notification_request_manager.dart';
import 'package:test/test.dart';

void main() {
  group('A group of tests to verify notification feature manager', () {
    // The notification request with 3.0.12 will not have notification id
    // in the notify syntax.
    test('A test to verify notification request with 3.0.12 version', () {
      var atNotification = (AtNotificationBuilder()
            ..id = '124'
            ..fromAtSign = '@alice'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = '@bob'
            ..notification = 'phone')
          .build();
      var notificationRequest = NotificationRequestManager.getInstance()
          .getNotificationRequest('3.0.12');
      var notifyStr = notificationRequest
          .getRequest(atNotification)
          .request;
      expect(notifyStr, 'messageType:key:notifier:system:ttln:86400000:phone');
    });

    // The notification request with 3.0.13 will have notification id
    // in the notify syntax.
    test('A test to verify notification request with 3.0.13 version', () {
      var atNotification = (AtNotificationBuilder()
            ..id = '124'
            ..fromAtSign = '@alice'
            ..notificationDateTime = DateTime.now()
            ..toAtSign = '@bob'
            ..notification = 'phone'
            ..atMetaData = (AtMetaData()
              ..sharedKeyEnc = '1234'
              ..pubKeyCS = 'abcd'))
          .build();
      var notificationRequest = NotificationRequestManager.getInstance()
          .getNotificationRequest('3.0.13');
      var notifyStr = notificationRequest
          .getRequest(atNotification)
          .request;
      expect(notifyStr,
          'id:124:messageType:key:notifier:system:ttln:86400000:sharedKeyEnc:1234:pubKeyCS:abcd:phone');
    });
  });
}
