import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/commit_entry.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/commit_log_keystore.dart';
import 'package:at_utils/at_logger.dart';
import 'package:hive/hive.dart';
import 'package:utf7/utf7.dart';

/// Class to main commit logs on the secondary server for create, update and remove operations on keys
class AtCommitLog implements AtLogType {
  var logger = AtSignLogger('AtCommitLog');

  var _commitLogKeyStore;

  AtCommitLog(LogKeyStore keyStore) {
    _commitLogKeyStore = keyStore;
  }

  /// Creates a new entry with key, operation and adds to the commit log with key - commitId and value - [CommitEntry]
  /// returns the sequence number corresponding to the new commit
  /// throws [DataStoreException] if there is an exception writing to hive box
  Future<int> commit(String key, CommitOp operation) async {
    if (key.startsWith(RegExp('private:|privatekey:|public:_'))) {
      // do not add private key and keys with public_ to commit log.
      return -1;
    }
    var result;
    key = Utf7.decode(key);
    var entry = CommitEntry(key, operation, DateTime.now().toUtc());
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

  /// Returns the commit entry for a given commit sequence number
  /// throws [DataStoreException] if there is an exception getting the commit entry
  Future<CommitEntry> getEntry(int sequenceNumber) async {
    try {
      var commitEntry = await _commitLogKeyStore.get(sequenceNumber);
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
  Future<List<CommitEntry>> getChanges(int sequenceNumber, String regex) async {
    var changes = <CommitEntry>[];
    try {
      changes =
          await _commitLogKeyStore.getChanges(sequenceNumber, regex: regex);
    } on Exception catch (e) {
      throw DataStoreException('Exception getting changes:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to commit log:${e.toString()}');
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
  Future<List<dynamic>> getExpired(int expiryInDays) async{
    return await _commitLogKeyStore.getExpired(expiryInDays);
  }

  /// Returns the latest committed sequence number
  Future<int> lastCommittedSequenceNumber() async {
    return await _commitLogKeyStore.lastCommittedSequenceNumber();
  }

  /// Returns the latest committed sequence number with regex
  Future<int> lastCommittedSequenceNumberWithRegex(String regex) async {
    return await _commitLogKeyStore.lastCommittedSequenceNumberWithRegex(regex);
  }

  CommitEntry lastSyncedEntry() {
    return _commitLogKeyStore.lastSyncedEntry();
  }

  CommitEntry lastSyncedEntryWithRegex(String regex) {
    return _commitLogKeyStore.lastSyncedEntry(regex: regex);
  }

  /// Returns the first committed sequence number
  int firstCommittedSequenceNumber() {
    return _commitLogKeyStore.firstCommittedSequenceNumber();
  }

  /// Returns the total number of keys
  /// @return - int : Returns number of keys in access log
  @override
  Future<int> entriesCount() {
    return _commitLogKeyStore.entriesCount();
  }

  /// Gets the first 'N' keys from the logs
  /// @param - N : The integer to get the first 'N'
  /// @return List of first 'N' keys from the log
  @override
  Future<List> getFirstNEntries(int N) async {
    var entries = [];
    try {
      entries = await _commitLogKeyStore.getFirstNEntries(N);
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception getting first N entries:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to access log:${e.toString()}');
    }
    return entries;
  }

  @override
  Future<int> getSize() async {
    return await _commitLogKeyStore.getSize();
  }

  /// Closes the [CommitLogKeyStore] instance.
  Future<void> close() async {
    await _commitLogKeyStore.close();
  }

  @override
  Future<void> remove(expiredKeys) async {
    await Future.forEach(expiredKeys, (key) async {
      await _commitLogKeyStore.remove(key);
    });
  }
}
