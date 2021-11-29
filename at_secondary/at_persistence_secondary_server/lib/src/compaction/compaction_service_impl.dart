import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/compaction/compaction_service.dart';

/// Class implementing the [CompactionService].
/// On server start-up initializes the [_commitLogEntriesMap] with keys of [CommitEntry] from [CommitLogKeyStore].
/// Further, on adding the entry to [CommitLogKeyStore] check's if the compaction threshold reaches.
/// If yes, compacts the [CommitLogKeyStore].
class CommitLogCompactionService implements CompactionService {
  late CommitLogKeyStore _commitLogKeyStore;
  final _commitLogEntriesMap = <String, CompactionSortedList>{};
  int keysToCompactCount = 0;
  List<AtCompactionLogObserver> observers = <AtCompactionLogObserver>[];

  CommitLogCompactionService(CommitLogKeyStore commitLogKeyStore) {
    _commitLogKeyStore = commitLogKeyStore;
    commitLogKeyStore.toMap().then((map) => map.forEach((key, commitEntry) {
          // If _commitLogEntriesMap contains the key, then more than one commitEntry exists.
          // Increment the keysToCompactCount.
          if (_commitLogEntriesMap.containsKey(key)) {
            keysToCompactCount = keysToCompactCount + 1;
          }
          _commitLogEntriesMap.putIfAbsent(
              commitEntry.atKey, () => CompactionSortedList());
          _commitLogEntriesMap[commitEntry.atKey]!.add(key);
        }));
  }

  @override
  Future<void> informChange(CommitEntry commitEntry) async {
    // If _commitLogEntriesMap contains the key, then more than one commitEntry exists.
    // Increment the keysToCompactCount.
    if (_commitLogEntriesMap.containsKey(commitEntry.atKey!)) {
      keysToCompactCount = keysToCompactCount + 1;
    }
    _commitLogEntriesMap.putIfAbsent(
        commitEntry.atKey!, () => CompactionSortedList());
    _commitLogEntriesMap[commitEntry.atKey!]!.add(commitEntry.commitId!);
    await compact();
  }

  @override
  Future<void> compact() async {
    if (_isCompactionRequired()) {
      var keysBeforeCompaction = _commitLogKeyStore.getBox().length;
      await Future.forEach(
          _commitLogEntriesMap.keys, (key) => _compactExpiredKeys(key));
      //Reset keysToCompactCount to 0 after deleting the expired keys.
      keysToCompactCount = 0;
      var keysAfterCompaction = _commitLogKeyStore.getBox().length;
      // notify to observer when compaction is completed.
      for (var observer in observers) {
        observer.informCompletion(keysBeforeCompaction - keysAfterCompaction);
      }
    }
  }

  /// For the given atKey, gets the expired commitEntry keys and removes from keystore
  void _compactExpiredKeys(var atKey) async {
    var atKeyList = _commitLogEntriesMap[atKey];
    var expiredKeys = atKeyList!.getKeysToCompact();
    await _commitLogKeyStore.delete(expiredKeys);
    atKeyList.deleteCompactedKeys(expiredKeys);
  }

  /// Returns true if compaction is required, else false.
  bool _isCompactionRequired() {
    return keysToCompactCount >= 50;
  }

  /// Return's the list of [CommitEntry] key's for a given atKey.
  /// Used in unit tests.
  CompactionSortedList? getCommitKeys(var key) {
    return _commitLogEntriesMap[key];
  }

  /// Adds observer to the [observers]
  void addObserver(AtCompactionLogObserver atCompactionLogObserver) {
    observers.add(atCompactionLogObserver);
  }
}

/// Represents the list of keys of [CommitEntry].
class CompactionSortedList {
  final _list = [];

  /// Adds the hive key of [CommitEntry] to the list and sort's the keys in descending order.
  void add(int commitEntryKey) {
    _list.add(commitEntryKey);
    _list.sort((a, b) => b.compareTo(a));
  }

  /// Returns the keys to compact.
  List getKeysToCompact() {
    var expiredKeys = _list.sublist(1);
    return expiredKeys;
  }

  /// Removes the compacted keys from the list.
  void deleteCompactedKeys(var expiredKeys) {
    for (var key in expiredKeys) {
      _list.remove(key);
    }
  }

  /// Returns the size of list.
  int getSize() {
    return _list.length;
  }

  @override
  String toString() {
    return 'CompactionSortedList{_list: $_list}';
  }
}
