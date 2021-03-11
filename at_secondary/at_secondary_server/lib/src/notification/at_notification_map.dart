import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/notification/notification_wait_time.dart';
import 'package:at_secondary/src/notification/strategy/all_notifications.dart';
import 'package:at_secondary/src/notification/strategy/latest_notifications.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';

class AtNotificationMap {
  static final AtNotificationMap _singleton = AtNotificationMap._internal();

  AtNotificationMap._internal();

  factory AtNotificationMap.getInstance() {
    return _singleton;
  }

  final _notificationMap = <String, Map<String, NotificationStrategy>>{};
  final _waitTimeMap = <String, NotificationWaitTime>{};
  var _quarantineMap = <String, DateTime>{};

  Map<String, DateTime> get quarantineMap => _quarantineMap;

  set quarantineMap(value) {
    _quarantineMap = value;
  }

  /// Adds the notifications to map where key is [AtNotification.toAtSign] and value is classes implementing [NotificationStrategy]
  void add(AtNotification atNotification) {
    _notificationMap.putIfAbsent(atNotification.toAtSign,
        () => {'all': AllNotifications(), 'latest': LatestNotifications()});
    var notificationsMap = _notificationMap[atNotification.toAtSign];
    notificationsMap[atNotification.strategy].add(atNotification);
    _computeWaitTime(atNotification);
  }

  /// Returns the map of first N entries.
  Iterator<AtNotification> remove(String atsign) {
    // If map is empty, return empty map
    if (_notificationMap.isEmpty) {
      return [].iterator;
    }
    // If map does not contain the atsign, return empty map.
    if (!_notificationMap.containsKey(atsign)) {
      return [].iterator;
    }
    var tempMap = _notificationMap.remove(atsign);
    LatestNotifications latestList = tempMap['latest'];
    AllNotifications list = tempMap['all'];
    var returnList = List<AtNotification>.from(latestList.toList())
      ..addAll(list.toList());
    tempMap.clear();
    return returnList.iterator;
  }

  /// Returns an Iterator of atsign on priority order.
  Iterator<String> getAtSignToNotify(int N) {
    var currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    var list = _sortWaitTimeMap(N);
    list.removeWhere((atsign) =>
        _quarantineMap.containsKey(atsign) &&
            _quarantineMap[atsign].millisecondsSinceEpoch >
                DateTime.now().millisecondsSinceEpoch ||
        atsign == currentAtSign);
    return list.iterator;
  }

  /// Sorts the keys in [_waitTimeMap] in descending order according to the wait time.
  List<String> _sortWaitTimeMap(int N) {
    var list = _waitTimeMap.keys.toList()
      ..sort((k1, k2) =>
          _waitTimeMap[k2].waitTime.compareTo(_waitTimeMap[k1].waitTime));
    if (N != null) {
      return list.take(N).toList();
    }
    return list;
  }

  /// Computes the wait for the notification.
  void _computeWaitTime(AtNotification atNotification) {
    _waitTimeMap.putIfAbsent(
        atNotification.toAtSign, () => NotificationWaitTime());
    var notificationWaitTime = _waitTimeMap[atNotification.toAtSign];
    notificationWaitTime.prioritiesSum = atNotification.priority.index;
    notificationWaitTime.totalPriorities = 1;
    var date;
    if (notificationWaitTime.totalPriorities == 1) {
      date = atNotification.notificationDateTime;
    }
    notificationWaitTime.calculateWaitTime(dateTime: date);
  }

  /// Removes the entry from _waitTimeMap.
  void removeWaitTimeEntry(String atsign) {
    _waitTimeMap.remove(atsign);
  }

  void removeQuarantineEntry(String atSign) {
    _quarantineMap.remove(atSign);
  }

  ///Clears the map instances.
  void clear() {
    _notificationMap.clear();
    _waitTimeMap.clear();
    _quarantineMap.clear();
  }
}
