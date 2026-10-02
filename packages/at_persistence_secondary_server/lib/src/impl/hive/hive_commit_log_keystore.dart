import 'dart:math';

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

  /// Holds the highest commitId issued once the record that carried it has
  /// left the commit-log box. Hive's compaction removes a deleted record
  /// from disk entirely, and with it the only trace that its id was issued.
  late Box _highWaterMarkBox;
  static const String _highWaterMarkKey = 'highWaterMark';

  int get latestCommitId => commitLogCache.latestCommitId;

  /// Smallest commitId still retained in the box, or `null` when the
  /// box is empty.
  ///
  /// Read straight from the box (not the cache) — correct because
  /// (1) the box's hive-internal key IS the commitId ([add] writes each
  /// entry under its commitId; [repairNullCommitIDs] backfills legacy
  /// nulls at init), and (2) Hive iterates box keys in ascending
  /// sorted order, so `keys.first` is the floor regardless of
  /// insertion or compaction history. See commit message body.
  int? get firstCommitId {
    final keys = getBox().keys;
    return keys.isEmpty ? null : keys.first as int;
  }

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
    if (!hive.isAdapterRegistered(CommitEntryAdapter().typeId)) {
      hive.registerAdapter(CommitEntryAdapter());
    }
    if (!hive.isAdapterRegistered(CommitOpAdapter().typeId)) {
      hive.registerAdapter(CommitOpAdapter());
    }
    await super.openBox(_boxName);
    _highWaterMarkBox = await hive.openBox('${_boxName}_meta');
    final int? storedHighWaterMark =
        _highWaterMarkBox.get(_highWaterMarkKey) as int?;
    if (storedHighWaterMark != null) {
      commitLogCache.raiseLatestCommitId(storedHighWaterMark);
    }
    _logger.finer('Commit log key store is initialized');

    await repairCommitLogAndCreateCachedMap();
  }

  Future<int> add(CommitEntry? commitEntry) async {
    final entry = commitEntry!;
    // NOTE issued before the first await, so concurrent adds cannot share
    // an id.
    final int commitId = commitLogCache.issueCommitId();
    try {
      entry.commitId = commitId;
      await getBox().put(commitId, entry);
      CommitEntry? cachedCommitEntry = commitLogCache.getEntry(entry.atKey!);

      // Delete old commit entry for the same key from the commit log
      if (cachedCommitEntry?.commitId != null) {
        await getBox().delete(cachedCommitEntry?.commitId);
      }
      // update the commitId in cache commitMap.
      commitLogCache.update(entry.atKey!, entry);
    } on Exception catch (e) {
      await _keepHighWaterMarkAfterFailedAdd();
      throw DataStoreException('Exception updating entry:${e.toString()}');
    } on HiveError catch (e) {
      await _keepHighWaterMarkAfterFailedAdd();
      throw DataStoreException(
          'Hive error updating entry to commit log:${e.toString()}');
    }
    return commitId;
  }

  /// Stores the highest commitId issued after an [add] fails, since the id
  /// it issued may have no record in the box. Best effort: the failure being
  /// reported is the add's, not this one's.
  Future<void> _keepHighWaterMarkAfterFailedAdd() async {
    try {
      await _highWaterMarkBox.put(
          _highWaterMarkKey, commitLogCache.latestCommitId);
    } on Exception catch (e) {
      _logger.severe('Could not store the highest commit id issued: $e');
    } on HiveError catch (e) {
      _logger.severe('Could not store the highest commit id issued: $e');
    }
  }

  /// Writes [entry] under the commitId it was issued elsewhere.
  Future<void> replay(CommitEntry entry) async {
    await getBox().put(entry.commitId, entry);
    commitLogCache.raiseLatestCommitId(entry.commitId!);
  }

  /// Raises the highest commitId issued to at least [commitId], storing it
  /// because no record in the box carries it.
  Future<void> raiseHighWaterMark(int commitId) async {
    if (commitId <= commitLogCache.latestCommitId) return;
    commitLogCache.raiseLatestCommitId(commitId);
    await _highWaterMarkBox.put(_highWaterMarkKey, commitId);
  }

  /// Stores the highest of [commitIds] when no higher id has been issued,
  /// before its record leaves the box.
  Future<void> _keepHighWaterMarkOf(Iterable<int> commitIds) async {
    if (commitIds.isEmpty) return;
    final highest = commitIds.reduce(max);
    if (highest < commitLogCache.latestCommitId) return;
    commitLogCache.raiseLatestCommitId(highest);
    await _highWaterMarkBox.put(_highWaterMarkKey, highest);
  }

  /// Removes every entry and forgets every id issued, so the next one is 0.
  Future<void> clear() async {
    await getBox().clear();
    await _highWaterMarkBox.clear();
    commitLogCache.reset();
  }

  @override
  Future<void> close() async {
    if (_highWaterMarkBox.isOpen) {
      await _highWaterMarkBox.close();
    }
    await super.close();
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
      await _keepHighWaterMarkOf([commitEntryIndex]);
      await getBox().delete(commitEntryIndex);
    } on Exception catch (e) {
      throw DataStoreException('Exception deleting entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error deleting entry from commit log:${e.toString()}');
    }
    // On removing the entry from commit log keystore, remove the stale
    // entry from the commit log cache map — but only when the cache's
    // entry for this atKey is the one being deleted. Removing an older
    // duplicate must not evict the newer live entry.
    if (commitEntry?.atKey != null) {
      _evictFromCacheIfCurrent(commitEntry!.atKey!, commitEntryIndex);
    }
  }

  Future<void> removeAll(List<int> deleteKeysList) async {
    if (deleteKeysList.isEmpty) {
      return;
    }
    // Capture (boxKey → atKey) BEFORE deleteAll — afterwards the
    // entries are gone and their atKeys unrecoverable.
    final toEvict = <int, String>{};
    for (final key in deleteKeysList) {
      final CommitEntry? entry = (getBox() as Box).get(key);
      if (entry?.atKey != null) {
        toEvict[key] = entry!.atKey!;
      }
    }
    await _keepHighWaterMarkOf(deleteKeysList);
    await getBox().deleteAll(deleteKeysList);
    // Removes stale entries from the commit log cache map
    toEvict.forEach((boxKey, atKey) {
      _evictFromCacheIfCurrent(atKey, boxKey);
    });
  }

  /// Removes [atKey]'s cache entry iff the cache currently points at
  /// [deletedCommitId]. When the deleted box entry was an older
  /// duplicate, the cache holds a newer entry for the same atKey
  /// which must stay.
  void _evictFromCacheIfCurrent(String atKey, int deletedCommitId) {
    if (commitLogCache.getEntry(atKey)?.commitId == deletedCommitId) {
      commitLogCache.remove(atKey);
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
  /// true are yielded. [skipDeletesUntil]/[latestCommitId] apply sync's
  /// delete-skip (see [AtCommitLog.iterate]). The box's one-entry-per-atKey
  /// invariant (enforced inline by [add] and by the startup dedup migration)
  /// means this yields one entry per atKey naturally.
  Stream<CommitEntry> iterate({
    int? fromCommitId,
    bool Function(CommitEntry)? where,
    int? skipDeletesUntil,
    int? latestCommitId,
  }) async* {
    for (final key in getBox().keys) {
      if (fromCommitId != null && (key as int) < fromCommitId) continue;
      final entry = await getValue(key) as CommitEntry;
      // Sync's delete-skip: drop below-watermark DELETE entries, keeping
      // only the latest so the client can still advance its watermark.
      if (skipDeletesUntil != null &&
          entry.operation == CommitOp.DELETE &&
          entry.commitId != null &&
          entry.commitId! <= skipDeletesUntil &&
          entry.commitId != latestCommitId) {
        continue;
      }
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
      await _keepHighWaterMarkOf(toDelete);
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

  // The highest commitId ever issued.
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

  /// Raises [latestCommitId] to [commitId] when that is higher.
  void raiseLatestCommitId(int commitId) {
    if (commitId > _latestCommitId) {
      _latestCommitId = commitId;
    }
  }

  /// Issues the next commitId.
  int issueCommitId() => ++_latestCommitId;

  /// Forgets every entry and every commitId issued.
  void reset() {
    _commitLogCacheMap.clear();
    _latestCommitId = -1;
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
