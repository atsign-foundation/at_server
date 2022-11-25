import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:hive/hive.dart';
import 'at_client_commit_log_keystore.dart';

/// The class implementing the [AtCommitLog].
///
/// When an [AtKey] is created/updated or deleted, a [CommitEntry] is created
/// with commitId set to null.
///
/// The [CommitEntry] with commitId's set null are termed as "Uncommitted entries" which indicates the
/// [CommitEntry.atKey] needs to be synced to cloud secondary.
///
/// A batch process will look for "Uncommitted entries" at a frequent intervals and syncs the keys to
/// the cloud secondary and updates the key's [CommitEntry.commitId] with the commitId returned by the
/// secondary server
class AtClientCommitLog extends AtCommitLog {
  final AtClientCommitLogKeyStore _atClientCommitLogKeyStore;

  AtClientCommitLog(this._atClientCommitLogKeyStore)
      : super(_atClientCommitLogKeyStore);

  /// Returns the list of commit entries greater than [sequenceNumber]
  /// throws [DataStoreException] if there is an exception getting the commit entries
  @override
  Future<List<CommitEntry>> getChanges(int? sequenceNumber, String? regex,
      {int? limit}) async {
    Future<List<CommitEntry>> changes;
    try {
      changes = _atClientCommitLogKeyStore.getChanges(sequenceNumber!,
          regex: regex, limit: limit);
    } on Exception catch (e) {
      throw DataStoreException('Exception getting changes:${e.toString()}');
    } on HiveError catch (e) {
      throw DataStoreException(
          'Hive error adding to commit log:${e.toString()}');
    }
    // ignore: unnecessary_null_comparison
    if (changes == null) {
      return [];
    }
    return changes;
  }

  /// Return the latest [CommitEntry] for the given key.
  ///
  /// If CommitEntry does not exist for the given key, [NullCommitEntry] is returned.
  @override
  Future<CommitEntry> getLatestCommitEntry(String key) async {
    return await _atClientCommitLogKeyStore.getLatestCommitEntry(key);
  }
}
