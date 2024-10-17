import 'package:at_persistence_secondary_server/src/log/commitlog/commit_entry.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/sync/sync_keys_fetch_strategy.dart';

class SkipDeleteStrategy extends SyncKeysFetchStrategy {
  @override
  bool shouldIncludeEntryInSyncResponse(
      CommitEntry commitEntry, int commitId, String regex,
      {List<String>? enrolledNamespace}) {
    return commitEntry.commitId! >= commitId &&
        super.shouldIncludeKeyInSyncResponse(commitEntry.atKey!, regex,
            enrolledNamespace: enrolledNamespace) &&
        commitEntry.operation != CommitOp.DELETE;
  }
}
