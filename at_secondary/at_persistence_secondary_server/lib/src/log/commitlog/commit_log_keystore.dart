import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/commit_entry.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:at_utils/at_utils.dart';
import 'package:hive/hive.dart';

class CommitLogKeyStore implements LogKeyStore<int, CommitEntry?> {
  var logger = AtSignLogger('CommitLogKeyStore');
  bool enableCommitId = true;
  String? storagePath;
  final _currentAtSign;
  late String _boxName;
  final _commitLogCacheMap = <String, CommitEntry>{};

  CommitLogKeyStore(this._currentAtSign);

  Future<void> init(String storagePath) async {
    _boxName = 'commit_log_' + AtUtils.getShaForAtSign(_currentAtSign);
    Hive.init(storagePath);

    if (!Hive.isAdapterRegistered(CommitEntryAdapter().typeId)) {
      Hive.registerAdapter(CommitEntryAdapter());
    }
    if (!Hive.isAdapterRegistered(CommitOpAdapter().typeId)) {
      Hive.registerAdapter(CommitOpAdapter());
    }

    this.storagePath = storagePath;
    await Hive.openLazyBox(_boxName,
        compactionStrategy: (entries, deletedEntries) {
      return deletedEntries > 1;
    });
    var lastCommittedSequenceNum = lastCommittedSequenceNumber();
    logger.finer('last committed sequence: $lastCommittedSequenceNum');
    if (_getBox().isOpen) {
      logger.info('Keystore initialized successfully');
    }
    // Cache the latest commitId of each key.
    _commitLogCacheMap.addAll(await _getCommitIdMap());
  }

  /// Closes the [commitLogKeyStore] instance.
  Future<void> close() async {
    await _getBox().close();
  }

  @override
  Future<CommitEntry?> get(int commitId) async {
    try {
      var commitEntry = await _getBox().get(commitId);
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
    var internalKey;
    try {
      internalKey = await _getBox().add(commitEntry);
      //set the hive generated key as commit id
      if (enableCommitId) {
        commitEntry!.commitId = internalKey;
        // update entry with commitId
        await _getBox().put(internalKey, commitEntry);
        // update the commitId in cache commitMap.
        _updateCacheLog(commitEntry.atKey!, commitEntry);
      }
    } on Exception catch (e) {
      throw DataStoreException('Exception updating entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error updating entry to commit log:${e.toString()}');
    }
    return internalKey;
  }

  @override
  Future update(int commitId, CommitEntry? commitEntry) async {
    try {
      commitEntry!.commitId = commitId;
      await _getBox().put(commitEntry.key, commitEntry);
    } on Exception catch (e) {
      throw DataStoreException('Exception updating entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error updating entry to commit log:${e.toString()}');
    }
  }

  /// Remove
  @override
  Future remove(int commitId) async {
    try {
      await _getBox().delete(commitId);
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
        _getBox().keys.isNotEmpty ? _getBox().keys.last : null;
    return lastCommittedSequenceNum;
  }

  /// Returns the latest committed sequence number with regex
  Future<int>? lastCommittedSequenceNumberWithRegex(String regex) async {
    var values = await _getValues();
    var lastCommittedEntry = values.lastWhere(
        (entry) => (_isRegexMatches(entry.atKey, regex)),
        orElse: () => null);
    var lastCommittedSequenceNum =
        (lastCommittedEntry != null) ? lastCommittedEntry.key : null;
    return lastCommittedSequenceNum;
  }

  Future<CommitEntry>? lastSyncedEntry({String? regex}) async {
    var lastSyncedEntry;
    var values = await _getValues();
    if (regex != null) {
      lastSyncedEntry = values.lastWhere(
          (entry) =>
              (_isRegexMatches(entry.atKey, regex) && (entry.commitId != null)),
          orElse: () => null);
    } else {
      lastSyncedEntry = values.lastWhere((entry) => entry.commitId != null,
          orElse: () => null);
    }
    return lastSyncedEntry;
  }

  /// Returns the first committed sequence number
  int? firstCommittedSequenceNumber() {
    var firstCommittedSequenceNum =
        _getBox().keys.isNotEmpty ? _getBox().keys.first : null;
    return firstCommittedSequenceNum;
  }

  /// Returns the total number of keys
  /// @return - int : Returns number of keys in access log
  @override
  int entriesCount() {
    int? totalKeys = 0;
    totalKeys = _getBox().keys.length;
    return totalKeys;
  }

  /// Gets the first 'N' keys from the logs
  /// @param - N : The integer to get the first 'N'
  /// @return List of first 'N' keys from the log
  @override
  List getFirstNEntries(int N) {
    var entries = [];
    try {
      entries = _getBox().keys.toList().take(N).toList();
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
  void delete(dynamic expiredKeys) {
    if (expiredKeys.isNotEmpty) {
      _getBox().deleteAll(expiredKeys);
    }
  }

  @override
  int getSize() {
    var logSize = 0;
    var logLocation = Directory(storagePath!);

    if (storagePath != null) {
      //The listSync function returns the list of files in the commit log storage location.
      // The below loop iterates recursively into sub-directories over each file and gets the file size using lengthSync function
      logLocation.listSync().forEach((element) {
        logSize = logSize + File(element.path).lengthSync();
      });
    }
    return logSize ~/ 1024;
  }

  @override
  Future<List<dynamic>> getExpired(int expiryInDays) async {
    // TODO: implement getExpired
    return [];
  }

  Future<List> getDuplicateEntries() async {
    var commitLogMap = await _toMap();
    var sortedKeys = commitLogMap.keys.toList(growable: false)
      ..sort((k1, k2) =>
          commitLogMap[k2].commitId.compareTo(commitLogMap[k1].commitId));
    var tempSet = <String>{};
    var expiredKeys = [];
    sortedKeys.forEach(
        (entry) => _processEntry(entry, tempSet, expiredKeys, commitLogMap));
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
      var keys = _getBox().keys;
      if (keys == null || keys.isEmpty) {
        return changes;
      }
      var startKey = sequenceNumber + 1;
      logger.finer('startKey: $startKey all commit log entries: $values');
      if (limit != null) {
        values.forEach((element) {
          if (element.key >= startKey &&
              _isRegexMatches(element.atKey, regexString) &&
              changes.length <= limit) {
            changes.add(element);
          }
        });
        return changes;
      }
      values.forEach((f) {
        if (f.key >= startKey) {
          if (_isRegexMatches(f.atKey, regexString)) {
            changes.add(f);
          }
        }
      });
    } on Exception catch (e) {
      throw DataStoreException('Exception getting changes:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to commit log:${e.toString()}');
    }
    return changes;
  }

  bool _isRegexMatches(String atKey, String regex) {
    var result = false;
    if ((RegExp(regex).hasMatch(atKey)) ||
        atKey.contains(AT_ENCRYPTION_SHARED_KEY) ||
        atKey.startsWith('public:') ||
        atKey.contains(AT_PKAM_SIGNATURE) ||
        atKey.contains(AT_SIGNING_PRIVATE_KEY)) {
      result = true;
    }
    return result;
  }

  /// Returns a map of all the keys in the commitLog and latest [CommitEntry] of the key.
  /// Called in init method of commitLog to initialize on server start-up.
  Future<Map<String, CommitEntry>> _getCommitIdMap() async{
    var keyMap = <String, CommitEntry>{};
    var values = await _getValues();
    values.forEach((entry) {
      // If keyMap contains the key, update the commitId in the map with greater commitId.
      if (keyMap.containsKey(entry.atKey)) {
        keyMap[entry.atKey]!.commitId =
            max(keyMap[entry.atKey]!.commitId!, entry.commitId);
      } else {
        keyMap[entry.atKey] = entry;
      }
    });
    return keyMap;
  }

  /// Updates the commitId of the key.
  void _updateCacheLog(String key, CommitEntry commitEntry) {
    _commitLogCacheMap[key] = commitEntry;
  }

  /// Returns the latest commitEntry of the key.
  CommitEntry? getLatestCommitEntry(String key) {
    if (_commitLogCacheMap.containsKey(key)) {
      return _commitLogCacheMap[key]!;
    }
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
    sortedMap.removeWhere((key, value) =>
        !_isRegexMatches(key, regex) || value!.commitId! < commitId);
    return sortedMap.entries.iterator;
  }

  Future<List> _getValues() async {
    var commitLogMap = await _toMap();
    return commitLogMap.values.toList();
  }

  LazyBox _getBox() {
    return Hive.lazyBox(_boxName);
  }

  Future<Map> _toMap() async {
    var commitLogMap = {};
    var keys = _getBox().keys;
    var value;
    await Future.forEach(keys, (key) async {
      value = await _getBox().get(key);
      commitLogMap.putIfAbsent(key, () => value);
    });
    return commitLogMap;
  }
}
