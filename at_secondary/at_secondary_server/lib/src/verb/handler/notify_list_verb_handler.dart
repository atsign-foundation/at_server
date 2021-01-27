import 'dart:collection';
import 'dart:convert';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_spec/src/keystore/secondary_keystore.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_server_spec/src/connection/inbound_connection.dart';
import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_server_spec/src/verb/notify_list.dart';
import '../verb_enum.dart';
import 'abstract_verb_handler.dart';
import 'package:at_commons/at_commons.dart';

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
    // If regex is not null, apply regular expression on the notifications.
    if (regex != null) {
      responseList = _applyRegexFilter(responseList, regex);
    }
    var result;
    if (responseList.isNotEmpty) {
      result = jsonEncode(responseList);
    }
    response.data = result;
  }

  /// Accepts notifications list and filter notifications based on regular expressions.
  /// @param notification : list of notifications
  /// @param regex : regular expression
  /// @return list : list of notifications that match the regular expression.
  List _applyRegexFilter(List notification, String regex) {
    // Retains notifications whose keys or atsign matches the regular expression
    notification.retainWhere((element) =>
        element[KEY].toString().contains(RegExp(regex)) ||
        _isAtsignRegex(element[FROM], regex));
    return notification;
  }

  /// Returns received notifications of the current atsign
  /// @param responseList : List to add the notifications
  /// @param Future<List> : Returns a list of received notifications of the current atsign.
  Future<List> _getReceivedNotification(List responseList) async {
    var notificationKeyStore = AtNotificationKeystore.getInstance();
    //NotificationEntry notificationEntry;
    var keyList = await notificationKeyStore.getKeys();
    await Future.forEach(
        keyList,
        (element) => _fetchNotificationEntries(
            element, responseList, notificationKeyStore));
    return responseList;
  }

  /// Fetches the notification entries for the given atsign.
  void _fetchNotificationEntries(
      element, responseList, notificationKeyStore) async {
    var notificationEntry = await notificationKeyStore.get(element);
    if (notificationEntry != null) {
      notificationEntry.receivedNotifications.forEach((element) {
        responseList.add(Notification(element));
      });
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
      logger.finer('connect result: ${connectResult}');
    }
    var sentNotifications = await outBoundClient.notifyList(fromAtSign);
    sentNotifications.forEach((element) {
      responseList.add(Notification(element));
    });
    return responseList;
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
}
