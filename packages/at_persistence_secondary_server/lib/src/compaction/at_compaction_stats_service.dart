/// Persists per-pass compaction metrics. Callers (typically a
/// scheduling layer in `at_secondary_server`) invoke [record] each
/// time a compactable resource's `compact()` stream completes.
///
/// The shape takes primitives rather than a dedicated data class
/// so that the package doesn't need an `AtCompactionStats` type
/// with no other purpose. Concrete impls choose how the metrics
/// are persisted (Hive: as `at_compaction_stats:...` atKeys in
/// the keystore).
abstract class AtCompactionStatsService {
  /// Record one compaction-pass result.
  ///
  /// * [label] identifies the resource that was compacted
  ///   (`'commitLog'`, `'accessLog'`, `'notificationKeystore'`).
  ///   Used by the impl to choose a persistence key.
  /// * [start] is the wall-clock time at which the pass started.
  /// * [compactedCount] is the number of items the
  ///   [Compactable.compact] stream yielded.
  /// * [duration] is the wall-clock time the pass took.
  Future<void> record({
    required String label,
    required DateTime start,
    required int compactedCount,
    required Duration duration,
  });
}
