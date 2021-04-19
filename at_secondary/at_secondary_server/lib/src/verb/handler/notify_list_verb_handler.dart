import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_spec/src/keystore/secondary_keystore.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/src/connection/inbound_connection.dart';
import 'package:at_server_spec/src/verb/notify_list.dart';
import 'package:at_server_spec/src/verb/verb.dart';

import 'abstract_verb_handler.dart';

/// class to handle notify:list verb
class NotifyListVerbHandler extends AbstractVerbHandler {
  static NotifyList notifyList = NotifyList();

  NotifyListVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  @override
  bool accept(String command) =>
      command.startsWith('${getName(VerbEnum.notify)}:list');

  @override
  Verb getVerb() {
    return notifyList;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String> verbParams,
      InboundConnection atConnection) async {
    var regex = verbParams[AT_REGEX];
    var fromDateInEpoch;
    var toDateInEpoch;
    try {
      fromDateInEpoch = (verbParams['fromDate'] != null)
          ? DateTime.parse(verbParams['fromDate']).millisecondsSinceEpoch
          : null;
      toDateInEpoch = (verbParams['toDate'] != null)
          ? DateTime.parse('${verbParams['toDate']} 23:59:99Z')
              .millisecondsSinceEpoch
          : DateTime.now().millisecondsSinceEpoch;
      if (fromDateInEpoch != null && toDateInEpoch < fromDateInEpoch) {
        logger.severe('ToDate cannot be less than FromDate');
        throw IllegalArgumentException('ToDate cannot be less than FromDate');
      }
    } on FormatException catch (e) {
      logger.severe('Invalid date format ${e.toString()}');
      throw IllegalArgumentException('Invalid date format');
    }
    InboundConnectionMetadata atConnectionMetadata = atConnection.getMetaData();
    var fromAtSign = atConnectionMetadata.fromAtSign;
    var responseList = <Notification>[];

    // If connection is authenticated, gets the received notifications of current atsign
    if (atConnectionMetadata.isAuthenticated) {
      responseList = await _getReceivedNotification(responseList);
    }
    //If connection is pol authenticated, gets the sent notifications to forAtSign
    if (atConnectionMetadata.isPolAuthenticated) {
      responseList =
          await _getSentNotifications(responseList, fromAtSign, atConnection);
    }
    responseList =
        _applyFilter(responseList, fromDateInEpoch, toDateInEpoch, regex);
    var result;
    if (responseList.isNotEmpty) {
      result = jsonEncode(responseList);
    }
    response.data = result;
  }

  /// Returns received notifications of the current atsign
  /// @param responseList : List to add the notifications
  /// @param Future<List> : Returns a list of received notifications of the current atsign.
  Future<List> _getReceivedNotification(List responseList) async {
    var notificationKeyStore = AtNotificationKeystore.getInstance();
    var keyList = notificationKeyStore.getValues();
    await Future.forEach(
        keyList,
        (element) => _fetchNotificationEntries(
            element, responseList, notificationKeyStore));
    return responseList;
  }

  /// Fetches the notification entries for the given atsign.
  void _fetchNotificationEntries(
      element, responseList, notificationKeyStore) async {
    var notificationEntry = await notificationKeyStore.get(element.id);
    if (notificationEntry != null &&
        notificationEntry.type == NotificationType.received) {
      responseList.add(Notification(element));
    }
  }

  /// when pol verb is performed, returns sent notifications of the another atsign.
  /// @param responseList : List to add notifications.
  /// @param fromAtSign : atsign who look up to the current atsign server
  /// @param atConnection : The inbound connection.
  /// @return Future<List> : Returns a list of sent notifications of the fromAtSign.
  Future<List> _getSentNotifications(List responseList, String fromAtSign,
      InboundConnection atConnection) async {
    var outBoundClient =
        OutboundClientManager.getInstance().getClient(fromAtSign, atConnection);
    // Need not connect again if the client's handshake is already done
    if (!outBoundClient.isHandShakeDone) {
      var connectResult = await outBoundClient.connect();
      logger.finer('connect result: $connectResult');
    }
    var sentNotifications = outBoundClient.notifyList(fromAtSign);
    sentNotifications.forEach((element) {
      responseList.add(Notification(element));
    });
    return responseList;
  }

  /// Applies filter criteria on the notifications
  List _applyFilter(List notificationList, int fromDateInEpoch,
      int toDateInEpoch, String regex) {
    notificationList.retainWhere((notification) => _isNotificationRetained(
        notification, fromDateInEpoch, toDateInEpoch, regex));
    return notificationList;
  }

  /// Returns boolean value.
  /// Returns true if notification matches with the filter criteria
  /// Returns false if notification does not match with filter criteria
  bool _isNotificationRetained(
      Notification notification, fromDateInEpoch, toDateInEpoch, regex) {
    // If fromDateInEpoch and regex are null, filter criteria is not specified, hence
    // return true to retain the notification.
    if (fromDateInEpoch == null && regex == null) {
      return true;
    }
    var isDateFilter = true;
    var isRegex = true;
    if (fromDateInEpoch != null) {
      isDateFilter =
          _applyDateFilter(notification, fromDateInEpoch, toDateInEpoch);
    }
    if (regex != null) {
      isRegex = _applyRegexFilter(notification, regex);
    }
    // If notification matches the filter criteria return true to retain the notification,
    // else to remove the notification.
    if (isRegex && isDateFilter) {
      return true;
    }
    return false;
  }

  /// Accepts notifications list and filter notifications based on regular expressions.
  /// @param notification : list of notifications
  /// @param regex : regular expression
  /// @return list : list of notifications that match the regular expression.
  bool _applyRegexFilter(Notification notification, String regex) {
    return notification.notification.toString().contains(RegExp(regex)) ||
        _isAtsignRegex(notification.fromAtSign, regex);
  }

  /// Accepts atsign and regular expression(regex) and verifies if atsign matches the regular expression.
  /// @param atSign : atsign user
  /// @param regex : regular expression to match with atsign
  /// @return bool : Returns true if atsign matches the regex, else false.
  bool _isAtsignRegex(String atSign, String regex) {
    var isAtsignRegex = false;
    atSign = atSign.replaceAll('@', '');
    if (atSign != null && atSign.contains(RegExp(regex))) {
      isAtsignRegex = true;
    }
    return isAtsignRegex;
  }

  /// Filters notification basing on from and to date specified.
  bool _applyDateFilter(
      Notification notification, int fromDateInEpoch, int toDateInEpoch) {
    return notification.dateTime >= fromDateInEpoch &&
        notification.dateTime <= toDateInEpoch;
  }
}
