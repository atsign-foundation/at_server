import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:meta/meta.dart';

class MonitorConfig {
  RegExp regex = RegExp('.*');
  StreamSubscription<AtNotification>? received;
  StreamSubscription<AtNotification>? self;
}

class MonitorVerbHandler extends AbstractVerbHandler {
  static Monitor monitor = Monitor();

  MonitorVerbHandler(super.keyStore, this.notifMgr);

  NotificationManager notifMgr;

  @override
  bool accept(String command) => command.startsWith(getName(VerbEnum.monitor));

  @override
  Verb getVerb() {
    return monitor;
  }

  @visibleForTesting
  Map<InboundConnection, MonitorConfig> configMap = {};

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    if (!atConnection.metaData.isAuthenticated) {
      throw UnAuthenticatedException(
          'Failed to execute verb. monitor requires authentication');
    }
    if (!configMap.containsKey(atConnection)) {
      configMap[atConnection] = MonitorConfig();
    }

    MonitorConfig mc = configMap[atConnection]!;
    // If regex is not provided by user, set regex to ".*" to match all the possibilities
    // else set regex to the value given by the user.
    try {
      mc.regex = RegExp(verbParams[AtConstants.regex] ?? '.*');
    } catch (e) {
      throw InvalidSyntaxException(
          'Invalid regex: ${verbParams[AtConstants.regex]}');
    }
    final selfNotificationsParam =
        verbParams[AtConstants.monitorSelfNotifications];
    mc.received = notifMgr.received.stream
        .listen((n) => processAtNotification(atConnection, n));
    if (selfNotificationsParam == AtConstants.monitorSelfNotifications) {
      mc.self = notifMgr.self.stream
          .listen((n) => processAtNotification(atConnection, n));
    }

    if (verbParams.containsKey(AtConstants.epochMilliseconds) &&
        verbParams[AtConstants.epochMilliseconds] != null) {
      // Send notifications already in the data store

      // set up values for the retain closure below
      int sinceMillis = int.parse(verbParams[AtConstants.epochMilliseconds]!);
      List<NotificationType> notifTypes = [NotificationType.received];
      if (selfNotificationsParam == AtConstants.monitorSelfNotifications) {
        notifTypes.add(NotificationType.self);
      }
      List<AtNotification> notifs = await notifMgr.getFilteredSorted(
        retain: (n) {
          // Filter expired
          if (n.isExpired()) {
            return false;
          }

          // Filter any before the provided epoch value
          if ((n.notificationDateTime?.millisecondsSinceEpoch ?? 0) <=
              sinceMillis) {
            return false;
          }

          // Filter by notification type
          // Must be either received or self (if the self flag was set)
          if (!notifTypes.contains(n.type)) {
            return false;
          }

          // Must match the regex
          if (n.notification?.contains(mc.regex) != true) {
            return false;
          }

          return true;
        },
        comparator: notifMgr.compareDateTime,
      );
      for (AtNotification n in notifs) {
        await processAtNotification(atConnection, n);
      }
    }
    atConnection.isMonitor = true;
  }

  /// - Checks if connection is authorized for this notif's key's namespace
  /// - Checks if the notif's key matches the regex
  /// - Writes the notification to the connection
  Future<void> _sendNotification(
      AtConnection atConnection, AtNotification notification) async {
    if (!(await isAuthorized(atConnection.metaData as InboundConnectionMetadata,
        atKey: notification.notification))) {
      return;
    }

    if (!configMap.containsKey(atConnection)) {
      logger.severe('_sendNotification: no connection config for connection'
          ' ${atConnection.metaData.toString()}');
      return;
    }

    MonitorConfig mc = configMap[atConnection]!;
    var fromAtSign = notification.fromAtSign?.replaceAll('@', '');
    try {
      if (notification.notification!.contains(mc.regex) ||
          (fromAtSign != null && fromAtSign.contains(mc.regex))) {
        if (logger.isLoggable('finest')) {
          logger.finest('${notification.notification} vs ${mc.regex} : true');
        }
        await atConnection.write('notification:'
            ' ${jsonEncode(notification.mapForClient)}\n');
      } else {
        if (logger.isLoggable('finest')) {
          logger.finest('${notification.notification} vs ${mc.regex} : false');
        }
      }
    } catch (e) {
      logger.severe('$e while delivering ${notification.notification}'
          ' to client ${atConnection.metaData.sessionID}');
    }
  }

  /// [processVerb] above registers this callback method with the notification
  /// manager; all of the registered callbacks are called by the notification
  /// manager when a notification needs to be handled. Here in the Monitor, we
  /// transform the data into format which AtClients should understand, then
  /// call [_checkAndSend]
  Future<void> processAtNotification(
      AtConnection atConnection, AtNotification atNotification) async {
    try {
      // If connection is invalid, cancel subscriptions and remove the config
      if (atConnection.isInValid()) {
        if (configMap.containsKey(atConnection)) {
          logger.info(
              'Connection sessionID ${atConnection.metaData.sessionID} invalid, cancelling subscriptions');
          MonitorConfig mc = configMap[atConnection]!;
          if (mc.received != null) {
            logger.info('Cancelling "received" subscription');
            await mc.received!.cancel();
            mc.received = null;
          }
          if (mc.self != null) {
            logger.info('Cancelling "self" subscription');
            await mc.self!.cancel();
            mc.self = null;
          }
          configMap.remove(atConnection);
          return;
        } else {
          logger.info(
              'Connection sessionID ${atConnection.metaData.sessionID} invalid, and no MonitorConfig available');
        }
      }

      await _sendNotification(atConnection, atNotification);
    } catch (e, st) {
      logger.severe('Unexpected exception $e in processAtNotification\n$st');
    }
  }
}

extension MapForClient on AtNotification {
  Map<String, dynamic> get mapForClient => {
        AtConstants.id: id,
        AtConstants.from: fromAtSign,
        AtConstants.to: toAtSign,
        AtConstants.key: notification,
        AtConstants.value: atValue,
        AtConstants.operation: opType?.name,
        AtConstants.epochMilliseconds:
            notificationDateTime!.millisecondsSinceEpoch,
        AtConstants.messageType: messageType?.toString(),
        AtConstants.isEncrypted: atMetadata?.isEncrypted ?? false,
        "metadata": {
          "ttr": atMetadata?.ttr,
          "ttl": atMetadata?.ttl,
          "ttb": atMetadata?.ttb,
          "sharedKeyEnc": atMetadata?.sharedKeyEnc,
          "pubKeyCS": atMetadata?.pubKeyCS,
          "dataSignature": atMetadata?.dataSignature,
          "encKeyName": atMetadata?.encKeyName,
          "encAlgo": atMetadata?.encAlgo,
          "ivNonce": atMetadata?.ivNonce,
          "skeEncKeyName": atMetadata?.skeEncKeyName,
          "skeEncAlgo": atMetadata?.skeEncAlgo,
          "availableAt": atMetadata?.availableAt.toString(),
          "expiresAt": (atMetadata?.expiresAt ?? expiresAt).toString(),
          "pubKeyHash": atMetadata?.pubKeyHash != null
              ? jsonEncode(atMetadata?.pubKeyHash?.toJson())
              : null,
          // The client parses this with Metadata.decodeAppMetadata,
          // which accepts a Map (emitted here) or a base64 string.
          AtConstants.appMetadata: atMetadata?.appMetadata?.toJson(),
        }
      };
}
