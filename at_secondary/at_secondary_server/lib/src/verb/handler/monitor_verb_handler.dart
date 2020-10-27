import 'dart:collection';
import 'dart:convert';
import 'package:at_persistence_spec/src/keystore/secondary_keystore.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/src/connection/inbound_connection.dart';
import 'package:at_server_spec/src/verb/response.dart';
import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

class MonitorVerbHandler extends AbstractVerbHandler {
  static Monitor monitor = Monitor();

  InboundConnection atConnection;

  String regex;

  MonitorVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

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
      HashMap<String, String> verbParams,
      InboundConnection atConnection) async {
    if (atConnection.getMetaData().isAuthenticated) {
      this.atConnection = atConnection;
      regex = verbParams[AT_REGEX];
      var atNotificationLog = AtNotificationLog.getInstance();

      atNotificationLog.registerNotificationCallback(
          NotificationType.received, processReceiveNotification);
    }
    atConnection.isMonitor = true;
  }

  void processReceiveNotification(AtNotification atNotification) {
    // If connection is invalid, deregister the notification
    if (atConnection.isInValid()) {
      var atNotificationLog = AtNotificationLog.getInstance();
      atNotificationLog.unregisterNotificationCallback(
          NotificationType.received, processReceiveNotification);
    } else {
      var notification = Notification(atNotification);
      var key = atNotification.notification;
      var fromAtSign = atNotification.fromAtSign;
      if (fromAtSign != null) {
        fromAtSign = fromAtSign.replaceAll('@', '');
      }

      // If monitor verb contains regular expression, push notifications that matches the notifications.
      // else push all notifications.
      if (regex != null) {
        try {
          // if key matches the regular expression, push notification.
          // else if fromAtSign matches the regular expression, push notification.
          if (key.contains(RegExp(regex))) {
            atConnection.write(
                'notification: ' + jsonEncode(notification.toJson()) + '\n');
          } else if (fromAtSign != null && fromAtSign.contains(RegExp(regex))) {
            atConnection.write(
                'notification: ' + jsonEncode(notification.toJson()) + '\n');
          }
        } on FormatException {
          logger.severe('Invalid regular expression : ${regex}');
          throw InvalidSyntaxException('Invalid regular expression syntax');
        }
      } else {
        atConnection
            .write('notification: ' + jsonEncode(notification.toJson()) + '\n');
      }
    }
  }
}

///Notification class to represent JSON format.
class Notification {
  String id;
  String fromAtSign;
  int dateTime;
  String toAtSign;
  String notification;
  String operation;
  String value;

  Notification(AtNotification atNotification) {
    id = atNotification.id;
    fromAtSign = atNotification.fromAtSign;
    dateTime = atNotification.notificationDateTime.millisecondsSinceEpoch;
    toAtSign = atNotification.toAtSign;
    notification = atNotification.notification;
    operation =
        atNotification.opType.toString().replaceAll('OperationType.', '');
    value = atNotification.atValue;
  }

  Map toJson() => {
        ID: id,
        FROM: fromAtSign,
        TO: toAtSign,
        KEY: notification,
        VALUE: value,
        OPERATION: operation,
        EPOCH_MILLIS: dateTime
      };
}
