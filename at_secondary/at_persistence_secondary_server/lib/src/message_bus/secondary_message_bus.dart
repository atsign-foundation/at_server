import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

abstract class SecondaryMessageBus {
  publish(String key, AtData atData, String owner, {String sharedWith});
}
