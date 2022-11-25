import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_base.dart';
import 'package:at_utils/at_utils.dart';
import 'package:hive/hive.dart';

/// An In-Memory data store backed by [Hive] to maintain the [AtCommitLog]
///
/// An abstract class that is responsible to initialize the KeyStore.
///
/// Contains the methods to perform CRUD operations on the CommitLog and methods
/// that are common between the Client and Server.
abstract class CommitLogKeyStore
    with HiveBase<CommitEntry?>
    implements LogKeyStore<int, CommitEntry?> {
  final _logger = AtSignLogger('CommitLogKeyStore');
  bool enableCommitId = true;
  final String _currentAtSign;
  late String _boxName;

  CommitLogKeyStore(this._currentAtSign);

  @override
  Future<void> initialize() async {
    _boxName = 'commit_log_${AtUtils.getShaForAtSign(_currentAtSign)}';
    if (!Hive.isAdapterRegistered(CommitEntryAdapter().typeId)) {
      Hive.registerAdapter(CommitEntryAdapter());
    }
    if (!Hive.isAdapterRegistered(CommitOpAdapter().typeId)) {
      Hive.registerAdapter(CommitOpAdapter());
    }
    await super.openBox(_boxName);
    var lastCommittedSequenceNum = lastCommittedSequenceNumber();
    _logger.finer('last committed sequence: $lastCommittedSequenceNum');
  }

  @override
  Future<CommitEntry?> get(int commitId) async {
    try {
      var commitEntry = await getValue(commitId);
      return commitEntry;
    } on Exception catch (e) {
      throw DataStoreException('Exception get entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error getting entry from commit log:${e.toString()}');
    }
  }

  @override
  Future<int> add(CommitEntry? commitEntry) async {
    int internalKey;
    try {
      internalKey = await super.getBox().add(commitEntry);
    } on Exception catch (e) {
      throw DataStoreException('Exception updating entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error updating entry to commit log:${e.toString()}');
    }
    return internalKey;
  }

  @override
  Future<void> update(int commitId, CommitEntry? commitEntry) async {
    try {
      commitEntry?.commitId = commitId;
      await super.getBox().put(commitEntry?.key, commitEntry);
    } on Exception catch (e) {
      throw DataStoreException('Exception updating entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error updating entry to commit log:${e.toString()}');
    }
  }

  /// Remove
  @override
  Future<void> remove(int commitId) async {
    try {
      await super.getBox().delete(commitId);
    } on Exception catch (e) {
      throw DataStoreException('Exception deleting entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error deleting entry from commit log:${e.toString()}');
    }
  }

  /// Returns the latest committed sequence number
  int? lastCommittedSequenceNumber() {
    var lastCommittedSequenceNum =
        super.getBox().keys.isNotEmpty ? super.getBox().keys.last : null;
    return lastCommittedSequenceNum;
  }

  /// Returns the first committed sequence number
  /// ToDo Not in use. Can remove code?
  // int? firstCommittedSequenceNumber() {
  //   var firstCommittedSequenceNum =
  //       super.getBox().keys.isNotEmpty ? super.getBox().keys.first : null;
  //   return firstCommittedSequenceNum;
  // }

  /// Returns the total number of keys
  /// @return - int : Returns number of keys in access log
  @override
  int entriesCount() {
    int? totalKeys = 0;
    totalKeys = super.getBox().keys.length;
    return totalKeys;
  }

  /// Gets the first 'N' keys from the logs
  /// @param - N : The integer to get the first 'N'
  /// @return List of first 'N' keys from the log
  @override
  List getFirstNEntries(int N) {
    var entries = [];
    try {
      entries = super.getBox().keys.toList().take(N).toList();
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
    if (expiredKeys.isNotEmpty) {
      await super.getBox().deleteAll(expiredKeys);
    }
  }

  bool acceptKey(String atKey, String regex) {
    return _isRegexMatches(atKey, regex) || _isSpecialKey(atKey);
  }

  bool _isRegexMatches(String atKey, String regex) {
    return RegExp(regex).hasMatch(atKey);
  }

  bool _isSpecialKey(String atKey) {
    return atKey.contains(AT_ENCRYPTION_SHARED_KEY) ||
        atKey.startsWith('public:') ||
        atKey.contains(AT_PKAM_SIGNATURE) ||
        atKey.contains(AT_SIGNING_PRIVATE_KEY);
  }

  ///Returns the key-value pair of commit-log where key is hive internal key and
  ///value is [CommitEntry]
  Future<Map<int, CommitEntry>> toMap() async {
    var commitLogMap = <int, CommitEntry>{};
    var keys = super.getBox().keys;

    await Future.forEach(keys, (key) async {
      var value = await getValue(key) as CommitEntry;
      commitLogMap.putIfAbsent(key as int, () => value);
    });
    return commitLogMap;
  }

  ///Returns the total number of keys in commit log keystore.
  int getEntriesCount() {
    return super.getBox().length;
  }
}
