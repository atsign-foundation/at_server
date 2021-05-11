import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification.dart';

/// Class to represent to the NotificationManager Spec.
abstract class NotificationManagerSpec {
  /// Notifies the key to another atsign
  Future<String> notify(AtNotification atNotification);

  /// Returns the status of the notificationId.
  Future<NotificationStatus?> getStatus(String notificationId);

  /// Returns if notification can be accepted.
  bool isNotificationAccepted();
}
