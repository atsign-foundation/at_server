import 'package:at_persistence_secondary_server/src/log/commitlog/commit_entry.dart';
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
  Future<int?> commit(String key, CommitOp operation);

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
  /// After 3.5a's dedup invariant, the box has at most one entry
  /// per atKey, so a full-log walk yields one entry per atKey
  /// in commit-id order.
  Stream<CommitEntry> iterate({
    int? fromCommitId,
    bool Function(CommitEntry)? where,
  });

  /// Latest assigned `commitId`, or `null` if the log is empty.
  int? lastCommittedSequenceNumber();

  /// Earliest assigned `commitId`.
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
  /// The Hive impl drops the oldest configured percentage of
  /// entries; SQL backends will do a `DELETE WHERE` (and possibly
  /// `VACUUM`) instead.
  @override
  Stream<int> compact(bool dryRun);

  // ----- Client-flavour members (default-throwing) -----
  //
  // The client-side commit log differs from the server-side one in
  // a few methods (commitId is assigned by the server and replayed
  // locally, not auto-incremented). These methods throw by default;
  // the client-flavour Hive impl overrides them.

  Future<CommitEntry?> lastSyncedEntry() async {
    throw UnimplementedError();
  }

  Future<CommitEntry?> lastSyncedEntryWithRegex(String regex) async {
    throw UnimplementedError();
  }

  Future<CommitEntry?> getEntry(int? sequenceNumber) async {
    throw UnimplementedError();
  }

  Future<void> update(CommitEntry commitEntry, int commitId) async {
    throw UnimplementedError();
  }

  Future<List<CommitEntry>> getChanges(int? sequenceNumber, String? regex,
      {int? limit}) async {
    throw UnimplementedError();
  }
}
