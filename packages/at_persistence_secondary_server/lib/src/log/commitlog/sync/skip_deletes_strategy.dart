import 'package:at_persistence_secondary_server/src/log/commitlog/commit_entry.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/sync/sync_keys_fetch_strategy.dart';

/// Returns the commit entries to be returned in sync response from server to client except delete commit entries.
class SkipDeleteStrategy extends SyncKeysFetchStrategy {
  late int skipDeletesUntil;
  late int latestCommitId;
  SkipDeleteStrategy(this.skipDeletesUntil, this.latestCommitId);
  @override
  bool shouldIncludeEntryInSyncResponse(
      CommitEntry commitEntry, int commitId, String regex,
      {List<String>? enrolledNamespace}) {
    // do not include delete commit entries between commitId and skipDeletesUntil,  except when delete is the last commit entry
    if (commitEntry.operation == CommitOp.DELETE &&
        commitEntry.commitId! <= skipDeletesUntil &&
        commitEntry.commitId! >= commitId &&
        commitEntry.commitId != latestCommitId) {
      return false;
    }
    return commitEntry.commitId! >= commitId &&
        super.shouldIncludeKeyInSyncResponse(commitEntry.atKey!, regex,
            enrolledNamespace: enrolledNamespace);
  }
}
