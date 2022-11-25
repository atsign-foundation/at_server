import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_logger.dart';
import 'package:hive/hive.dart';

/// Class extending the [CommitLogKeyStore]
///
/// This class is specific to the Client SDK.
class AtClientCommitLogKeyStore extends CommitLogKeyStore {
  AtClientCommitLogKeyStore(String currentAtSign) : super(currentAtSign);

  final _logger = AtSignLogger('AtClientCommitLogKeyStore');

  /// Contains the entries that are last synced by the client SDK.
  /// The key represents the regex and value represents the [CommitEntry]
  final _lastSyncedEntryCacheMap = <String, CommitEntry>{};

  /// Updates the [commitEntry.commitId] with the given [commitId].
  ///
  /// This method is only called by the client(s) because when a key is created on the
  /// client side, a record is created in the [CommitLogKeyStore] with a null commitId.
  /// At the time of sync, a key is created/updated in cloud secondary server and generates
  /// the commitId; sends it back to client which the gets updated against the commitEntry
  /// of the key synced.
  ///
  @override
  Future<void> update(int commitId, CommitEntry? commitEntry) async {
    try {
      // Updates the commitId for the given commit entry
      await super.update(commitId, commitEntry);

      if (_lastSyncedEntryCacheMap.isEmpty) {
        return;
      }
      // Iterate through the regex's in the _lastSyncedEntryCacheMap.
      // Updates the commitEntry against the matching regexes.
      for (var regex in _lastSyncedEntryCacheMap.keys) {
        if (acceptKey(commitEntry!.atKey!, regex)) {
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

  /// Returns the list of commit entries greater than [sequenceNumber]
  /// throws [DataStoreException] if there is an exception getting the commit entries
  Future<List<CommitEntry>> getChanges(int sequenceNumber,
      {String? regex, int? limit}) async {
    var changes = <CommitEntry>[];
    var regexString = (regex != null) ? regex : '';
    var values = (await toMap()).values.toList();
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

    var commitLogMap = await toMap();
    var values = (commitLogMap.values.toList())..sort(_sortByCommitId);
    if (values.isEmpty) {
      return null;
    }

    // Returns the commitEntry with maximum commitId matching the given regex.
    // otherwise returns NullCommitEntry
    lastSyncedEntry = values.lastWhere(
        (entry) => (acceptKey(entry.atKey!, regex) && (entry.commitId != null)),
        orElse: () => NullCommitEntry());

    if (lastSyncedEntry is NullCommitEntry) {
      _logger.finer('Unable to fetch lastSyncedEntry. Returning null');
      return null;
    }

    _logger.finer(
        'Updating the lastSyncedEntry matching regex $regex to the cache. Returning lastSyncedEntry with key : ${lastSyncedEntry.atKey} and commitId ${lastSyncedEntry.commitId}');
    _lastSyncedEntryCacheMap.putIfAbsent(regex, () => lastSyncedEntry!);
    return lastSyncedEntry;
  }

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

  Future<CommitEntry> getLatestCommitEntry(String key) async {
    var values = (await toMap()).values.toList()..sort(compareCommitId);
    for (CommitEntry commitEntry in values) {
      if (commitEntry.atKey == key) {
        return commitEntry;
      }
    }
    return NullCommitEntry();
  }

  /// Sorts the commit entries in descending order.
  ///
  /// The CommitEntries with commitId 'null' comes before the commit entries with commitId
  int compareCommitId(commitEntry1, commitEntry2) {
    if (commitEntry1.commitId == null && commitEntry2.commitId == null) {
      return 0;
    }
    if (commitEntry1.commitId == null && commitEntry2.commitId != null) {
      return -1;
    }
    if (commitEntry1.commitId != null && commitEntry2.commitId == null) {
      return 1;
    }
    return commitEntry2.commitId!.compareTo(commitEntry1.commitId!);
  }

  ///Not a part of API. Exposed for Unit test
  List<CommitEntry> getLastSyncedEntryCacheMapValues() {
    return _lastSyncedEntryCacheMap.values.toList();
  }

  @override
  Future<List> getExpired(int expiryInDays) {
    throw UnimplementedError(
        'This not applicable for client. Applicable only on server');
  }
}
