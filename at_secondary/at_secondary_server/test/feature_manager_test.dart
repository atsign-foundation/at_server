import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/notification/notification_request_manager.dart';
import 'package:test/test.dart';

void main() {
  group('A group of tests to verify notification feature manager', () {
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
          .prepareNotificationReqeust(atNotification)
          .request;
      print(notifyStr);
    });
  });
}
