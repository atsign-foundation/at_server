import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/event_listener/at_change_event.dart';
import 'package:at_persistence_secondary_server/src/event_listener/at_change_event_listener.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/commit_entry.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/commit_log_keystore.dart';
import 'package:at_utf7/at_utf7.dart';
import 'package:at_utils/at_logger.dart';
import 'package:hive/hive.dart';

/// Class to main commit logs on the secondary server for create, update and remove operations on keys
class AtCommitLog implements AtLogType {
  var logger = AtSignLogger('AtCommitLog');

  late final List<AtChangeEventListener> _atChangeEventListener = [];

  late CommitLogKeyStore _commitLogKeyStore;

  CommitLogKeyStore get commitLogKeyStore => _commitLogKeyStore;

  AtCommitLog(CommitLogKeyStore keyStore) {
    _commitLogKeyStore = keyStore;
  }

  /// Creates a new entry with key, operation and adds to the commit log with key - commitId and value - [CommitEntry]
  /// returns the sequence number corresponding to the new commit
  /// throws [DataStoreException] if there is an exception writing to hive box
  @client
  Future<int?> commit(String key, CommitOp operation) async {
    if (key.startsWith(RegExp('private:|privatekey:|public:_'))) {
      // do not add private key and keys with public_ to commit log.
      return -1;
    }
    var result;
    key = Utf7.decode(key);
    var entry = CommitEntry(key, operation, DateTime.now().toUtc());
    try {
      result = await _commitLogKeyStore.add(entry);
      await _publishChangeEvent(entry);
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception adding to commit log:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to commit log:${e.toString()}');
    }
    return result;
  }

  /// Returns the commit entry for a given commit sequence number
  /// throws [DataStoreException] if there is an exception getting the commit entry
  Future<CommitEntry?> getEntry(int? sequenceNumber) async {
    try {
      var commitEntry = await _commitLogKeyStore.get(sequenceNumber!);
      return commitEntry;
    } on Exception catch (e) {
      throw DataStoreException('Exception getting entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to commit log:${e.toString()}');
    }
  }

  /// Returns the list of commit entries greater than [sequenceNumber]
  /// throws [DataStoreException] if there is an exception getting the commit entries
  Future<List<CommitEntry>> getChanges(int? sequenceNumber, String? regex,
      {int? limit}) async {
    var changes;
    try {
      changes = _commitLogKeyStore.getChanges(sequenceNumber!,
          regex: regex, limit: limit);
    } on Exception catch (e) {
      throw DataStoreException('Exception getting changes:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to commit log:${e.toString()}');
    }
    if (changes == null) {
      return [];
    }
    return changes;
  }

  Future<void> update(CommitEntry commitEntry, int commitId) async {
    try {
      await _commitLogKeyStore.update(commitId, commitEntry);
    } on Exception catch (e) {
      throw DataStoreException('Exception updating entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error updating entry to commit log:${e.toString()}');
    }
  }

  @override
  Future<List> getExpired(int expiryInDays) {
    return _commitLogKeyStore.getExpired(expiryInDays);
  }

  /// Returns the latest committed sequence number
  int? lastCommittedSequenceNumber() {
    return _commitLogKeyStore.latestCommitId;
  }

  /// Returns the latest committed sequence number with regex
  Future<int?> lastCommittedSequenceNumberWithRegex(String regex) async {
    return await _commitLogKeyStore.lastCommittedSequenceNumberWithRegex(regex);
  }

  Future<CommitEntry?> lastSyncedEntry() async {
    return await _commitLogKeyStore.lastSyncedEntry();
  }

  Future<CommitEntry?> lastSyncedEntryWithRegex(String regex) async {
    return await _commitLogKeyStore.lastSyncedEntry(regex: regex);
  }

  /// Returns the first committed sequence number
  int? firstCommittedSequenceNumber() {
    return _commitLogKeyStore.firstCommittedSequenceNumber();
  }

  /// Returns the total number of keys
  /// @return - int : Returns number of keys in access log
  @override
  int entriesCount() {
    return _commitLogKeyStore.entriesCount();
  }

  /// Gets the first 'N' keys from the logs
  /// @param - N : The integer to get the first 'N'
  /// @return List of first 'N' keys from the log
  @override
  Future<List> getFirstNEntries(int N) async {
    List<dynamic>? entries = [];
    try {
      entries = await _commitLogKeyStore.getDuplicateEntries();
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception getting first N entries:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to access log:${e.toString()}');
    }
    return entries;
  }

  /// Removes the expired keys from the log.
  /// @param - expiredKeys : The expired keys to remove
  @override
  Future<void> delete(dynamic expiredKeys) async {
    await _commitLogKeyStore.delete(expiredKeys);
  }

  @override
  int getSize() {
    return _commitLogKeyStore.getSize();
  }

  /// Returns the latest commitEntry of the key.
  CommitEntry? getLatestCommitEntry(String key) {
    return _commitLogKeyStore.getLatestCommitEntry(key);
  }

  /// Closes the [CommitLogKeyStore] instance.
  Future<void> close() async {
    await _commitLogKeyStore.close();
  }

  /// Returns the Iterator of [_commitLogCacheMap] from the commitId specified.
  Iterator getEntries(int commitId, {String? regex}) {
    // If regex is null or isEmpty set regex to match all keys
    if (regex == null || regex.isEmpty) {
      regex = '.*';
    }
    return _commitLogKeyStore.getEntries(commitId, regex: regex);
  }

  Future<void> _publishChangeEvent(CommitEntry commitEntry) async {
    try {
      for (var listener in _atChangeEventListener) {
        await listener.listen(AtPersistenceChangeEvent.from(commitEntry.atKey,
            value: commitEntry.commitId,
            commitOp: commitEntry.operation!,
            keyStoreType: KeyStoreType.commitLogKeyStore));
      }
    } on Exception catch (e) {
      logger.info('Failed to publish change event ${e.toString()}');
    } on Error catch (err) {
      logger.info('Failed to publish change event ${err.toString()}');
    }
  }

  /// Adds the class implementing the [AtChangeEventListener] to publish the [AtPersistenceChangeEvent]
  void addEventListener(AtChangeEventListener atChangeEventListener) {
    _atChangeEventListener.add(atChangeEventListener);
  }

  /// Removes the [AtChangeEventListener]
  void removeEventListener(AtChangeEventListener atChangeEventListener) {
    _atChangeEventListener.remove(atChangeEventListener);
  }
}
