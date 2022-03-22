import 'package:at_commons/at_commons.dart';
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

  /// Accepts the feature name and returns the appropriate instance of [NotificationRequest].
  /// Defaults to return the oldest version of NotificationRequest - NotifyWithoutId
  NotificationRequest getNotificationRequestByFeature(
      {String feature = notifyWithoutId}) {
    if (feature.toLowerCase() == notifyWithId.toLowerCase()) {
      return IdRequest();
    }
    return NonIdRequest();
  }
}
