import 'package:at_persistence_secondary_server/src/event_listener/at_change_event.dart';

/// Class responsible to listening on the [AtPersistenceChangeEvent]
abstract class AtChangeEventListener {
  /// Publishes the [AtPersistenceChangeEvent] on change in keystore to the classes implementing
  /// the [AtChangeEventListener].
  Future<void> listen(AtPersistenceChangeEvent atChangeEvent);
  ignoreCommitId(int commitId);
}
