import 'dart:convert';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/commit_entry.dart';
import 'package:dartis/dartis.dart' as redis;

/// Class implementing the redis key store.
class CommitLogRedisKeyStore implements LogKeyStore<int, CommitEntry> {
  final logger = AtSignLogger('CommitLogRedisKeyStore');

  bool enableCommitId = true;
  var redis_client;
  var redis_commands;
  final COMMIT_LOG = 'at_commit_log';
  String storagePath;
  final _currentAtSign;

  CommitLogRedisKeyStore(this._currentAtSign);

  /// Initializes the redis key store.
  Future<void> init(String url, {String password}) async {
    var success = false;
    try {
      // Connects.
      redis_client = await redis.Client.connect(url);
      // Runs some commands.
      redis_commands = redis_client.asCommands<String, String>();
      await redis_commands.auth(password);
    } on Exception catch (e) {
      logger.severe('AtPersistence.init exception: ' + e.toString());
      throw DataStoreException(
          'Exception initializing secondary keystore manager: ${e.toString()}');
    }
    return success;
  }

  /// Adds entry to commit log persistent store.
  @override
  Future add(commitEntry) async {
    var internalKey;
    try {
      var value =
          (commitEntry != null) ? json.encode(commitEntry.toJson()) : null;
      if (value == null) {
        return internalKey;
      }
      internalKey = await redis_commands.rpush(COMMIT_LOG, value: value);
      logger.info(
          'CommitLog InternalKey $internalKey, ${internalKey.runtimeType}');
      //set the hive generated key as commit id
      if (enableCommitId) {
        commitEntry.commitId = internalKey - 1;
        var value =
            (commitEntry != null) ? json.encode(commitEntry.toJson()) : null;
        // update entry with commitId
        await redis_commands.lset(COMMIT_LOG, internalKey - 1, value);
      }
    } on Exception catch (e) {
      throw DataStoreException('Exception updating entry:${e.toString()}');
    }
    return internalKey - 1;
  }

  /// Returns the total number of keys
  /// @return - int : Returns number of keys in commit log
  @override
  Future<int> entriesCount() async {
    var totalKeys = 0;
    totalKeys = await redis_commands.llen(COMMIT_LOG);
    return totalKeys;
  }

  /// Returns the [CommitEntry] for the specified key,
  @override
  Future<CommitEntry> get(int key) async {
    try {
      var commitEntry;
      var value = await redis_commands.lrange(COMMIT_LOG, key, key);
      if (value == null) {
        return commitEntry;
      }
      var value_json = (value != null) ? json.decode(value) : null;
      commitEntry = CommitEntry.fromJson(value_json);
      return commitEntry;
    } on Exception catch (e) {
      throw DataStoreException('Exception get entry:${e.toString()}');
    }
  }

  /// Returns all the expired keys in the at_commit_log before the number of days sepcified.
  /// @param expiryInDays: Accepts an integer value
  @override
  Future<List> getExpired(int expiryInDays) async {
    var expiredKeys = {};
    var now = DateTime.now().toUtc();
    var values = await redis_commands.lrange(COMMIT_LOG, 0, -1);

    /// Iterates on each commit entry in at_commit_log instance.
    for (var entry in values) {
      var value = CommitEntry.fromJson(json.decode(entry));

      /// If the date-time of commit entry is before the expiry date, the entry is added to expiredKeys.
      if (value.opTime != null &&
          value.opTime.isBefore(now.subtract(Duration(days: expiryInDays)))) {
        expiredKeys.putIfAbsent(values.indexOf(entry), () => value);
      }
    }
    // If expiredKeys isEmpty, return null.
    if (expiredKeys.isEmpty) {
      return null;
    }
    return getDuplicateEntries(expiredKeys);
  }

  /// Returns the first N entries from commit log persistent store
  @override
  Future<List> getFirstNEntries(int N) async {
    var expiredKeys = {};
    try {
      var values = await redis_commands.lrange(COMMIT_LOG, 0, N - 1);
      for (var entry in values) {
        var value = CommitEntry.fromJson(json.decode(entry));
        expiredKeys.putIfAbsent(values.indexOf(entry), () => value);
      }
      return getDuplicateEntries(expiredKeys);
    } on Exception catch (e) {
      throw DataStoreException(
          'Exception getting first N entries:${e.toString()}');
    }
  }

  /// Returns of the size of the commit log
  @override
  Future<int> getSize() async {
    //Returning number of entries
    var logSize = await redis_commands.llen(COMMIT_LOG);
    return logSize;
  }

  ///Removes the key from commit log persistent store
  @override
  Future<void> remove(int key) async {
    try {
      var value = await redis_commands.lrange(COMMIT_LOG, key, key);
      if (value != null && value.isNotEmpty) {
        await redis_commands.lrem(COMMIT_LOG, 1, value[0]);
      }
    } on Exception catch (e) {
      throw DataStoreException('Exception deleting entry:${e.toString()}');
    }
  }

  @override
  Future update(int commitId, CommitEntry commitEntry) async {
    try {
      commitEntry.commitId = commitId;
      var value = json.encode(commitEntry.toJson());
      await redis_commands.lset(COMMIT_LOG, commitId, value);
    } on Exception catch (e) {
      throw DataStoreException('Exception updating entry:${e.toString()}');
    }
  }

  /// Closes the [commitLogKeyStore] instance.
  void close() async {
    await redis_client.close();
  }

  /// Returns the first committed sequence number
  int firstCommittedSequenceNumber() {
    var firstCommittedSequenceNum = 0;
    return firstCommittedSequenceNum;
  }

  /// Returns the duplicate commit entries
  List getDuplicateEntries(Map commitLogMap) {
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
      {String regex}) async {
    var changes = <CommitEntry>[];
    var regexString = (regex != null) ? regex : '';
    try {
      var values = await redis_commands.lrange(COMMIT_LOG, 0, -1);
      if (values == null || values.isEmpty) {
        return changes;
      }
      for (var f in values) {
        var commitEntry = CommitEntry.fromJson(json.decode(f));
        var atKey = commitEntry.atKey;
        if (commitEntry != null && _isRegexMatches(atKey, regexString)) {
          changes.add(commitEntry);
        }
      }
    } on Exception catch (e) {
      throw DataStoreException('Exception getting changes:${e.toString()}');
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

  /// Returns the latest committed sequence number
  Future<int> lastCommittedSequenceNumber() async {
    var lastCommittedSequenceNum = await redis_commands.llen(COMMIT_LOG);
    return lastCommittedSequenceNum - 1;
  }

  /// Returns the latest committed sequence number with regex
  Future<int> lastCommittedSequenceNumberWithRegex(String regex) async {
    var lastCommittedEntry;
    var values = await redis_commands.lrange(COMMIT_LOG, 0, -1);
    for (var value in values) {
      var entry = CommitEntry.fromJson(json.decode(value));
      if (_isRegexMatches(entry.atKey, regex)) {
        lastCommittedEntry = entry;
      }
    }
    var lastCommittedSequenceNum =
        (lastCommittedEntry != null) ? lastCommittedEntry.key : null;
    return lastCommittedSequenceNum;
  }

  /// Returns the last synced commit entry
  Future<CommitEntry> lastSyncedEntry({String regex}) async {
    var lastSyncedEntry;
    if (regex != null) {
      var values = await redis_commands.lrange(COMMIT_LOG, 0, -1);
      for (var value in values) {
        var entry = CommitEntry.fromJson(json.decode(value));
        if (_isRegexMatches(entry.atKey, regex) && (entry.commitId != null)) {
          lastSyncedEntry = entry;
        }
      }
    } else {
      var values = await redis_commands.lrange(COMMIT_LOG, 0, -1);
      for (var value in values) {
        var entry = CommitEntry.fromJson(json.decode(value));
        if (entry.commitId != null) {
          lastSyncedEntry = entry;
        }
      }
    }
    return lastSyncedEntry;
  }
}
