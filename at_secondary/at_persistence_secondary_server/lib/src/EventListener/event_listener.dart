import 'package:at_persistence_secondary_server/src/EventListener/at_change_event.dart';

/// Class responsible to listening on the [AtChangeEvent]
abstract class AtChangeEventListener {
  /// Publishes the [AtChangeEvent] on change in keystore to the classes implementing
  /// the [AtChangeEventListener].
  Future<void> listen(AtChangeEvent atChangeEvent);
}
