import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

class MonitorVerbHandler extends AbstractVerbHandler {
  static Monitor monitor = Monitor();

  late InboundConnection atConnection;

  late String regex;

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
    if (!atConnection.getMetaData().isAuthenticated) {
      throw UnAuthenticatedException(
          'Failed to execute verb. monitor requires authentication');
    }
    this.atConnection = atConnection;
    // If regex is not provided by user, set regex to ".*" to match all the possibilities
    // else set regex to the value given by the user.
    (verbParams[AT_REGEX] == null)
        ? regex = '.*'
        : regex = verbParams[AT_REGEX]!;
    final selfNotificationsFlag = verbParams[MONITOR_SELF_NOTIFICATIONS];
    AtNotificationCallback.getInstance().registerNotificationCallback(
        NotificationType.received, processAtNotification);
    if (selfNotificationsFlag == MONITOR_SELF_NOTIFICATIONS) {
      logger.finer('self notification callback registered');
      AtNotificationCallback.getInstance().registerNotificationCallback(
          NotificationType.self, processAtNotification);
    }

    if (verbParams.containsKey(EPOCH_MILLIS) &&
        verbParams[EPOCH_MILLIS] != null) {
      // Send notifications that are already received after EPOCH_MILLIS first
      List<Notification> receivedNotificationsAfterEpochMills =
          await _getNotificationsAfterEpoch(
              int.parse(verbParams[EPOCH_MILLIS]!),
              selfNotificationsFlag == MONITOR_SELF_NOTIFICATIONS);
      for (Notification receivedNotification
          in receivedNotificationsAfterEpochMills) {
        await _sendNotificationToClient(receivedNotification);
      }
    }
    atConnection.isMonitor = true;
  }

  /// Writes [notification] on authenticated connection
  /// * If connection is authenticate via PKAM
  ///    - Writes all the notifications on the connection.
  ///    - Optionally, if regex is supplied, write only the notifications that
  ///      matches the pattern.
  ///
  /// * If connection is authenticated via APKAM
  ///    - Writes the notifications only if the namespace in the notification key
  ///      matches the namespace in the enrollment.
  ///    - Optionally if regex is supplied, write only the notifications that
  ///      matches the pattern.
  Future<void> _sendNotificationToClient(Notification notification) async {
    // If enrollmentId is null, then connection is authenticated via PKAM
    if ((atConnection.getMetaData() as InboundConnectionMetadata)
            .enrollmentId ==
        null) {
      _sendLegacyNotification(notification);
    } else {
      // If enrollmentId is populated, then connection is authenticated via APKAM
      await _sendNotificationByEnrollmentNamespaceAccess(notification);
    }
  }

  /// If connection is authenticate via PKAM
  ///    - Writes all the notifications on the connection.
  ///    - Optionally, if regex is supplied, write only the notifications that
  ///      matches the pattern.
  void _sendLegacyNotification(Notification notification) {
    var fromAtSign = notification.fromAtSign;
    if (fromAtSign != null) {
      fromAtSign = fromAtSign.replaceAll('@', '');
    }
    try {
      // If the user does not provide regex, defaults to ".*" to match all notifications.
      if (notification.notification!.contains(RegExp(regex)) ||
          (fromAtSign != null && fromAtSign.contains(RegExp(regex)))) {
        atConnection
            .write('notification: ${jsonEncode(notification.toJson())}\n');
      }
    } on FormatException {
      logger.severe('Invalid regular expression : $regex');
      throw InvalidSyntaxException(
          'Invalid regular expression. $regex is not a valid regex');
    }
  }

  /// If connection is authenticated via APKAM
  ///    - Writes the notifications only if the namespace in the notification key
  ///      matches the namespace in the enrollment.
  ///    - Optionally if regex is supplied, write only the notifications that
  ///      matches the pattern.
  Future<void> _sendNotificationByEnrollmentNamespaceAccess(
      Notification notification) async {
    // Fetch namespaces that are associated with the enrollmentId.
    var enrollmentKey =
        '${(atConnection.getMetaData() as InboundConnectionMetadata).enrollmentId}.$newEnrollmentKeyPattern.$enrollManageNamespace${AtSecondaryServerImpl.getInstance().currentAtSign}';
    EnrollDataStoreValue enrollDataStoreValue =
        await getEnrollDataStoreValue(enrollmentKey);
    // When an enrollment is revoked, avoid sending notifications to the
    // existing monitor connection.
    if (enrollDataStoreValue.approval!.state != EnrollStatus.approved.name) {
      logger.info('Enrollment is not approved. Failed to send notifications');
      return;
    }
    if (enrollDataStoreValue.namespaces.isEmpty) {
      logger.info('No namespaces are enrolled for the enrollmentId:'
          ' ${(atConnection.getMetaData() as InboundConnectionMetadata).enrollmentId}');
      return;
    }
    // separate namespace from the notification key
    String namespaceFromKey = notification.notification!
        .substring(notification.notification!.indexOf('.') + 1);

    try {
      // - If the namespace in the notification key matches the namespace in the
      //   enrollment, it indicates that the client has successfully enrolled for
      //   that namespace, thereby granting authorization to receive notifications.
      //
      // - If namespace is enrollManageNamespace (__manage) or allNamespace (.*),
      //   then all enrollments should be written to client to perform action
      //   (approve/deny)on an enrollment.
      //
      // - Optionally, if regex is provided, send only the notifications which match
      //   the regex patten by notification key or fromAtSign of the notification.
      // - If the user does not provide regex, defaults to ".*" to match all notifications.
      //   match the exact namespace
      if ((enrollDataStoreValue.namespaces.containsKey(allNamespaces) ||
              enrollDataStoreValue.namespaces
                  .containsKey(enrollManageNamespace) ||
              enrollDataStoreValue.namespaces.containsKey(namespaceFromKey)) &&
          (notification.notification!.contains(RegExp(regex)) ||
              (notification.fromAtSign != null &&
                  notification.fromAtSign!.contains(RegExp(regex))))) {
        atConnection
            .write('notification: ${jsonEncode(notification.toJson())}\n');
      }
    } on FormatException {
      logger.severe('Invalid regular expression : $regex');
      throw InvalidSyntaxException(
          'Invalid regular expression. $regex is not a valid regex');
    }
  }

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
      await _sendNotificationToClient(notification);
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
