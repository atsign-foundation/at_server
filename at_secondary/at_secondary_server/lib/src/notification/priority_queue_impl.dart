import 'package:at_persistence_secondary_server/src/notification/at_notification.dart';
import 'package:collection/src/priority_queue.dart';

/// Class implementing the priority queue.
class AtNotificationPriorityQueue {
  final PriorityQueue<AtNotification> _priorityQueue;

  AtNotificationPriorityQueue({priorityQueue, comparison})
      : _priorityQueue = PriorityQueue<AtNotification>(comparison ??= _comparePriority);

  /// Adds [AtNotification] to the priority queue.
  /// Accepts [AtNotification] as input param.
  /// Returns notificationId.
  void addNotification(AtNotification atNotification) {
    _priorityQueue.add(atNotification);
  }

  /// Returns the [AtNotification] from the queue.
  AtNotification? removeNotification() {
    return _priorityQueue.removeFirst();
  }

  /// Returns the list of notification in the queue.
  List<AtNotification>? toList() {
    return _priorityQueue.toList();
  }

  /// Returns the size of the priority queue
  int size() {
    return _priorityQueue.length;
  }

  /// Clears the priority queue.
  void clear() {
    _priorityQueue.clear();
  }

  /// Compares the priority of given two notifications.
  static int _comparePriority(AtNotification p1, AtNotification p2) {
    // If both notifications have same priority, then first come first serve.
    var arg1 = p1.priority!.index *
        DateTime.now().difference(p1.notificationDateTime!).inMilliseconds;
    var arg2 = p2.priority!.index *
        DateTime.now().difference(p2.notificationDateTime!).inMilliseconds;
    return arg2.compareTo(arg1);
  }
}
