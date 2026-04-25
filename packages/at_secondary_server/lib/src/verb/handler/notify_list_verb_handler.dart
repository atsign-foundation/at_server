import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart' hide StringBuffer;
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

import 'abstract_verb_handler.dart';
import 'monitor_verb_handler.dart';

/// class to handle notify:list verb
class NotifyListVerbHandler extends AbstractVerbHandler {
  static NotifyList notifyList = NotifyList();
  final NotificationManager notifMgr;

  NotifyListVerbHandler(
    super.keyStore,
    this.notifMgr,
  );

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
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var regex = verbParams[AtConstants.regex];
    int? fromDateInEpoch;
    int toDateInEpoch;
    try {
      fromDateInEpoch = (verbParams['fromDate'] != null)
          ? DateTime.parse(verbParams['fromDate']!).millisecondsSinceEpoch
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
    var atConnectionMetadata =
        atConnection.metaData as InboundConnectionMetadata;
    final RegExp? compiledRegex = regex == null ? null : RegExp(regex);

    StringBuffer sb = StringBuffer();

    sb.write('[');
    // If connection is authenticated, gets the received notifications of current atsign
    if (atConnectionMetadata.isAuthenticated) {
      bool first = true;
      for (final k in await notifMgr.getKeys()) {
        AtNotification n = (await notifMgr.get(k))!;
        if (n.type == NotificationType.received &&
            !n.isExpired() &&
            (await super
                .isAuthorized(atConnectionMetadata, atKey: n.notification!)) &&
            _matchesRequestFilters(
              n,
              fromDateInEpoch,
              toDateInEpoch,
              compiledRegex,
            )) {
          if (first) {
            first = false;
          } else {
            sb.write(',');
          }
          sb.write(jsonEncode(n.mapForClient));
        }
      }
    } else
    // If authenticated connection from another atSign (polAuthenticated),
    // gets the notifications which were sent to that atSign
    if (atConnectionMetadata.isPolAuthenticated) {
      bool first = true;
      for (var n in (await notifMgr.getFilteredSorted(
          retain: (n) {
            return n.type == NotificationType.sent &&
                atConnectionMetadata.fromAtSign! == n.toAtSign &&
                _matchesRequestFilters(
                  n,
                  fromDateInEpoch,
                  toDateInEpoch,
                  compiledRegex,
                );
          },
          comparator: notifMgr.compareDateTime))) {
        if (first) {
          first = false;
        } else {
          sb.write(',');
        }
        sb.write(
          jsonEncode(n.mapForClient),
        );
      }
    }
    sb.write(']');

    response.data = sb.toString();
    sb.clear();
  }

  /// Returns boolean value.
  /// Returns true if notification matches with the filter criteria
  /// Returns false if notification does not match with filter criteria
  bool _matchesRequestFilters(AtNotification notification,
      int? fromDateInEpoch, int toDateInEpoch, RegExp? regex) {
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
  bool _applyRegexFilter(AtNotification notification, RegExp regex) {
    return notification.notification.toString().contains(regex) ||
        _isAtsignRegex(notification.fromAtSign!, regex);
  }

  /// Accepts atsign and regular expression(regex) and verifies if atsign matches the regular expression.
  /// @param atSign : atsign user
  /// @param regex : regular expression to match with atsign
  /// @return bool : Returns true if atsign matches the regex, else false.
  bool _isAtsignRegex(String atSign, RegExp regex) {
    return atSign.replaceAll('@', '').contains(regex);
  }

  /// Filters notification basing on from and to date specified.
  bool _applyDateFilter(
      AtNotification notification, int fromDateInEpoch, int toDateInEpoch) {
    return notification.notificationDateTime!.millisecondsSinceEpoch >=
            fromDateInEpoch &&
        notification.notificationDateTime!.millisecondsSinceEpoch <=
            toDateInEpoch;
  }
}
