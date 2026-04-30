import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

/// Backend-agnostic contract for "shrink this store down".
///
/// Phase 1's compaction wiring reached into `AtLogType` directly,
/// which forced `at_secondary_server` (and `at_client_sdk`) to know
/// about Hive-shaped primitives like
/// [AtLogType.getKeysToDeleteOnCompaction] /
/// [AtLogType.deleteKeyForCompaction]. Phase 2 hides those behind
/// this strategy: the bundle exposes a strategy per log/store, the
/// scheduler ([AtCompactionJob]) just calls [compact] periodically
/// and the strategy decides what "shrink" means for its backend.
///
/// On Hive, the supplied [HiveCompactionStrategy] still leans on
/// the existing keys-to-delete primitives. A future SQLite or
/// Postgres backend would implement this with a `DELETE WHERE`
/// (and possibly a `VACUUM`) instead.
abstract class AtCompactionStrategy {
  /// Update the [AtCompactionConfig] this strategy uses (frequency
  /// is for the scheduler; percentage etc. are for the strategy).
  /// The scheduler calls this once before scheduling, and again on
  /// any dynamic config change.
  void setConfig(AtCompactionConfig config);

  /// Run a single compaction pass and return the metrics.
  Future<AtCompactionStats> compact();
}

/// [AtCompactionStrategy] over an [AtLogType] that exposes the
/// `getKeysToDeleteOnCompaction` / `deleteKeyForCompaction` pair
/// (i.e. every Hive-backed concrete in this package). Used by
/// [HiveAtPersistenceFactory] to populate the bundle's compactor
/// fields.
class HiveCompactionStrategy implements AtCompactionStrategy {
  final AtLogType _atLogType;

  HiveCompactionStrategy(this._atLogType);

  @override
  void setConfig(AtCompactionConfig config) {
    _atLogType.setCompactionConfig(config);
  }

  @override
  Future<AtCompactionStats> compact() async {
    final preCount = _atLogType.entriesCount();
    final preMillis = DateTime.now().toUtc().millisecondsSinceEpoch;
    final keysToDelete = await _atLogType.getKeysToDeleteOnCompaction();
    await _atLogType.deleteKeyForCompaction(keysToDelete);
    final postMillis = DateTime.now().toUtc().millisecondsSinceEpoch;
    final postCount = _atLogType.entriesCount();
    return AtCompactionStats()
      ..preCompactionEntriesCount = preCount
      ..postCompactionEntriesCount = postCount
      ..compactionDurationInMills = postMillis - preMillis
      ..deletedKeysCount = preCount - postCount
      ..lastCompactionRun = DateTime.now().toUtc()
      ..atCompactionType = _atLogType.toString();
  }
}
