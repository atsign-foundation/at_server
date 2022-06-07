import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/event_listener/at_change_event.dart';
import 'package:at_persistence_secondary_server/src/event_listener/at_change_event_listener.dart';
import 'package:at_utils/at_logger.dart';

/// [CommitLogCompactionService] class is responsible for compacting the [AtCommitLog]
/// Listens on the [AtChangeEventListener] and increments [keysToCompactCount] on each insert
/// into the commit-log. When [keysToCompactCount] reaches threshold (50), compaction triggers
/// and removes the duplicate [CommitEntry]
class CommitLogCompactionService implements AtChangeEventListener {
  late CommitLogKeyStore _commitLogKeyStore;
  final _commitLogEntriesMap = <String, CompactionSortedList>{};
  int keysToCompactCount = 0;
  final _logger = AtSignLogger('CommitLogCompactionService');
  static const atServer = AtServerAnnotation();

  /// Initializes the [CommitLogCompactionService] and loads the keys in [AtCommitLog]
  /// into [_commitLogEntriesMap].
  CommitLogCompactionService(CommitLogKeyStore commitLogKeyStore) {
    _commitLogKeyStore = commitLogKeyStore;
    _commitLogKeyStore.toMap().then((map) => map.forEach((key, commitEntry) {
          // If _commitLogEntriesMap contains the key, then more than one commitEntry exists.
          // Increment the keysToCompactCount.
          if (_commitLogEntriesMap.containsKey(commitEntry.atKey)) {
            keysToCompactCount = keysToCompactCount + 1;
          }
          _commitLogEntriesMap.putIfAbsent(
              commitEntry.atKey, () => CompactionSortedList());
          _commitLogEntriesMap[commitEntry.atKey]!.add(key);
        }));
  }
  @atServer
  @override
  Future<void> listen(AtPersistenceChangeEvent atChangeEvent) async {
    if (_commitLogEntriesMap.containsKey(atChangeEvent.key)) {
      keysToCompactCount = keysToCompactCount + 1;
    }
    _commitLogEntriesMap.putIfAbsent(
        atChangeEvent.key, () => CompactionSortedList());
    _commitLogEntriesMap[atChangeEvent.key]?.add(atChangeEvent.value);
    await compact();
  }

  /// Removes the duplicate [CommitEntry] when reaches the threshold.
  @atServer
  Future<void> compact() async {
    if (_isCompactionRequired()) {
      var keysBeforeCompaction = _commitLogKeyStore.getEntriesCount();
      try {
        await Future.forEach(
            _commitLogEntriesMap.keys, (key) => _compactExpiredKeys(key));
        var keysAfterCompaction = _commitLogKeyStore.getEntriesCount();
        _logger.info(
            'Commit Log compacted successfully. Removed ${keysBeforeCompaction - keysAfterCompaction} duplicate entries');
        //Reset keysToCompactCount to 0 after deleting the expired keys.
        keysToCompactCount = 0;
      } on Exception catch (e) {
        _logger.severe(
            'Exception occurred while performing commit log compaction ${e.toString}');
      }
    }
  }

  /// For the given atKey, gets the expired commitEntry keys and removes from keystore
  Future<void> _compactExpiredKeys(var atKey) async {
    var atKeyList = _commitLogEntriesMap[atKey];
    var expiredKeys = atKeyList?.getKeysToCompact();
    if (expiredKeys != null && expiredKeys.isNotEmpty) {
      await _commitLogKeyStore.delete(expiredKeys);
      atKeyList?.deleteCompactedKeys(expiredKeys);
    }
  }

  /// Returns true if compaction is required, else false.
  /// Setting the compaction threshold to 50.
  /// TODO: Get 50 from config.
  bool _isCompactionRequired() {
    return keysToCompactCount >= 50;
  }

  ///Returns the list[CompactionSortedList] for a given key.
  CompactionSortedList? getEntries(var key) {
    return _commitLogEntriesMap[key];
  }
}
