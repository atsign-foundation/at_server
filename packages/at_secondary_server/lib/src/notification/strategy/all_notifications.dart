import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/notification/priority_queue_impl.dart';

/// Class implements [NotificationStrategy]. All the notifications are stored in the priority queue
/// on priority basis
/// Priority is calculated as notification priority * (current data time - notification date time)
class AllNotifications implements NotificationStrategy {
  final _priorityQueue = AtNotificationPriorityQueue();

  int get length => _priorityQueue.size();

  @override
  void add(AtNotification atNotification) {
    _priorityQueue.addNotification(atNotification);
  }

  List<AtNotification>? toList() {
    return _priorityQueue.toList();
  }
}
