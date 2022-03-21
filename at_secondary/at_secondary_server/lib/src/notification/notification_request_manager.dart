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
    // If version is equal or greater than 3.0.13, return IdBased NotificationReqeust.
    if (version.compareTo('3.0.13') == 1 || version.compareTo('3.0.13') == 0) {
      return IdBasedRequest();
    }
    // If version is equal or greater than 3.0.12, return NonIdBased NotificationReqeust.
    if (version.compareTo('3.0.12') == 0) {
      return NonIdBasedRequest();
    }
    // By default, return NonIdBased NotificationReqeust.
    return NonIdBasedRequest();
  }
}
