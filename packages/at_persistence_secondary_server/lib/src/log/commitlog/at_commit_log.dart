import 'package:at_persistence_secondary_server/src/event_listener/at_change_event_listener.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/commit_entry.dart';
import 'package:at_persistence_secondary_server/src/spec/spec.dart';

/// Abstract contract for a commit log: an append-style record of
/// `(atKey, op)` tuples keyed by a monotonically-increasing
/// `commitId`. The Hive-backed implementation is [HiveAtCommitLog];
/// future backends (e.g. SQLite, Postgres) provide their own.
///
/// This interface intentionally does NOT expose the underlying
/// keystore handle (Hive-specific). Backend-aware operations
/// (compaction, on-disk maintenance) reach the impl via the
/// bundle's compactor field, not via this interface.
abstract class AtCommitLog implements AtLogType<int, CommitEntry> {
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

  /// Latest `commitId` whose `atKey` matches [regex] and whose
  /// namespace is in [enrolledNamespace] (if provided).
  Future<int?> lastCommittedSequenceNumberWithRegex(String regex,
      {List<String>? enrolledNamespace});

  /// Earliest assigned `commitId`.
  int? firstCommittedSequenceNumber();

  /// The latest [CommitEntry] for [key], or `null` if [key] has
  /// never been committed.
  CommitEntry? getLatestCommitEntry(String key);

  /// Close the underlying storage handle.
  Future<void> close();

  /// Subscribe / unsubscribe to commit-log change events.
  void addEventListener(AtChangeEventListener listener);
  void removeEventListener(AtChangeEventListener listener);

  /// Set the compaction config governing automatic pruning.
  @override
  void setCompactionConfig(AtCompactionConfig atCompactionConfig);

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
