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

  final Map<String?, Map<String, NotificationStrategy>> _notificationMap = <String?, Map<String, NotificationStrategy>>{};
  final Map<String?, NotificationWaitTime> _waitTimeMap = <String?, NotificationWaitTime>{};
  final Map<String?, DateTime> _quarantineMap = <String?, DateTime>{};

  Map<String?, DateTime> get quarantineMap => _quarantineMap;

  /// Adds the notifications to map where key is [AtNotification.toAtSign] and value is classes implementing [NotificationStrategy]
  void add(AtNotification atNotification) {
    _notificationMap.putIfAbsent(atNotification.toAtSign,
        () => {'all': AllNotifications(), 'latest': LatestNotifications()});
    var notificationsMap = _notificationMap[atNotification.toAtSign]!;
    notificationsMap[atNotification.strategy!]!.add(atNotification);
    _computeWaitTime(atNotification);
  }

  int numQueued(String atSign) {
    // If map is empty, or map doesn't contain the atSign, return an iterator for an empty list
    if (_notificationMap.isEmpty || !_notificationMap.containsKey(atSign)) {
      return 0;
    }

    Map<String, NotificationStrategy>? tempMap = _notificationMap[atSign]!; // can't be null, we've just checked containsKey
    LatestNotifications latestList = tempMap['latest'] as LatestNotifications;
    AllNotifications allList = tempMap['all'] as AllNotifications;
    return latestList.length + allList.length;
  }

  /// Returns the map of first N entries.
  Iterator<AtNotification> remove(String? atSign) {
    List<AtNotification> returnList;
    // If map is empty, or map doesn't contain the atSign, return an iterator for an empty list
    if (_notificationMap.isEmpty || !_notificationMap.containsKey(atSign)) {
      returnList = [];
    } else {
      Map<String, NotificationStrategy> tempMap = _notificationMap.remove(atSign)!;
      var latestList = tempMap['latest'] as LatestNotifications;
      var list = tempMap['all'] as AllNotifications;
      returnList = List<AtNotification>.from(latestList.toList())
        ..addAll(list.toList()!);
      tempMap.clear();
    }
    return returnList.iterator;
  }

  /// Returns an Iterator of atsign on priority order.
  Iterator<String?> getAtSignToNotify(int N) {
    var currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    var list = _sortWaitTimeMap(N);
    list.removeWhere((atsign) =>
        _quarantineMap.containsKey(atsign) &&
            _quarantineMap[atsign]!.millisecondsSinceEpoch >
                DateTime.now().millisecondsSinceEpoch ||
        atsign == currentAtSign);
    return list.iterator;
  }

  /// Sorts the keys in [_waitTimeMap] in descending order according to the wait time.
  List<String?> _sortWaitTimeMap(int N) {
    var list = _waitTimeMap.keys.toList()
      ..sort((k1, k2) =>
          _waitTimeMap[k2]!.waitTime.compareTo(_waitTimeMap[k1]!.waitTime));
    return list.take(N).toList();
  }

  /// Computes the wait for the notification.
  void _computeWaitTime(AtNotification atNotification) {
    _waitTimeMap.putIfAbsent(
        atNotification.toAtSign, () => NotificationWaitTime());
    var notificationWaitTime = _waitTimeMap[atNotification.toAtSign]!;
    notificationWaitTime.prioritiesSum = atNotification.priority!.index;
    notificationWaitTime.totalPriorities += 1;
    DateTime? date;
    if (notificationWaitTime.totalPriorities == 1) {
      date = atNotification.notificationDateTime;
    }
    notificationWaitTime.calculateWaitTime(dateTime: date);
  }

  /// Removes the entry from _waitTimeMap.
  void removeWaitTimeEntry(String? atsign) {
    _waitTimeMap.remove(atsign);
  }

  void removeQuarantineEntry(String? atSign) {
    _quarantineMap.remove(atSign);
  }

  ///Clears the map instances.
  void clear() {
    _notificationMap.clear();
    _waitTimeMap.clear();
    _quarantineMap.clear();
  }
}
