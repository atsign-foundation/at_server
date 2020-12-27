import 'package:at_persistence_secondary_server/src/notification/at_notification_entry.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification.dart';
import 'package:at_commons/at_commons.dart';
import 'package:hive/hive.dart';
import 'package:at_utils/at_logger.dart';

/// Class to store Notifications (Both sent and received)
/// Invoke callback functions if any for received notifications
class AtNotificationLog {
  static final AtNotificationLog _singleton = AtNotificationLog._internal();

  AtNotificationLog._internal();

  var logger = AtSignLogger('AtNotificationLog');

  Box _box;

  bool _registerAdapters = false;

  int maxEntries;

  var callbackMethods = <NotificationType, List<NotificationFunction>>{};

  Box get box => _box;

  factory AtNotificationLog.getInstance() {
    return _singleton;
  }

  /// Initializes access log hive box inside [storagePath].
  /// Register [NotificationEntryAdapter, AtNotificationAdapter, NotificationTypeAdapter]
  void init(String boxName, String storagePath, int maxNotifications) async {
    Hive.init(storagePath);
    if (!_registerAdapters) {
      Hive.registerAdapter(NotificationEntryAdapter());
      Hive.registerAdapter(AtNotificationAdapter());
      Hive.registerAdapter(NotificationTypeAdapter());
      Hive.registerAdapter(OperationTypeAdapter());
      _registerAdapters = true;
    }
    maxEntries = maxNotifications;
    _box = await Hive.openBox<NotificationEntry>(boxName,
        compactionStrategy: (entries, deletedEntries) {
      return deletedEntries > 1;
    });
  }

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
    var functions = callbackMethods[notificationType];
    functions.forEach((nfs) {
      if (nfs.function == callback) {
        nfs.isValid = false;
      }
    });
  }

  /// Method to invoke registered callbacks
  void invokeCallbacks(NotificationEntry notificationEntry) async {
    try {
      var atNotification;
      atNotification = (notificationEntry.sentNotifications.isNotEmpty)
          ? notificationEntry.sentNotifications[0]
          : notificationEntry.receivedNotifications[0];
      //Based on notification Entry type get callback function and invoke
      if (atNotification.type == NotificationType.received) {
        var callbacks = callbackMethods[atNotification.type];
        if (callbacks == null || callbacks.isEmpty) {
          logger.info('No callback registered for received notifications');
          return;
        }
        callbacks.forEach((callback) {
          if (callback.isValid) {
            callback.function(atNotification);
          }
        });
      }
    } on Exception catch (e) {
      throw InternalServerException(
          'Exception while invoking callbacks:${e.toString()}');
    }
  }

  List<dynamic> getNotificationKeys() {
    return _box.keys.toList();
  }

  /// Method to update sentNotifications and receivedNotifications list
  NotificationEntry prepareNotificationEntry(
      NotificationEntry existingData, NotificationEntry newData) {
    var result =
        (existingData == null) ? NotificationEntry([], []) : existingData;

    var atNotification;
    atNotification = (newData.sentNotifications.isNotEmpty)
        ? newData.sentNotifications[0]
        : newData.receivedNotifications[0];
    (atNotification.type == NotificationType.sent)
        ? result.sentNotifications.add(atNotification)
        : result.receivedNotifications.add(atNotification);

    return result;
  }

  void close() {
    box.close();
  }
}

void _removeUnregisteredFunctions(List<NotificationFunction> nf) {
  nf.removeWhere((element) => element.isValid == false);
}

class NotificationFunction {
  Function function;
  bool isValid;
}
