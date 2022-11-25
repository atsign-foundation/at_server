import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:hive/hive.dart';
import 'at_server_commit_log_keystore.dart';

/// The class implementing the [AtCommitLog].
///
/// When an [AtKey] is created/updated or deleted, a [CommitEntry] is created
/// with commitId set to auto-incremented integer.
class AtServerCommitLog extends AtCommitLog {
  final AtServerCommitLogKeyStore _atServerCommitLogKeyStore;

  AtServerCommitLog(this._atServerCommitLogKeyStore)
      : super(_atServerCommitLogKeyStore);

  /// Returns the list of commit entries greater than [sequenceNumber]
  /// throws [DataStoreException] if there is an exception getting the commit entries
  @override
  Future<List<CommitEntry>> getChanges(int? sequenceNumber, String? regex,
      {int? limit}) async {
    Future<List<CommitEntry>> changes;
    try {
      changes = _atServerCommitLogKeyStore.getChanges(sequenceNumber!,
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

  @override
  Future<void> update(CommitEntry commitEntry, int commitId) {
    // TODO: implement update
    throw UnimplementedError();
  }

  @override
  CommitEntry getLatestCommitEntry(String key) {
    return _atServerCommitLogKeyStore.getLatestCommitEntry(key);
  }
}
