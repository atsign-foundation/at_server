import 'package:at_secondary/src/notification/notification_request.dart';

/// The Manager class responsible for returning instance of [NotificationRequest]
/// basing on the secondary server version.
class NotificationRequestManager {
  static final NotificationRequestManager _singleton =
      NotificationRequestManager._internal();

  NotificationRequestManager._internal();

  factory NotificationRequestManager.getInstance() {
    return _singleton;
  }

  /// Accepts the secondary server version and returns the instance
  /// of NotificationRequest.
  /// Defaults to return the oldest version of NotificationRequest
  NotificationRequest getNotificationRequest(String version) {
    switch (version) {
      case '3.0.12':
        return NotificationRequestv1();
      case '3.0.13':
        return NotificationRequestv2();
      default:
        return NotificationRequestv1();
    }
  }
}
