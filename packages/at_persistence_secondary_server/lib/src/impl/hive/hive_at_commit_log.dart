import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utf7/at_utf7.dart';
import 'package:at_utils/at_logger.dart';
import 'package:hive/hive.dart';

import 'hive_commit_log_keystore.dart';

/// Hive-backed implementation of [AtCommitLog] for the server side.
@server
class HiveAtCommitLog extends AtCommitLog {
  var logger = AtSignLogger('HiveAtCommitLog');

  late HiveCommitLogKeyStore _commitLogKeyStore;

  /// Per-pass percentage of entries to drop when compaction is
  /// invoked. Captured from `AtSecondaryConfig` at factory time;
  /// immutable per instance.
  final int compactionPercentage;

  HiveCommitLogKeyStore get commitLogKeyStore => _commitLogKeyStore;

  HiveAtCommitLog(HiveCommitLogKeyStore keyValueStore,
      {this.compactionPercentage = 30}) {
    _commitLogKeyStore = keyValueStore;
  }

  /// Creates a new entry with key, operation and adds to the commit log with key - commitId and value - [CommitEntry]
  /// returns the sequence number corresponding to the new commit
  /// throws [DataStoreException] if there is an exception writing to hive box
  @override
  @server
  Future<int?> commit(String key, CommitOp operation) async {
    // If key starts with "public:__", it is a public hidden key which gets synced
    // between cloud and local secondary. So increment commitId.
    // If key starts with "public:_" it is a public hidden key but does not get synced.
    // So return -1.
    // The private: and privatekey: are not synced. so return -1.
    // The key that starts with 'local:' are the local keys that do not sync between the
    // client and server. Hence do not add to commit log.
    if (!key.startsWith('public:__') &&
        (key.startsWith(RegExp('private:|privatekey:|public:_|local:')))) {
      return -1;
    }
    int result;
    key = Utf7.decode(key);
    var entry = CommitEntry(
        key, operation, DateTime.now().toUtcMillisecondsPrecision());
    try {
      result = await _commitLogKeyStore.add(entry);
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception adding to commit log:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to commit log:${e.toString()}');
    }
    return result;
  }

  @override
  Future<void> replay(CommitEntry entry) async {
    if (entry.commitId == null) {
      throw ArgumentError('replay requires a non-null commitId on the entry');
    }
    try {
      await _commitLogKeyStore.getBox().put(entry.commitId, entry);
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception replaying commit entry: ${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error replaying commit entry: ${e.toString()}');
    }
  }

  @override
  Stream<CommitEntry> iterate({
    int? fromCommitId,
    bool Function(CommitEntry)? where,
  }) {
    return _commitLogKeyStore.iterate(fromCommitId: fromCommitId, where: where);
  }

  /// Returns the latest committed sequence number
  @override
  @server
  int? lastCommittedSequenceNumber() {
    return _commitLogKeyStore.latestCommitId;
  }

  /// Returns the total number of keys
  /// @return - int : Returns number of keys in access log
  @override
  int entriesCount() {
    return _commitLogKeyStore.entriesCount();
  }

  @override
  @server
  int getSize() {
    return _commitLogKeyStore.getSize();
  }

  /// Returns the latest commitEntry of the key.
  @override
  @server
  CommitEntry? getLatestCommitEntry(String key) {
    return _commitLogKeyStore.getLatestCommitEntry(key);
  }

  /// Closes the [HiveServerCommitLogKeyStore] instance.
  @override
  @server
  Future<void> close() async {
    await _commitLogKeyStore.close();
  }

  /// Compact the commit log. The Hive impl prunes duplicate entries
  /// (same atKey, older commitId) — the same algorithm
  /// `HiveCompactionStrategy` used to drive externally.
  @override
  Stream<int> compact(bool dryRun) async* {
    final List<int> keysToDelete =
        await _commitLogKeyStore.getDuplicateEntries();
    if (dryRun) {
      for (final id in keysToDelete) {
        yield id;
      }
      return;
    }
    try {
      await _commitLogKeyStore.removeAll(keysToDelete);
    } on Exception catch (e) {
      throw DataStoreException(
          'DataStoreException while deleting for compaction:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error while deleting for compaction:${e.toString()}');
    }
    for (final id in keysToDelete) {
      yield id;
    }
  }

  @override
  String toString() {
    return runtimeType.toString();
  }
}
