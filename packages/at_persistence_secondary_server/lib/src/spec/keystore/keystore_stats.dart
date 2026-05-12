/// Diagnostic snapshot of a [AtKeyValueStore]'s state. Returned
/// by [`AtKeyValueStore.stats`]. Counts are exact; [sizeBytes]
/// is a best-effort approximation (Hive doesn't expose a precise
/// byte count without a filesystem `stat`).
///
/// Not load-bearing — intended for operator dashboards / debug
/// surfaces (e.g. `AtClient.diagnostics()`), not for runtime
/// decisions on a hot path.
class KeyStoreStats {
  /// Total number of keys currently in the store, including
  /// expired/not-yet-born ones.
  final int totalKeys;

  /// Number of keys with a non-null `ttl` metadata field.
  final int ttlKeys;

  /// Number of keys with a non-null `ttb` metadata field.
  final int ttbKeys;

  /// Approximate on-disk size in bytes. `0` means "not reported"
  /// (the backend doesn't expose a cheap size query). Hive impls
  /// typically leave this at `0`; SQL backends report exact.
  final int sizeBytes;

  /// `createdAt` of the earliest entry in the store (lowest), or
  /// `null` if the store is empty.
  final DateTime? oldestCreatedAt;

  /// `createdAt` of the latest entry in the store (highest), or
  /// `null` if the store is empty.
  final DateTime? newestCreatedAt;

  const KeyStoreStats({
    required this.totalKeys,
    required this.ttlKeys,
    required this.ttbKeys,
    required this.sizeBytes,
    required this.oldestCreatedAt,
    required this.newestCreatedAt,
  });

  @override
  String toString() => 'KeyStoreStats('
      'totalKeys: $totalKeys, '
      'ttlKeys: $ttlKeys, '
      'ttbKeys: $ttbKeys, '
      'sizeBytes: $sizeBytes, '
      'oldestCreatedAt: $oldestCreatedAt, '
      'newestCreatedAt: $newestCreatedAt)';
}
