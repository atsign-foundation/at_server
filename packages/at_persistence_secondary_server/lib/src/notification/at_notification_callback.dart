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

  var callbackMethods = <NotificationType, List<NotificationFunction>>{};

  /// Method to register callback function
  void registerNotificationCallback(
      NotificationType notificationType, Function callback) {
    var nf = NotificationFunction();
    nf.isValid = true;
    nf.function = callback;
    var functions = callbackMethods[notificationType];
    functions ??= <NotificationFunction>[];
    _removeUnregisteredFunctions(functions);
    functions.add(nf);
    callbackMethods[notificationType] = functions;
  }

  /// Method to deregister callback function
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
      // Introduced self notification type for APKAM enrollment notifications.
      if (atNotification.type == NotificationType.received ||
          atNotification.type == NotificationType.self) {
        var callbacks = callbackMethods[atNotification.type!];
        if (callbacks == null || callbacks.isEmpty) {
          //logger.info('No callback registered for received notifications');
          return;
        }
        for (var callback in callbacks) {
          if (callback.isValid!) {
            callback.function!(atNotification);
          }
        }
      }
    } on Exception catch (e) {
      throw InternalServerException(
          'Exception while invoking callbacks:${e.toString()}');
    }
  }

  void _removeUnregisteredFunctions(List<NotificationFunction> nf) {
    nf.removeWhere((element) => element.isValid == false);
  }
}

class NotificationFunction {
  Function? function;
  bool? isValid;
}
