import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

/// Class for AtNotification callback method implementations
class AtNotificationCallback {
  static final AtNotificationCallback _singleton =
      AtNotificationCallback._internal();

  AtNotificationCallback._internal();

  factory AtNotificationCallback.getInstance() {
    return _singleton;
  }

  @Deprecated('No longer in use. Replaced with notificationCallback')
  var callbackMethods = <NotificationType, List<NotificationFunction>>{};

  Function? notificationCallback;

  /// Method to register callback function
  void registerNotificationCallback(
      NotificationType notificationType, Function callback) {
    notificationCallback = callback;
  }

  /// Method to deregister callback function
  @Deprecated('No longer in use')
  void unregisterNotificationCallback(
      NotificationType notificationType, Function callback) {
    var functions = callbackMethods[notificationType]!;
    for (var nfs in functions) {
      if (nfs.function == callback) {
        nfs.isValid = false;
      }
    }
  }

  /// Method to invoke registered callbacks
  Future<void> invokeCallbacks(AtNotification? atNotification) async {
    try {
      if (atNotification == null) {
        return;
      }
      //Based on notification Entry type get callback function and invoke
      // Introduced self notification type for APKAM enrollment notifications.
      if (atNotification.type == NotificationType.received ||
          atNotification.type == NotificationType.self) {
        if (notificationCallback == null) {
          return;
        }
        notificationCallback!(atNotification);
      }
    } on Exception catch (e) {
      throw InternalServerException(
          'Exception while invoking callbacks:${e.toString()}');
    }
  }
}

@Deprecated('No longer in use')
class NotificationFunction {
  Function? function;
  bool? isValid;
}
