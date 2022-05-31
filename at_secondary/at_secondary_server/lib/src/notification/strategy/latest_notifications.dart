import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/notification/priority_queue_impl.dart';

///Class implements [NotificationStrategy].
/// Latest Notifications contains Map <String, AtNotificationPriorityQueue> where String is notifier
/// AtNotificationPriorityQueue contains AtNotifications on priority basis.
class LatestNotifications implements NotificationStrategy {
  final _latestNotificationsMap = <String?, AtNotificationPriorityQueue>{};

  int get length => _latestNotificationsMap.length;

  @override
  void add(AtNotification atNotification) {
    if (!_latestNotificationsMap.containsKey(atNotification.notifier)) {
      _latestNotificationsMap.putIfAbsent(atNotification.notifier,
          () => AtNotificationPriorityQueue(comparison: _comparePriorityDates));
    }
    var list = _latestNotificationsMap[atNotification.notifier]!;
    if (atNotification.depth! <= list.size()) {
      var n = atNotification.depth! - list.size();
      while (n == 0) {
        list.removeNotification();
        n--;
      }
    }
    _latestNotificationsMap[atNotification.notifier]!
        .addNotification(atNotification);
  }

  /// Returns a List of AtNotifications.
  List<AtNotification> toList() {
    var tempList = <AtNotification>[];
    for (var element in _latestNotificationsMap.keys) {
      tempList.addAll(_latestNotificationsMap[element]!.toList()!);
    }
    return tempList;
  }

  /// Compares two AtNotifications on notification data time.
  static int _comparePriorityDates(AtNotification p1, AtNotification p2) {
    return p1.notificationDateTime!.millisecondsSinceEpoch
        .compareTo(p2.notificationDateTime!.millisecondsSinceEpoch);
  }
}
