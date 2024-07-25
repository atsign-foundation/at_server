import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

class MonitorVerbHandler extends AbstractVerbHandler {
  static Monitor monitor = Monitor();

  late InboundConnection atConnection;

  late String regex;

  MonitorVerbHandler(super.keyStore);

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
    if (!atConnection.metaData.isAuthenticated) {
      throw UnAuthenticatedException(
          'Failed to execute verb. monitor requires authentication');
    }
    this.atConnection = atConnection;
    // If regex is not provided by user, set regex to ".*" to match all the possibilities
    // else set regex to the value given by the user.
    (verbParams[AtConstants.regex] == null)
        ? regex = '.*'
        : regex = verbParams[AtConstants.regex]!;
    final selfNotificationsFlag =
        verbParams[AtConstants.monitorSelfNotifications];
    AtNotificationCallback.getInstance().registerNotificationCallback(
        NotificationType.received, processAtNotification);
    if (selfNotificationsFlag == AtConstants.monitorSelfNotifications) {
      logger.finer('self notification callback registered');
      AtNotificationCallback.getInstance().registerNotificationCallback(
          NotificationType.self, processAtNotification);
    }

    if (verbParams.containsKey(AtConstants.epochMilliseconds) &&
        verbParams[AtConstants.epochMilliseconds] != null) {
      // Send notifications that are already received after EPOCH_MILLIS first
      List<Notification> receivedNotificationsAfterEpochMills =
          await _getNotificationsAfterEpoch(
              int.parse(verbParams[AtConstants.epochMilliseconds]!),
              selfNotificationsFlag == AtConstants.monitorSelfNotifications);
      for (Notification receivedNotification
          in receivedNotificationsAfterEpochMills) {
        await _checkAndSend(receivedNotification);
      }
    }
    atConnection.isMonitor = true;
  }

  /// Does an [isAuthorized] check, if OK then calls [_sendNotification]
  Future<void> _checkAndSend(Notification notification) async {
    if (await isAuthorized(atConnection.metaData as InboundConnectionMetadata,
        atKey: notification.notification)) {
      await _sendNotification(notification);
    }
  }

  /// If connection is authenticate via PKAM
  ///    - Writes all the notifications on the connection.
  ///    - Optionally, if regex is supplied, write only the notifications that
  ///      matches the pattern.
  Future<void> _sendNotification(Notification notification) async {
    var fromAtSign = notification.fromAtSign;
    if (fromAtSign != null) {
      fromAtSign = fromAtSign.replaceAll('@', '');
    }
    try {
      logger.finest('Checking $notification against $regex');
      // If the user does not provide regex, defaults to ".*" to match all notifications.
      if (notification.notification!.contains(RegExp(regex)) ||
          (fromAtSign != null && fromAtSign.contains(RegExp(regex)))) {
        logger.finest('Matched regex - sending');
        await atConnection.write('notification:'
            ' ${jsonEncode(notification.toJson())}\n');
      }
    } on FormatException {
      logger.severe('Invalid regular expression : $regex');
      throw InvalidSyntaxException(
          'Invalid regular expression. $regex is not a valid regex');
    }
  }

  /// [processVerb] above registers this callback method with the notification
  /// manager; all of the registered callbacks are called by the notification
  /// manager when a notification needs to be handled. Here in the Monitor, we
  /// transform the data into format which AtClients should understand, then
  /// call [_checkAndSend]
  Future<void> processAtNotification(AtNotification atNotification) async {
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

      await _checkAndSend(notification);
    }
  }

  /// Returns received notifications of the current atSign
  /// @param responseList : List to add the notifications
  /// @param Future<List> : Returns a list of received notifications of the current atSign.
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
      "availableAt": atNotification.atMetadata?.availableAt.toString(),
      "expiresAt":
          (atNotification.atMetadata?.expiresAt ?? atNotification.expiresAt)
              .toString()
    };
  }

  Map toJson() => {
        AtConstants.id: id,
        AtConstants.from: fromAtSign,
        AtConstants.to: toAtSign,
        AtConstants.key: notification,
        AtConstants.value: value,
        AtConstants.operation: operation,
        AtConstants.epochMilliseconds: dateTime,
        AtConstants.messageType: messageType,
        AtConstants.isEncrypted: isTextMessageEncrypted,
        "metadata": metadata
      };

  @override
  String toString() {
    return toJson().toString();
  }
}
