import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

/// The class observers the compactions process and is responsible to record
/// compaction activity.
abstract class AtCompactionObserver {
  void start(AtLogType atLogType);

  Future<void> end(AtLogType atLogType);
}
