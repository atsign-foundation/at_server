/// The class observers the compactions process and is responsible to record
/// compaction activity.
abstract class AtCompactionObserver {

  /// Invoked before the compaction process begins.
  /// Captures the compaction metrics before compaction starts
  void start();

  /// Invokes after the compaction ends.
  /// Captures the compaction metrics at the end of the compaction process.
  Future<void> end();
}
