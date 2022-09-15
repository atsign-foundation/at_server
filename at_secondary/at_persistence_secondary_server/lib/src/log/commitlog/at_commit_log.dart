import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/event_listener/at_change_event.dart';
import 'package:at_persistence_secondary_server/src/event_listener/at_change_event_listener.dart';
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
  @server
  Future<int?> commit(String key, CommitOp operation) async {
    // If key starts with "public:__", it is a public hidden key which gets synced
    // between cloud and local secondary. So increment commitId.
    // If key starts with "public:_" it is a public hidden key but does not get synced.
    // So return -1.
    // The private: and privatekey: are not synced. so return -1.
    if (!key.startsWith('public:__') &&
        (key.startsWith(RegExp(
                'private:|privatekey:|public:_|public:signing_publickey')) ||
            key.startsWith(RegExp(
                '@(?<sharedWith>.*):signing_privatekey@(?<sharedBy>.*)')))) {
      return -1;
    }
    int result;
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
  @client
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
    Future<List<CommitEntry>> changes;
    try {
      changes = _commitLogKeyStore.getChanges(sequenceNumber!,
          regex: regex, limit: limit);
    } on Exception catch (e) {
      throw DataStoreException('Exception getting changes:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to commit log:${e.toString()}');
    }
    // ignore: unnecessary_null_comparison
    if (changes == null) {
      return [];
    }
    return changes;
  }

  @client
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
  @server
  Future<List> getExpired(int expiryInDays) {
    return _commitLogKeyStore.getExpired(expiryInDays);
  }

  /// Returns the latest committed sequence number
  @server
  int? lastCommittedSequenceNumber() {
    return _commitLogKeyStore.latestCommitId;
  }

  /// Returns the latest committed sequence number with regex
  @server
  Future<int?> lastCommittedSequenceNumberWithRegex(String regex) async {
    return await _commitLogKeyStore.lastCommittedSequenceNumberWithRegex(regex);
  }

  @client
  Future<CommitEntry?> lastSyncedEntry() async {
    return await _commitLogKeyStore.lastSyncedEntry();
  }

  @client
  Future<CommitEntry?> lastSyncedEntryWithRegex(String regex) async {
    return await _commitLogKeyStore.lastSyncedEntry(regex: regex);
  }

  /// Returns the first committed sequence number
  @server
  int? firstCommittedSequenceNumber() {
    return _commitLogKeyStore.firstCommittedSequenceNumber();
  }

  /// Returns the total number of keys
  /// @return - int : Returns number of keys in access log
  @override
  @server
  int entriesCount() {
    return _commitLogKeyStore.entriesCount();
  }

  /// Gets the first 'N' keys from the logs
  /// @param - N : The integer to get the first 'N'
  /// @return List of first 'N' keys from the log
  @override
  @server
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
  @server
  Future<void> delete(dynamic expiredKeys) async {
    await _commitLogKeyStore.delete(expiredKeys);
  }

  @override
  @server
  int getSize() {
    return _commitLogKeyStore.getSize();
  }

  /// Returns the latest commitEntry of the key.
  @server
  CommitEntry? getLatestCommitEntry(String key) {
    return _commitLogKeyStore.getLatestCommitEntry(key);
  }

  /// Closes the [CommitLogKeyStore] instance.
  @server
  Future<void> close() async {
    await _commitLogKeyStore.close();
  }

  /// Returns the Iterator of [_commitLogCacheMap] from the commitId specified.
  @server
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
