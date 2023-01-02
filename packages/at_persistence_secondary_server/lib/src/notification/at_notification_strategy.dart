import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

abstract class NotificationStrategy {
  void add(AtNotification atNotification);
}
