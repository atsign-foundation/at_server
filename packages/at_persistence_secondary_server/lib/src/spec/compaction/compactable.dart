/// A resource that can be compacted — i.e. that periodically prunes
/// state it no longer needs. Implemented by [AtCommitLog],
/// [AtAccessLog], [AtNotificationKeystore], and [AtKeyValueStore].
///
/// What "compaction" *means* is entirely up to the concrete impl:
/// dropping the oldest N% of entries, pruning by age, deduplicating
/// per-key, vacuuming a database, etc. Per-resource configuration
/// (thresholds, percentages, retention windows) is owned by the
/// concrete impl — not passed in via an `AtCompactionConfig` data
/// class. Server-side scheduling (when to call this) is owned by
/// `at_secondary_server`, not by anything in this package.
abstract interface class Compactable {
  /// Compact this resource. If [dryRun] is `true`, yields each
  /// item that WOULD be removed by a real compaction pass — no
  /// state is mutated, the call is purely diagnostic. If `false`,
  /// performs the compaction and yields each item as it is
  /// removed.
  ///
  /// The element type is intentionally `Object`; concrete impls
  /// tighten the return type via covariant override — e.g. an
  /// [AtCommitLog] impl yields `Stream<int>` of commit ids, an
  /// [AtNotificationKeystore] impl yields `Stream<String>` of
  /// notification keys.
  Stream<Object> compact(bool dryRun);
}
