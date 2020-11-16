import 'dart:io';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/commit_entry.dart';
import 'package:hive/hive.dart';
import 'package:at_utils/at_logger.dart';

class CommitLogKeyStore implements LogKeyStore<int, CommitEntry> {
  static final CommitLogKeyStore _singleton = CommitLogKeyStore._internal();

  CommitLogKeyStore._internal();

  factory CommitLogKeyStore.getInstance() {
    return _singleton;
  }

  var logger = AtSignLogger('CommitLogKeyStore');
  bool _registerAdapters = false;
  bool enableCommitId = true;
  Box box;
  String storagePath;

  void init(String boxName, String storagePath) async {
    Hive.init(storagePath);
    if (!_registerAdapters) {
      Hive.registerAdapter(CommitEntryAdapter());
      Hive.registerAdapter(CommitOpAdapter());
      _registerAdapters = true;
    }
    this.storagePath = storagePath;
    box = await Hive.openBox(boxName,
        compactionStrategy: (entries, deletedEntries) {
      return deletedEntries > 1;
    });
    var lastCommittedSequenceNum = lastCommittedSequenceNumber();
    logger.finer('last committed sequence: ${lastCommittedSequenceNum}');
  }

  @override
  Future<CommitEntry> get(int commitId) async {
    try {
      var commitEntry = await box.get(commitId);
      return commitEntry;
    } on Exception catch (e) {
      throw DataStoreException('Exception get entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error getting entry from commit log:${e.toString()}');
    }
  }

  @override
  Future<int> add(CommitEntry commitEntry) async {
    var internalKey;
    try {
      internalKey = await box.add(commitEntry);
      //set the hive generated key as commit id
      if (enableCommitId) {
        commitEntry.commitId = internalKey;
        // update entry with commitId
        await box.put(internalKey, commitEntry);
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
  Future update(int commitId, CommitEntry commitEntry) async {
    try {
      commitEntry.commitId = commitId;
      await box.put(commitEntry.key, commitEntry);
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
      await box.delete(commitId);
    } on Exception catch (e) {
      throw DataStoreException('Exception deleting entry:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error deleting entry from commit log:${e.toString()}');
    }
  }

  /// Returns the latest committed sequence number
  int lastCommittedSequenceNumber() {
    var lastCommittedSequenceNum = box.keys.isNotEmpty ? box.keys.last : null;
    return lastCommittedSequenceNum;
  }

  CommitEntry lastSyncedEntry() {
    var lastSyncedEntry = box.values
        .lastWhere((entry) => entry.commitId != null, orElse: () => null);
    return lastSyncedEntry;
  }

  /// Returns the first committed sequence number
  int firstCommittedSequenceNumber() {
    var firstCommittedSequenceNum = box.keys.isNotEmpty ? box.keys.first : null;
    return firstCommittedSequenceNum;
  }

  /// Returns the total number of keys
  /// @return - int : Returns number of keys in access log
  @override
  int entriesCount() {
    var totalKeys = 0;
    totalKeys = box?.keys?.length;
    return totalKeys;
  }

  /// Gets the first 'N' keys from the logs
  /// @param - N : The integer to get the first 'N'
  /// @return List of first 'N' keys from the log
  @override
  List getFirstNEntries(int N) {
    var entries = [];
    try {
      entries = box.keys.toList().take(N).toList();
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
      box.deleteAll(expiredKeys);
    }
  }

  @override
  int getSize() {
    var logSize = 0;
    var logLocation = Directory(storagePath);

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
  List getExpired(int expiryInDays) {
    // TODO: implement getExpired
    return null;
  }

  /// Returns the list of commit entries greater than [sequenceNumber]
  /// throws [DataStoreException] if there is an exception getting the commit entries
  List<CommitEntry> getChanges(int sequenceNumber) {
    var changes = <CommitEntry>[];
    try {
      var keys = box.keys;
      if (keys == null || keys.isEmpty) {
        return changes;
      }
      // If sequence number is -1 return all keys from commit log.
      if (sequenceNumber == -1) {
        sequenceNumber = keys.first;
      }
      var startKey = sequenceNumber + 1;
      box
          .valuesBetween(startKey: startKey, endKey: keys.last)
          .forEach((f) => changes.add(f));
    } on Exception catch (e) {
      throw DataStoreException('Exception getting changes:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to commit log:${e.toString()}');
    }
    return changes;
  }
}
