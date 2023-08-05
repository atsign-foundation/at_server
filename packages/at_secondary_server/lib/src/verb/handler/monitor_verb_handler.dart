import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

class MonitorVerbHandler extends AbstractVerbHandler {
  static Monitor monitor = Monitor();

  late InboundConnection atConnection;

  String? regex;

  MonitorVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  Notification notification = Notification.empty();

  @override
  bool accept(String command) => command.startsWith(getName(VerbEnum.monitor));

  @override
  Verb getVerb() {
    return monitor;
  }

  MonitorVerbHandler clone() {
    return MonitorVerbHandler(super.keyStore);
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    if (atConnection.getMetaData().isAuthenticated) {
      this.atConnection = atConnection;
      regex = verbParams[AT_REGEX];
      final selfNotificationsFlag = verbParams[MONITOR_SELF_NOTIFICATIONS];

      var atNotificationCallback = AtNotificationCallback.getInstance();

      atNotificationCallback.registerNotificationCallback(
          NotificationType.received, processAtNotification);
      if (selfNotificationsFlag == MONITOR_SELF_NOTIFICATIONS) {
        logger.finer('self notification callback registered');
        atNotificationCallback.registerNotificationCallback(
            NotificationType.self, processAtNotification);
      }

      if (verbParams.containsKey(EPOCH_MILLIS) &&
          verbParams[EPOCH_MILLIS] != null) {
        // Send notifications that are already received after EPOCH_MILLIS first
        var fromEpochMillis = int.parse(verbParams[EPOCH_MILLIS]!);
        List<NotificationType> notificationTypesToFetch = [
          NotificationType.received
        ];
        if (verbParams[MONITOR_SELF_NOTIFICATIONS] != null) {
          notificationTypesToFetch.add(NotificationType.self);
        }
        List notificationsList = await AtNotificationKeystore.getInstance()
            .getNotificationsAfterTimestamp(
                fromEpochMillis, notificationTypesToFetch);
        for (var atNotification in notificationsList) {
          processAtNotification(atNotification);
        }
      }
    }
    atConnection.isMonitor = true;
  }

  /// Writes [notification] to connection if the [notification] matches [monitor]'s [regex]
  void processReceivedNotification(Notification notification) {
    var key = notification.notification;
    var fromAtSign = notification.fromAtSign;
    if (fromAtSign != null) {
      fromAtSign = fromAtSign.replaceAll('@', '');
    }

    // If monitor verb contains a regular expression,
    // push only if the notification matches regex
    if (regex != null) {
      logger.finer('regex is not null:$regex');
      logger.finer('key: $key');
      try {
        // if key matches the regular expression, push notification.
        // else if fromAtSign matches the regular expression, push notification.
        if (key!.contains(RegExp(regex!))) {
          logger.finer('key matches regex');
          atConnection
              .write('notification: ${jsonEncode(notification.toJson())}\n');
        } else if (fromAtSign != null && fromAtSign.contains(RegExp(regex!))) {
          logger.finer('fromAtSign matches regex');
          atConnection
              .write('notification: ${jsonEncode(notification.toJson())}\n');
        } else {
          logger.finer('no regex match');
        }
      } on FormatException {
        logger.severe('Invalid regular expression : $regex');
        throw InvalidSyntaxException('Invalid regular expression syntax');
      }
    } else {
      atConnection
          .write('notification: ${jsonEncode(notification.toJson())}\n');
    }
  }

  void processAtNotification(AtNotification atNotification) {
    // If connection is invalid, deregister the notification
    if (atConnection.isInValid()) {
      var atNotificationCallback = AtNotificationCallback.getInstance();
      atNotificationCallback.unregisterNotificationCallback(
          NotificationType.received, processAtNotification);
    } else {
      notification
        ..id = atNotification.id
        ..fromAtSign = atNotification.fromAtSign
        ..dateTime = atNotification.notificationDateTime!.millisecondsSinceEpoch
        ..toAtSign = atNotification.toAtSign
        ..notification = atNotification.notification
        ..operation =
            atNotification.opType.toString().replaceAll('OperationType.', '')
        ..value = atNotification.atValue
        ..messageType = atNotification.messageType!.toString()
        ..isTextMessageEncrypted =
            atNotification.atMetadata?.isEncrypted != null
                ? atNotification.atMetadata!.isEncrypted!
                : false
        ..metadata = {
          "encKeyName": atNotification.atMetadata?.encKeyName,
          "encAlgo": atNotification.atMetadata?.encAlgo,
          "ivNonce": atNotification.atMetadata?.ivNonce,
          "skeEncKeyName": atNotification.atMetadata?.skeEncKeyName,
          "skeEncAlgo": atNotification.atMetadata?.skeEncAlgo,
        };
      processReceivedNotification(notification);
    }
  }

  /// Returns received notifications of the current atsign
  /// @param responseList : List to add the notifications
  /// @param Future<List> : Returns a list of received notifications of the current atsign.
  Future<List<Notification>> _getNotificationsAfterEpoch(
      int millisecondsEpoch, bool isSelfNotificationsEnabled) async {
    // Get all notifications
    var allNotifications = <Notification>[];
    var notificationKeyStore = AtNotificationKeystore.getInstance();
    var keyList = await notificationKeyStore.getValues();
    await Future.forEach(
        keyList,
        (element) => _fetchNotificationEntry(element, allNotifications,
            notificationKeyStore, isSelfNotificationsEnabled));

    // Filter previous notifications than millisecondsEpoch
    var responseList = <Notification>[];
    for (var notification in allNotifications) {
      if (notification.dateTime! > millisecondsEpoch) {
        responseList.add(notification);
      }
    }
    return responseList;
  }

  /// Fetches a notification from the notificationKeyStore and adds it to responseList
  void _fetchNotificationEntry(
      dynamic element,
      List<Notification> responseList,
      AtNotificationKeystore notificationKeyStore,
      bool isSelfNotificationsEnabled) async {
    var notificationEntry = await notificationKeyStore.get(element.id);
    if (notificationEntry != null &&
        (notificationEntry.type == NotificationType.received ||
            (isSelfNotificationsEnabled &&
                notificationEntry.type == NotificationType.self)) &&
        !notificationEntry.isExpired()) {
      responseList.add(Notification(element));
    }
  }
}

///Notification class to represent JSON format.
class Notification {
  String? id;
  String? fromAtSign;
  int? dateTime;
  String? toAtSign;
  String? notification;
  String? operation;
  String? value;
  late String messageType;
  late bool isTextMessageEncrypted = false;
  Map? metadata;

  Notification.empty();

  Notification(AtNotification atNotification) {
    id = atNotification.id;
    fromAtSign = atNotification.fromAtSign;
    dateTime = atNotification.notificationDateTime!.millisecondsSinceEpoch;
    toAtSign = atNotification.toAtSign;
    notification = atNotification.notification;
    operation =
        atNotification.opType.toString().replaceAll('OperationType.', '');
    value = atNotification.atValue;
    messageType = atNotification.messageType!.toString();
    isTextMessageEncrypted = atNotification.atMetadata?.isEncrypted != null
        ? atNotification.atMetadata!.isEncrypted!
        : false;
    metadata = {
      "encKeyName": atNotification.atMetadata?.encKeyName,
      "encAlgo": atNotification.atMetadata?.encAlgo,
      "ivNonce": atNotification.atMetadata?.ivNonce,
      "skeEncKeyName": atNotification.atMetadata?.skeEncKeyName,
      "skeEncAlgo": atNotification.atMetadata?.skeEncAlgo,
    };
  }

  Map toJson() => {
        ID: id,
        FROM: fromAtSign,
        TO: toAtSign,
        KEY: notification,
        VALUE: value,
        OPERATION: operation,
        EPOCH_MILLIS: dateTime,
        MESSAGE_TYPE: messageType,
        IS_ENCRYPTED: isTextMessageEncrypted,
        "metadata": metadata
      };

  @override
  String toString() {
    return toJson().toString();
  }
}
