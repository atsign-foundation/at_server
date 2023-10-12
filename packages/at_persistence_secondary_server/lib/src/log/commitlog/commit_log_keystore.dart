import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_base.dart';
import 'package:at_persistence_secondary_server/src/metadata_keystore/atkey_server_metadata.dart';
import 'package:at_utils/at_utils.dart';
import 'package:hive/hive.dart';
import 'package:meta/meta.dart';
import 'package:mutex/mutex.dart';

@server
class CommitLogKeyStore extends BaseCommitLogKeyStore {
  final _logger = AtSignLogger('CommitLogKeyStore');

  late AtKeyMetadataStore atKeyMetadataStore;

  final Mutex _commitMutex = Mutex();

  int get latestCommitId {
    if ((getBox() as Box).isEmpty) {
      return -1;
    }
    return (getBox() as Box).getAt(getBox().length - 1).commitId;
  }

  CommitLogKeyStore(String currentAtSign) : super(currentAtSign);

  @override
  Future<void> initialize() async {
    _boxName = 'commit_log_${AtUtils.getShaForAtSign(currentAtSign)}';
    if (!Hive.isAdapterRegistered(CommitEntryAdapter().typeId)) {
      Hive.registerAdapter(CommitEntryAdapter());
    }
    if (!Hive.isAdapterRegistered(CommitOpAdapter().typeId)) {
      Hive.registerAdapter(CommitOpAdapter());
    }
    await super.openBox(_boxName);
    _logger.finer('Commit log key store is initialized');

    //await repairCommitLogAndCreateCachedMap();
  }

  Future<int> commitChange(CommitEntry commitEntry) async {
    try {
      _commitMutex.acquire();
      // 1. Delete previous entry
      if (atKeyMetadataStore.contains(commitEntry.atKey)) {
        AtKeyServerMetadata atKeyServerMetadata =
            await atKeyMetadataStore.get(commitEntry.atKey);
        await getBox().delete(atKeyServerMetadata.commitId);
      }
      // 2. Add entry into commit log
      int commitId = await add(commitEntry);
      // 3. Update the commitId to Metadata persistent store.
      atKeyMetadataStore.put(
          commitEntry.atKey, AtKeyServerMetadata()..commitId = commitId);
      // 4. Update the commit-Id to the commit log.
      // 4.a Set the hive generated key as commit id
      commitEntry.commitId = commitId;
      // 4.2 Update entry with commitId
      await getBox().put(commitId, commitEntry);
      return commitId;
    } finally {
      _commitMutex.release();
    }
  }

  Future<int> add(CommitEntry? commitEntry, {int previousCommitId = -1}) async {
    int internalKey;
    try {
      internalKey = await getBox().add(commitEntry!);
    } on Exception catch (e) {
      throw DataStoreException('Exception updating entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error updating entry to commit log:${e.toString()}');
    }
    return internalKey;
  }

  /// Returns the latest committed sequence number with regex
  Future<int?> lastCommittedSequenceNumberWithRegex(String regex) async {
    var lastCommittedEntry = (getBox() as Box).values.lastWhere(
        (entry) => (_acceptKey(entry.atKey, regex)),
        orElse: () => NullCommitEntry());
    var lastCommittedSequenceNum =
        (lastCommittedEntry != null) ? lastCommittedEntry.key : null;
    return lastCommittedSequenceNum;
  }

  /// Sorts the [CommitEntry]'s order by commit in descending order
  int _sortByCommitId(dynamic c1, dynamic c2) {
    if (c1.commitId == null && c2.commitId == null) {
      return 0;
    }
    if (c1.commitId != null && c2.commitId == null) {
      return 1;
    }
    if (c1.commitId == null && c2.commitId != null) {
      return -1;
    }
    return c1.commitId.compareTo(c2.commitId);
  }

  /// Returns the first committed sequence number
  int? firstCommittedSequenceNumber() {
    var firstCommittedSequenceNum =
        getBox().keys.isNotEmpty ? getBox().keys.first : null;
    return firstCommittedSequenceNum;
  }

  /// Returns the total number of keys
  /// @return - int : Returns number of keys in access log
  int entriesCount() {
    int? totalKeys = 0;
    totalKeys = getBox().keys.length;
    return totalKeys;
  }

  /// Gets the first 'N' keys from the logs
  /// @param - N : The integer to get the first 'N'
  /// @return List of first 'N' keys from the log
  List getFirstNEntries(int N) {
    var entries = [];
    try {
      entries = getBox().keys.toList().take(N).toList();
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
  Future<void> remove(int commitEntryIndex) async {
    CommitEntry? commitEntry = (getBox() as Box).get(commitEntryIndex);
    if (commitEntry != null) {
      await atKeyMetadataStore.put(commitEntry.atKey,
          AtKeyServerMetadata()..commitId = commitEntryIndex);
    }
    await super.remove(commitEntryIndex);
  }

  Future<void> removeAll(List<int> deleteKeysList) async {
    if (deleteKeysList.isEmpty) {
      return;
    }
    await getBox().deleteAll(deleteKeysList);
  }

  Future<List<int>> getExpired(int expiryInDays) async {
    var expiredKeys = <int>[];
    var now = DateTime.now().toUtc();
    var commitLogMap = await toMap();
    commitLogMap.forEach((key, value) {
      if (value.opTime != null &&
          value.opTime!.isBefore(now.subtract(Duration(days: expiryInDays)))) {
        expiredKeys.add(key);
      }
    });
    return expiredKeys;
  }

  Future<List<int>> getDuplicateEntries() async {
    var commitLogMap = await toMap();

    // When fetching the duplicates entries for compaction, ignore the values
    // with commit-Id not equal to null.
    // On the client side, the entries with commit null indicates the entries have to
    // be synced to cloud secondary and should not be deleted. Hence removing the keys from
    // commitLogMap.
    commitLogMap.removeWhere((key, value) => value.commitId == null);
    var sortedKeys = commitLogMap.keys.toList(growable: false)
      ..sort((k1, k2) => _sortByCommitId(commitLogMap[k2], commitLogMap[k1]));
    var tempSet = <String>{};
    var expiredKeys = <int>[];
    for (var entry in sortedKeys) {
      _processEntry(entry, tempSet, expiredKeys, commitLogMap);
    }
    return expiredKeys;
  }

  void _processEntry(entry, tempSet, expiredKeys, commitLogMap) {
    var isKeyLatest = tempSet.add(commitLogMap[entry].atKey);
    if (!isKeyLatest) {
      expiredKeys.add(entry);
    }
  }

  bool _acceptKey(String atKey, String regex) {
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

  /// Returns the latest commitEntry of the key.
  Future<CommitEntry?> getLatestCommitEntry(String key) async {
    AtKeyServerMetadata atKeyServerMetadata = await atKeyMetadataStore.get(key);
    int commitId = atKeyServerMetadata.commitId;
    int start = 0;
    int end = getBox().length;
    while (start <= end) {
      var midIndex = (start + end) ~/ 2;
      CommitEntry commitEntry = (getBox() as Box).getAt(midIndex);
      if (commitEntry.commitId == commitId) {
        return commitEntry;
      }

      if (commitEntry.commitId! <= commitId) {
        start = midIndex + 1;
      } else {
        end = midIndex - 1;
      }
    }
    return null;
  }

  /// Returns the Iterator of entries as Key value pairs after the given the [commitId] for the keys that matches the [regex]
  Iterator<MapEntry<String, CommitEntry>> getEntries(int commitId,
      {String regex = '.*', int limit = 25}) {
    // When commitId is -1, it means a full sync. So return all the entries from the start.
    // Set start to 0
    // If commitId is not 0, it means to send keys from the given commitId
    // Using binary search approach, find the index and set start to the index.
    int startIndex = 0;
    int endIndex = (getBox().length - 1);
    while (startIndex <= endIndex) {
      var midIndex = (startIndex + endIndex) ~/ 2;
      CommitEntry commitEntry = (getBox() as Box).getAt(midIndex);
      if (commitId == commitEntry.commitId) {
        startIndex = midIndex;
        break;
      } else if (commitEntry.commitId! < commitId) {
        startIndex = midIndex + 1;
      } else {
        endIndex = midIndex - 1;
      }
    }

    // Fetch the sync entries
    limit = (getBox().length < limit) ? getBox().length : limit;
    Map<String, CommitEntry> commitEntriesMap = {};
    while (startIndex < limit) {
      CommitEntry commitEntry = (getBox() as Box).getAt(startIndex);
      if (!_acceptKey(commitEntry.atKey!, regex)) {
        startIndex = startIndex + 1;
        continue;
      }
      if (commitEntriesMap.containsKey(commitEntry.atKey)) {
        commitEntriesMap.remove(commitEntry.atKey);
      }
      commitEntriesMap[commitEntry.atKey!] = commitEntry;
      startIndex = startIndex + 1;
    }
    return commitEntriesMap.entries.iterator;
  }

  ///Returns the key-value pair of commit-log where key is hive internal key and
  ///value is [CommitEntry]
  Future<Map<int, CommitEntry>> toMap() async {
    var commitLogMap = <int, CommitEntry>{};
    var keys = getBox().keys;

    await Future.forEach(keys, (key) async {
      var value = await getValue(key) as CommitEntry;
      commitLogMap.putIfAbsent(key as int, () => value);
    });
    return commitLogMap;
  }

  ///Returns the total number of keys in commit log keystore.
  int getEntriesCount() {
    return getBox().length;
  }

  Future<void> removeEntriesWithMalformedAtKeys() async {
    for (int commitIndex = 0; commitIndex < getBox().length; commitIndex++) {
      CommitEntry? commitEntry = (getBox() as Box).getAt(commitIndex);
      if (commitEntry == null) {
        _logger.warning(
            'CommitLog seqNum $commitIndex has a null commitEntry - removing');
        remove(commitIndex);
        return;
      }
      if (commitEntry.atKey == null) {
        _logger.warning(
            'CommitLog seqNum $commitIndex has an entry with a null atKey - removed');
        remove(commitIndex);
        return;
      }
      KeyType keyType =
          AtKey.getKeyType(commitEntry.atKey!, enforceNameSpace: false);
      if (keyType == KeyType.invalidKey) {
        _logger.warning(
            'CommitLog seqNum $commitIndex has an entry with an invalid atKey ${commitEntry.atKey} - removed');
        remove(commitIndex);
        return;
      } else {
        _logger.finest(
            'CommitLog seqNum $commitIndex has valid type $keyType for atkey ${commitEntry.atKey}');
      }
    }
  }

  /// Removes all entries which have a malformed [CommitEntry.atKey]
  /// Returns the list of [CommitEntry.atKey]s which were removed
  // @visibleForTesting
  // Future<List<String>> removeEntriesWithMalformedAtKeysOld(
  //     Map<int, CommitEntry> allEntries) async {
  //   List<String> removed = [];
  //   await Future.forEach(allEntries.keys, (int seqNum) async {
  //     CommitEntry? commitEntry = allEntries[seqNum];
  //     if (commitEntry == null) {
  //       _logger.warning(
  //           'CommitLog seqNum $seqNum has a null commitEntry - removing');
  //       remove(seqNum);
  //       return;
  //     }
  //     String? atKey = commitEntry.atKey;
  //     if (atKey == null) {
  //       _logger.warning(
  //           'CommitLog seqNum $seqNum has an entry with a null atKey - removed');
  //       return;
  //     }
  //     KeyType keyType = AtKey.getKeyType(atKey, enforceNameSpace: false);
  //     if (keyType == KeyType.invalidKey) {
  //       _logger.warning(
  //           'CommitLog seqNum $seqNum has an entry with an invalid atKey $atKey - removed');
  //       removed.add(atKey);
  //       remove(seqNum);
  //       return;
  //     } else {
  //       _logger.finer(
  //           'CommitLog seqNum $seqNum has valid type $keyType for atkey $atKey');
  //     }
  //   });
  //   return removed;
  // }

  // /// For each commitEntry with a null commitId, replace the commitId with
  // /// the hive internal key
  // @visibleForTesting
  // Future<void> repairNullCommitIDOld(Map<int, CommitEntry> commitLogMap) async {
  //   await Future.forEach(commitLogMap.keys, (key) async {
  //     CommitEntry? commitEntry = commitLogMap[key];
  //     if (commitEntry?.commitId == null) {
  //       commitEntry!.commitId = key as int;
  //       await getBox().put(commitEntry.commitId, commitEntry);
  //     }
  //   });
  // }

  Future<void> repairNullCommitIDs() async {
    for (int commitIndex = 0; commitIndex < getBox().length; commitIndex++) {
      CommitEntry commitEntry = (getBox() as Box).getAt(commitIndex);
      if (commitEntry.commitId != null) {
        continue;
      }
      AtKeyServerMetadata? atKeyServerMetadata;
      if (atKeyMetadataStore.contains(commitEntry.atKey)) {
        atKeyServerMetadata = await atKeyMetadataStore.get(commitEntry.atKey);
      }
      atKeyServerMetadata ??= AtKeyServerMetadata()..commitId = -1;

      // If commitId of a key in AtKeyMetadataStore is less than the commitId
      // of the "this" commitEntry, then the commitId in AtKeyMetadataStore is old.
      // Update the commitId to the latest.
      if (atKeyServerMetadata.commitId < commitEntry.key) {
        await atKeyMetadataStore.put(
            commitEntry.atKey, atKeyServerMetadata..commitId = commitEntry.key);
      }
      await getBox()
          .put(commitEntry.key, commitEntry..commitId = commitEntry.key);
    }
  }

  Future<void> loadDataIntoMetadataStore() async {
    // Inside "loadDataIntoKeystore" after populating the existing data into
    // the at_metadata_store, insert a dummy key "existing_data_populated"
    // to prevent inserting the data on the subsequent server restart.
    if (atKeyMetadataStore.contains('existing_data_populated')) {
      return;
    }
    for (int commitIndex = 0; commitIndex < getBox().length; commitIndex++) {
      CommitEntry commitEntry = (getBox() as Box).getAt(commitIndex);
      if (commitEntry.commitId == -1) {
        continue;
      }
      await atKeyMetadataStore.put(commitEntry.atKey!,
          AtKeyServerMetadata()..commitId = commitEntry.commitId!);
      // After completion, insert a dummy key to ensure the metadata keystore
      // is prepopulated with the existing data and prevent loading data on
      // subsequent restarts
      await atKeyMetadataStore.put(
          'existing_data_populated', AtKeyServerMetadata()..commitId = -1);
    }
  }

// /// Not a part of API. Added for unit test
// @visibleForTesting
// List<MapEntry<String, CommitEntry>> commitEntriesList() {
//   //  return commitLogCache.entriesList();
// }
}

abstract class BaseCommitLogKeyStore with HiveBase<CommitEntry?> {
  late String _boxName;
  String currentAtSign;

  BaseCommitLogKeyStore(this.currentAtSign);

  Future<CommitEntry?> get(int commitId) async {
    try {
      return await getValue(commitId);
    } on Exception catch (e) {
      throw DataStoreException('Exception get entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error getting entry from commit log:${e.toString()}');
    }
  }

  Future<void> remove(int commitEntryIndex) async {
    try {
      await getBox().delete(commitEntryIndex);
    } on Exception catch (e) {
      throw DataStoreException('Exception deleting entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error deleting entry from commit log:${e.toString()}');
    }
  }

  Future<void> update(int commitId, CommitEntry? commitEntry) {
    throw UnimplementedError();
  }

  /// Returns the list of commit entries greater than [sequenceNumber]
  /// throws [DataStoreException] if there is an exception getting the commit entries
  Future<List<CommitEntry>> getChanges(int sequenceNumber,
      {String? regex, int? limit}) async {
    throw UnimplementedError();
  }
}

@client
class ClientCommitLogKeyStore extends CommitLogKeyStore {
  /// Contains the entries that are last synced by the client SDK.

  /// The key represents the regex and value represents the [CommitEntry]
  final _lastSyncedEntryCacheMap = <String, CommitEntry>{};

  ClientCommitLogKeyStore(String currentAtSign) : super(currentAtSign);

  /// Initializes the key store and makes it ready for the persistance
  @override
  Future<void> initialize() async {
    _boxName = 'commit_log_${AtUtils.getShaForAtSign(currentAtSign)}';
    if (!Hive.isAdapterRegistered(CommitEntryAdapter().typeId)) {
      Hive.registerAdapter(CommitEntryAdapter());
    }
    if (!Hive.isAdapterRegistered(CommitOpAdapter().typeId)) {
      Hive.registerAdapter(CommitOpAdapter());
    }
    await super.openBox(_boxName);
    _logger.finer('Commit log key store is initialized');
  }

  /// Adds a [CommitEntry] to the commitlog
  /// Returns numeric value generated as the key to persist the data
  @override
  Future<int> add(CommitEntry? commitEntry, {int previousCommitId = -1}) async {
    return await getBox().add(commitEntry);
  }

  /// Updates the [commitEntry.commitId] with the given [commitId].
  ///
  /// This method is only called by the client(s) because when a key is created on the
  /// client side, a record is created in the [CommitLogKeyStore] with a null commitId.
  /// At the time sync, a key is created/updated in cloud secondary server and generates
  /// the commitId sends it back to client which the gets updated against the commitEntry
  /// of the key synced.
  ///
  @override
  Future<void> update(int commitId, CommitEntry? commitEntry) async {
    try {
      commitEntry!.commitId = commitId;
      await getBox().put(commitEntry.key, commitEntry);
      if (_lastSyncedEntryCacheMap.isEmpty) {
        return;
      }
      // Iterate through the regex's in the _lastSyncedEntryCacheMap.
      // Updates the commitEntry against the matching regexes.
      for (var regex in _lastSyncedEntryCacheMap.keys) {
        if (_acceptKey(commitEntry.atKey!, regex)) {
          _lastSyncedEntryCacheMap[regex] = commitEntry;
        }
      }
    } on Exception catch (e) {
      throw DataStoreException('Exception updating entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error updating entry to commit log:${e.toString()}');
    }
  }

  @override
  Future<List<CommitEntry>> getChanges(int sequenceNumber,
      {String? regex, int? limit}) async {
    try {
      if (getBox().isEmpty) {
        return <CommitEntry>[];
      }
      var changes = <CommitEntry>[];
      var regexString = (regex != null) ? regex : '';
      var values = (getBox() as Box).values;
      var startKey = sequenceNumber + 1;
      limit ??= values.length + 1;
      for (CommitEntry element in values) {
        if (element.key >= startKey &&
            _acceptKey(element.atKey!, regexString) &&
            changes.length <= limit) {
          if (element.commitId == null) {
            changes.add(element);
          }
        }
      }
      return changes;
    } on Exception catch (e) {
      throw DataStoreException('Exception getting changes:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to commit log:${e.toString()}');
    }
  }

  /// Returns the lastSyncedEntry to the local secondary commitLog keystore by the clients.
  ///
  /// Optionally accepts the regex. Matches the regex against the [CommitEntry.AtKey] and returns the
  /// matching [CommitEntry]. Defaulted to accept all patterns.
  ///
  /// This is used by the clients which have local secondary keystore. Not used by the secondary server.
  Future<CommitEntry?> lastSyncedEntry({String regex = '.*'}) async {
    CommitEntry? lastSyncedEntry;
    if (_lastSyncedEntryCacheMap.containsKey(regex)) {
      lastSyncedEntry = _lastSyncedEntryCacheMap[regex];
      _logger.finer(
          'Returning the lastSyncedEntry matching regex $regex from cache. lastSyncedKey : ${lastSyncedEntry!.atKey} with commitId ${lastSyncedEntry.commitId}');
      return lastSyncedEntry;
    }
    var values = (getBox() as Box).values.toList()..sort(_sortByCommitId);
    if (values.isEmpty) {
      return null;
    }
    // Returns the commitEntry with maximum commitId matching the given regex.
    // otherwise returns NullCommitEntry
    lastSyncedEntry = values.lastWhere(
        (entry) =>
            (_acceptKey(entry!.atKey!, regex) && (entry.commitId != null)),
        orElse: () => NullCommitEntry());

    if (lastSyncedEntry == null || lastSyncedEntry is NullCommitEntry) {
      _logger.finer('Unable to fetch lastSyncedEntry. Returning null');
      return null;
    }

    _logger.finer(
        'Updating the lastSyncedEntry matching regex $regex to the cache. Returning lastSyncedEntry with key : ${lastSyncedEntry.atKey} and commitId ${lastSyncedEntry.commitId}');
    _lastSyncedEntryCacheMap.putIfAbsent(regex, () => lastSyncedEntry!);
    return lastSyncedEntry;
  }

  ///Not a part of API. Exposed for Unit test
  List<CommitEntry> getLastSyncedEntryCacheMapValues() {
    return _lastSyncedEntryCacheMap.values.toList();
  }
}