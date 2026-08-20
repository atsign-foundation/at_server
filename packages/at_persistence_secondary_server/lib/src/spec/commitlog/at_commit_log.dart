import 'package:at_persistence_secondary_server/src/spec/spec.dart';

/// Abstract contract for a commit log: an append-style record of
/// `(atKey, op)` tuples keyed by a monotonically-increasing
/// `commitId`. The Hive-backed implementation is [HiveAtCommitLog];
/// future backends (e.g. SQLite, Postgres) provide their own.
///
/// This interface intentionally does NOT expose the underlying
/// keystore handle (Hive-specific). Backend-aware operations
/// (e.g. compaction) are exposed via [compact] on the [Compactable]
/// contract.
abstract class AtCommitLog implements Compactable {
  /// Append a new entry for [key] / [operation]. Returns the
  /// assigned `commitId`, or `-1` for keys that bypass the commit
  /// log (`private:`, `privatekey:`, `public:_`, `local:`, ...).
  ///
  /// [opTime] is the operation time recorded on the entry: pass a
  /// caller-asserted time (a delete's `deletedAt`, an update's
  /// asserted `updatedAt`) when the protocol supplied one; when
  /// null, now. Truncated to millisecond precision. Informational —
  /// entry ordering is by `commitId`, never by `opTime`.
  Future<int?> commit(String key, CommitOp operation, {DateTime? opTime});

  /// Remove the commit entry for [key], if one exists. The log
  /// holds at most one entry per atKey, so at most one entry is
  /// removed; removing none is not an error. Used by the
  /// skipCommit write paths: a write that must leave no commit
  /// entry also scrubs the key's previous entry, otherwise sync
  /// would keep serving a stale entry for a record whose latest
  /// change was deliberately uncommitted.
  ///
  /// [key] takes the same form that [commit] accepts on the same
  /// backend.
  Future<void> removeEntryFor(String key);

  /// Replay [entry] under its existing `commitId` WITHOUT firing
  /// change-event listeners. Used by the persistence migrator to
  /// copy commit-log content from one backend to another while
  /// preserving sync identity. Idempotent on
  /// `(commitId, atKey, operation)`.
  Future<void> replay(CommitEntry entry);

  /// Iterate every commit entry in `commitId` order. If
  /// [fromCommitId] is provided, yields only entries with
  /// `commitId >= fromCommitId`. If [where] is provided, only
  /// entries for which `where(entry)` returns true are yielded;
  /// the rest are silently skipped. Used by sync, by migration,
  /// and by anything that needs full-log traversal.
  ///
  /// [skipDeletesUntil] pushes sync's "skip deletes" policy into the
  /// query so DELETE entries the client does not need are never
  /// materialised: when set, a DELETE entry whose `commitId <=
  /// skipDeletesUntil` is not yielded — EXCEPT the entry whose
  /// `commitId == [latestCommitId]`, which is always yielded so the
  /// client can still advance its watermark. Applied before [where].
  /// Backends that can (SQLite) filter these rows in the query itself
  /// rather than reading and discarding them.
  ///
  /// After 3.5a's dedup invariant, the box has at most one entry
  /// per atKey, so a full-log walk yields one entry per atKey
  /// in commit-id order.
  Stream<CommitEntry> iterate({
    int? fromCommitId,
    bool Function(CommitEntry)? where,
    int? skipDeletesUntil,
    int? latestCommitId,
  });

  /// Latest assigned `commitId`, or `null` if the log is empty.
  int? lastCommittedSequenceNumber();

  /// Smallest `commitId` still retained in the log, or `null` if
  /// the log is empty. Pairs with [lastCommittedSequenceNumber] to
  /// expose the log's `[floor, ceiling]` to sync clients.
  ///
  /// MUST return the smallest commitId still present in the
  /// underlying log (not a cached approximation). The value never
  /// decreases over time: entries leave the log only via update
  /// dedup and compaction, both of which can only raise the floor.
  ///
  /// A sync client whose own commit state is below the floor cannot
  /// be incrementally caught up — the server no longer retains the
  /// entries the client would need — and must full-sync instead.
  ///
  /// O(1) on every backend in this package.
  int? firstCommittedSequenceNumber();

  /// The latest [CommitEntry] for [key], or `null` if [key] has
  /// never been committed.
  CommitEntry? getLatestCommitEntry(String key);

  /// Total entry count. Used by operators / metrics; not on any
  /// hot path.
  int entriesCount();

  /// Approximate on-disk size in bytes.
  int getSize();

  /// Close the underlying storage handle.
  Future<void> close();

  /// Compact the commit log. If [dryRun] is `true`, yields each
  /// commit-id that WOULD be removed without performing the
  /// deletion. If `false`, performs the compaction and yields each
  /// commit-id as it is removed.
  ///
  /// The Hive impl prunes duplicate entries — same atKey, older
  /// commitId. Under the one-entry-per-atKey invariant (enforced
  /// inline on commit and by the startup dedup migration) that set
  /// is empty in practice, so this is a legacy-data safety net.
  /// SQL backends will do a `DELETE WHERE` (and possibly `VACUUM`)
  /// instead.
  @override
  Stream<int> compact(bool dryRun);
}
