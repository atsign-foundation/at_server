import 'dart:collection';
import 'dart:math';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_logger.dart';
import 'package:hive/hive.dart';
import 'package:meta/meta.dart';

/// Class extending the [CommitLogKeyStore].
///
/// This class is specific to the AtSecondaryServer
class AtServerCommitLogKeyStore extends CommitLogKeyStore {
  AtServerCommitLogKeyStore(String currentAtSign) : super(currentAtSign);

  final _commitLogCacheMap = <String, CommitEntry>{};

  int _latestCommitId = -1;

  int get latestCommitId => _latestCommitId;

  final _logger = AtSignLogger('AtServerCommitLogKeyStore');

  @override
  Future<void> initialize() async {
    await super.initialize();
    // Repairs the commit log.
    // If null commit id's exist in commitEntry, replaces the commitId with
    // respective hive internal key
    await repairCommitLog(await toMap());
    // Cache the latest commitId of each key.
    // Add entries to commitLogCacheMap when initialized from at_secondary_server
    // and refrain for at_client_sdk.
    _commitLogCacheMap.addAll(await _getCommitIdMap());
  }

  @override
  Future<int> add(CommitEntry? commitEntry) async {
    var internalKey = await super.add(commitEntry);
    //set the hive generated key as commit id
    commitEntry!.commitId = internalKey;
    // update entry with commitId
    await super.getBox().put(internalKey, commitEntry);
    // update the commitId in cache commitMap.
    _updateCacheLog(commitEntry.atKey!, commitEntry);
    if (commitEntry.commitId != null &&
        commitEntry.commitId! > _latestCommitId) {
      _latestCommitId = commitEntry.commitId!;
    }
    return internalKey;
  }

  Future<int?> lastCommittedSequenceNumberWithRegex(String regex) async {
    var values = await _getValues();
    var lastCommittedEntry = values.lastWhere(
        (entry) => (acceptKey(entry.atKey, regex)),
        orElse: () => NullCommitEntry());
    var lastCommittedSequenceNum =
        (lastCommittedEntry != null) ? lastCommittedEntry.key : null;
    return lastCommittedSequenceNum;
  }

  @override
  Future<List<dynamic>> getExpired(int expiryInDays) async {
    final dupEntries = await getDuplicateEntries();
    _logger.finer('commit log entries to delete: $dupEntries');
    return dupEntries;
  }

  Future<List> getDuplicateEntries() async {
    var commitLogMap = await toMap();
    //defensive fix for commit entries with commitId equal to null
    Set keysWithNullCommitIdsInValue = {};
    commitLogMap.forEach((key, value) {
      if (value.commitId == null) {
        keysWithNullCommitIdsInValue.add(key);
        _logger.severe('Commit ID is null for key $key with value $value');
      }
    });
    for (var key in keysWithNullCommitIdsInValue) {
      commitLogMap.remove(key);
    }
    var sortedKeys = commitLogMap.keys.toList(growable: false)
      ..sort((k1, k2) =>
          commitLogMap[k2]!.commitId!.compareTo(commitLogMap[k1]!.commitId!));
    var tempSet = <String>{};
    var expiredKeys = [];
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

  /// Returns the list of commit entries greater than [sequenceNumber]
  /// throws [DataStoreException] if there is an exception getting the commit entries
  Future<List<CommitEntry>> getChanges(int sequenceNumber,
      {String? regex, int? limit}) async {
    var changes = <CommitEntry>[];
    var regexString = (regex != null) ? regex : '';
    var values = await _getValues();
    try {
      var keys = super.getBox().keys;
      if (keys.isEmpty) {
        return changes;
      }
      var startKey = sequenceNumber + 1;
      _logger.finer('startKey: $startKey all commit log entries: $values');
      limit ??= values.length + 1;
      for (CommitEntry element in values) {
        if (element.key >= startKey &&
            acceptKey(element.atKey!, regexString) &&
            changes.length <= limit) {
          changes.add(element);
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

  /// Returns a map of all the keys in the commitLog and latest [CommitEntry] of the key.
  /// Called in init method of commitLog to initialize on server start-up.
  Future<Map<String, CommitEntry>> _getCommitIdMap() async {
    var keyMap = <String, CommitEntry>{};
    var values = await _getValues();
    for (var value in values) {
      if (value.commitId == null) {
        _logger.severe(
            'CommitID is null for ${value.atKey}. Skipping to update entry into commitLogCacheMap');
        continue;
      }
      // If keyMap contains the key, update the commitId in the map with greater commitId.
      if (keyMap.containsKey(value.atKey)) {
        keyMap[value.atKey]!.commitId =
            max(keyMap[value.atKey]!.commitId!, value.commitId);
      } else {
        keyMap[value.atKey] = value;
      }
      // update the latest commit id
      if (value.commitId > _latestCommitId) {
        _latestCommitId = value.commitId;
      }
    }
    return keyMap;
  }

  /// Updates the commitId of the key.
  void _updateCacheLog(String key, CommitEntry commitEntry) {
    _commitLogCacheMap[key] = commitEntry;
  }

  /// Returns the latest commitEntry of the key.
  CommitEntry getLatestCommitEntry(String key) {
    if (_commitLogCacheMap.containsKey(key)) {
      return _commitLogCacheMap[key]!;
    }
    return NullCommitEntry();
  }

  /// Returns the Iterator of [_commitLogCacheMap] from the commitId specified.
  Iterator getEntries(int commitId, {String regex = '.*'}) {
    // Sorts the keys by commitId in ascending order.
    var sortedKeys = _commitLogCacheMap.keys.toList()
      ..sort((k1, k2) => _commitLogCacheMap[k1]!
          .commitId!
          .compareTo(_commitLogCacheMap[k2]!.commitId!));

    var sortedMap = LinkedHashMap.fromIterable(sortedKeys,
        key: (k) => k, value: (k) => _commitLogCacheMap[k]);
    // Remove the keys that does not match regex or commitId of the key
    // less than the commitId specified in the argument.
    sortedMap.removeWhere(
        (key, value) => !acceptKey(key, regex) || value!.commitId! < commitId);
    return sortedMap.entries.iterator;
  }

  Future<List> _getValues() async {
    var commitLogMap = await toMap();
    return commitLogMap.values.toList();
  }

  @override
  Future<void> remove(int commitId) async {
    final commitEntry = (super.getBox() as Box).get(commitId);
    await super.remove(commitId);
    // invalidate cache for the removed entry
    if (commitEntry != null) {
      _commitLogCacheMap.remove(commitEntry.atKey);
      _logger.finest('removed key : ${commitEntry.atKey} from commit log.');
    }
  }

  /// Replaces the null commit id's with hive internal key's
  @visibleForTesting
  Future<void> repairCommitLog(Map<int, CommitEntry> commitLogMap) async {
    await Future.forEach(commitLogMap.keys, (key) async {
      CommitEntry? commitEntry = commitLogMap[key];
      if (commitEntry?.commitId == null) {
        await update(key as int, commitEntry);
      }
    });
  }
}
