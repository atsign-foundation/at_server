import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/src/impl/hive/hive_base.dart';
import 'package:at_utils/at_utils.dart';
import 'package:hive/hive.dart';
import 'package:meta/meta.dart';

@server
class HiveCommitLogKeyStore with HiveBase<CommitEntry?> {
  late String _boxName;
  String currentAtSign;
  final _logger = AtSignLogger('CommitLogKeyStore');
  late HiveCommitLogCache commitLogCache;

  int get latestCommitId => commitLogCache.latestCommitId;

  HiveCommitLogKeyStore(this.currentAtSign) {
    commitLogCache = HiveCommitLogCache(this);
  }

  Future<CommitEntry?> get(int commitId) async {
    try {
      final entry = await getValue(commitId);
      entry?.key = commitId;
      return entry;
    } on Exception catch (e) {
      throw DataStoreException('Exception get entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error getting entry from commit log:${e.toString()}');
    }
  }

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

    await repairCommitLogAndCreateCachedMap();
  }

  Future<int> add(CommitEntry? commitEntry) async {
    int internalKey;
    try {
      internalKey = await getBox().add(commitEntry!);
      //set the hive generated key as commit id
      commitEntry.commitId = internalKey;
      // update entry with commitId
      await getBox().put(internalKey, commitEntry);
      CommitEntry? cachedCommitEntry =
          commitLogCache.getEntry(commitEntry.atKey!);

      // Delete old commit entry for the same key from the commit log
      if (cachedCommitEntry?.commitId != null) {
        await getBox().delete(cachedCommitEntry?.commitId);
      }
      // update the commitId in cache commitMap.
      commitLogCache.update(commitEntry.atKey!, commitEntry);
    } on Exception catch (e) {
      throw DataStoreException('Exception updating entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error updating entry to commit log:${e.toString()}');
    }
    return internalKey;
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

  /// Returns the total number of keys
  /// @return - int : Returns number of keys in access log
  int entriesCount() {
    int? totalKeys = 0;
    totalKeys = getBox().keys.length;
    return totalKeys;
  }

  Future<void> remove(int commitEntryIndex) async {
    CommitEntry? commitEntry = (getBox() as Box).get(commitEntryIndex);
    try {
      await getBox().delete(commitEntryIndex);
    } on Exception catch (e) {
      throw DataStoreException('Exception deleting entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error deleting entry from commit log:${e.toString()}');
    }
    // On removing the entry from commit log keystore, remove the stale entries from
    // commit log cache map
    if (commitEntry != null) {
      commitLogCache.remove(commitEntry.atKey!);
    }
  }

  Future<void> removeAll(List<int> deleteKeysList) async {
    if (deleteKeysList.isEmpty) {
      return;
    }
    await getBox().deleteAll(deleteKeysList);
    // Removes stale entries from the commit log cache map
    for (int key in deleteKeysList) {
      CommitEntry? commitEntry = (getBox() as Box).get(key);
      if (commitEntry != null) {
        commitLogCache.remove(commitEntry.atKey!);
      }
    }
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

  /// Returns the latest commitEntry of the key.
  CommitEntry? getLatestCommitEntry(String key) {
    return commitLogCache.getEntry(key);
  }

  /// Lazy stream over every commit entry with `commitId >= [fromCommitId]`
  /// (or all entries if [fromCommitId] is null), in commit-id order.
  /// If [where] is provided, only entries for which `where(entry)` returns
  /// true are yielded. The box's one-entry-per-atKey invariant
  /// (enforced inline by [add] and by the startup dedup migration)
  /// means this yields one entry per atKey naturally.
  Stream<CommitEntry> iterate({
    int? fromCommitId,
    bool Function(CommitEntry)? where,
  }) async* {
    for (final key in getBox().keys) {
      if (fromCommitId != null && (key as int) < fromCommitId) continue;
      final entry = await getValue(key) as CommitEntry;
      if (where != null && !where(entry)) continue;
      yield entry;
    }
  }

  ///Returns the key-value pair of commit-log where key is hive internal key and
  ///value is [CommitEntry]
  Future<Map<int, CommitEntry>> toMap() async {
    var commitLogMap = <int, CommitEntry>{};
    var keys = getBox().keys;

    await Future.forEach(keys, (key) async {
      var value = await getValue(key) as CommitEntry;
      value.key = key as int;
      commitLogMap.putIfAbsent(key, () => value);
    });
    return commitLogMap;
  }

  /// Removes entries with malformed keys
  /// Repairs entries with null commit IDs
  /// Clears and repopulates the [commitLogCache]
  /// Removes any legacy duplicate entries so the box holds at most
  /// one entry per atKey (the entry with the highest commitId).
  @visibleForTesting
  Future<bool> repairCommitLogAndCreateCachedMap() async {
    // Ensures the below code runs only when initialized from secondary server.
    // enableCommitId is set to true in secondary server and to false in client SDK.
    Map<int, CommitEntry> allEntries = await toMap();
    await removeEntriesWithMalformedAtKeys(allEntries);
    await repairNullCommitIDs(allEntries);
    commitLogCache.clear();
    commitLogCache.initialize();
    await dedupBoxToOnePerAtKey();
    return true;
  }

  /// Walks the commit log box and removes any entries whose internal
  /// hive key is not the latest seen for their atKey. After this runs,
  /// the box invariant "at most one entry per atKey" holds.
  ///
  /// Called from [repairCommitLogAndCreateCachedMap] on init. New
  /// commits maintain this invariant inline via [add]'s delete-old
  /// step; this migration covers legacy data and any incidental
  /// duplicates from interrupted writes.
  @visibleForTesting
  Future<void> dedupBoxToOnePerAtKey() async {
    final keepKeys = <int>{};
    for (final entry in commitLogCache._commitLogCacheMap.values) {
      if (entry.commitId != null) keepKeys.add(entry.commitId!);
    }
    final toDelete = <int>[];
    for (final key in getBox().keys) {
      if (key is int && !keepKeys.contains(key)) {
        toDelete.add(key);
      }
    }
    if (toDelete.isNotEmpty) {
      await getBox().deleteAll(toDelete);
      _logger.info(
          'Commit log dedup migration: removed ${toDelete.length} duplicate entries');
    }
  }

  /// Removes all entries which have a malformed [CommitEntry.atKey]
  /// Returns the list of [CommitEntry.atKey]s which were removed
  @visibleForTesting
  Future<List<String>> removeEntriesWithMalformedAtKeys(
      Map<int, CommitEntry> allEntries) async {
    List<String> removed = [];
    await Future.forEach(allEntries.keys, (int seqNum) async {
      CommitEntry? commitEntry = allEntries[seqNum];
      if (commitEntry == null) {
        _logger.warning(
            'CommitLog seqNum $seqNum has a null commitEntry - removing');
        await remove(seqNum);
        return;
      }
      String? atKey = commitEntry.atKey;
      if (atKey == null) {
        _logger.warning(
            'CommitLog seqNum $seqNum has an entry with a null atKey - removed');
        return;
      }
      KeyType keyType = AtKey.getKeyType(atKey, enforceNameSpace: false);
      if (keyType == KeyType.invalidKey) {
        _logger.warning(
            'CommitLog seqNum $seqNum has an entry with an invalid atKey $atKey - removed');
        removed.add(atKey);
        await remove(seqNum);
        return;
      } else {
        _logger.finer(
            'CommitLog seqNum $seqNum has valid type $keyType for atkey $atKey');
      }
    });
    return removed;
  }

  /// For each commitEntry with a null commitId, replace the commitId with
  /// the hive internal key
  @visibleForTesting
  Future<void> repairNullCommitIDs(Map<int, CommitEntry> commitLogMap) async {
    await Future.forEach(commitLogMap.keys, (key) async {
      CommitEntry? commitEntry = commitLogMap[key];
      if (commitEntry?.commitId == null) {
        commitEntry!.commitId = key;
        await getBox().put(commitEntry.commitId, commitEntry);
      }
    });
  }

  /// Not a part of API. Added for unit test
  @visibleForTesting
  List<MapEntry<String, CommitEntry>> commitEntriesList() {
    return commitLogCache.entriesList();
  }
}

class HiveCommitLogCache {
  final _logger = AtSignLogger('CommitLogCache');

  // [CommitLogKeyStore] for which the cache is being maintained
  HiveCommitLogKeyStore commitLogKeyStore;

  // A Map implementing a LinkedHashMap to preserve the insertion order.
  // "{}" is collection literal to represent a LinkedHashMap.
  // Stores AtKey and its corresponding commitEntry sorted by their commit-id's
  final _commitLogCacheMap = <String, CommitEntry>{};

  // Keeps track of latest commit ID
  int _latestCommitId = -1;

  int get latestCommitId => _latestCommitId;

  HiveCommitLogCache(this.commitLogKeyStore);

  /// Initializes the CommitLogCache
  void initialize() {
    Iterable iterable = (commitLogKeyStore.getBox() as Box).values;
    for (var value in iterable) {
      if (value.commitId == null) {
        _logger.finest(
            'CommitID is null for ${value.atKey}. Skipping to update entry into commitLogCacheMap');
        continue;
      }
      // The reason we remove and add is that, the map which is a LinkedHashMap
      // should have data in the following format:
      // {
      //  {k1, v1},
      //  {k2, v2},
      //  {k3, v3}
      // }
      // such that v1 < v2 < v3
      //
      // If a key exist in the _commitLogCacheMap, updating the commit entry will
      // overwrite the existing key resulting into an unsorted map.
      // Hence remove the key and insert at the last ensure the entry with highest commitEntry
      // is always at the end of the map.
      if (_commitLogCacheMap.containsKey(value.atKey)) {
        _commitLogCacheMap.remove(value.atKey);
        _commitLogCacheMap[value.atKey] = value;
      } else {
        _commitLogCacheMap[value.atKey] = value;
      }
      // update the latest commit id
      if (value.commitId > _latestCommitId) {
        _latestCommitId = value.commitId;
      }
    }
  }

  /// Updates cache when a new [CommitEntry] for the [key] is added
  void update(String key, CommitEntry commitEntry) {
    int? existingCommitId = getEntry(key)?.commitId;
    // ignore update, if cache has existing commitEntry for current key with a greater commitId
    if (existingCommitId != null &&
        commitEntry.commitId != null &&
        existingCommitId > commitEntry.commitId!) {
      _logger.info(
          'Ignoring commit entry update to cache. existingCommitId: $existingCommitId | toUpdateWithCommitId: ${commitEntry.commitId}');
      return;
    }
    _updateCacheLog(key, commitEntry);

    if (commitEntry.commitId != null &&
        commitEntry.commitId! > _latestCommitId) {
      _latestCommitId = commitEntry.commitId!;
    }
  }

  /// Updates the commitId of the key.
  void _updateCacheLog(String key, CommitEntry commitEntry) {
    // The reason we remove and add is that, the map which is a LinkedHashMap
    // should have data in the following format:
    // {
    //  {k1, v1},
    //  {k2, v2},
    //  {k3, v3}
    // }
    // such that v1 < v2 < v3
    //
    // If a key exist in the _commitLogCacheMap, updating the commit entry will
    // overwrite the existing key resulting into an unsorted map.
    // Hence remove the key and insert at the last ensure the entry with highest commitEntry
    // is always at the end of the map.
    _commitLogCacheMap.remove(key);
    _commitLogCacheMap[key] = commitEntry;
  }

  CommitEntry? getEntry(String atKey) {
    if (_commitLogCacheMap.containsKey(atKey)) {
      return _commitLogCacheMap[atKey];
    }
    return null;
  }

  /// On commit log compaction, the entries are removed from the
  /// Commit Log Keystore. Remove the stale entries from the commit log cache-map
  void remove(String atKey) {
    _commitLogCacheMap.remove(atKey);
  }

  /// Not a part of API. Added for unit test
  @visibleForTesting
  List<MapEntry<String, CommitEntry>> entriesList() {
    return _commitLogCacheMap.entries.toList();
  }

  // Clears all of the entries in cache
  void clear() {
    _commitLogCacheMap.clear();
  }
}
