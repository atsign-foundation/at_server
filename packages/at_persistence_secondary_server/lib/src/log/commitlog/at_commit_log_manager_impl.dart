import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

class AtCommitLogManagerImpl implements AtCommitLogManager {
  static final AtCommitLogManagerImpl _singleton =
      AtCommitLogManagerImpl._internal();

  AtCommitLogManagerImpl._internal();

  @Deprecated(
      'Use HiveAtPersistenceFactory (or any AtPersistenceFactory) and '
      'inject `bundle.commitLog` instead. Will be removed in the next '
      'major release.')
  factory AtCommitLogManagerImpl.getInstance() {
    return _singleton;
  }

  final Map<String, HiveAtCommitLog> _commitLogMap = {};

  @override
  Future<HiveAtCommitLog?> getCommitLog(String atSign,
      {String? commitLogPath, bool enableCommitId = true}) async {
    //verify if an instance has been already created for the given instance.
    if (!_commitLogMap.containsKey(atSign)) {
      CommitLogKeyStore? commitLogKeyStore;
      // Creating commit-log for client
      if (enableCommitId) {
        commitLogKeyStore = CommitLogKeyStore(atSign);
        _commitLogMap[atSign] = HiveAtCommitLog(commitLogKeyStore);
      } else {
        commitLogKeyStore = ClientCommitLogKeyStore(atSign);
        _commitLogMap[atSign] = HiveClientAtCommitLog(commitLogKeyStore);
      }
      if (commitLogPath != null) {
        await commitLogKeyStore.init(commitLogPath, isLazy: false);
      }
    }
    return _commitLogMap[atSign];
  }

  Future<void> close() async {
    await Future.forEach(
        _commitLogMap.values, (HiveAtCommitLog atCommitLog) => atCommitLog.close());
    _commitLogMap.clear();
  }

  void clear() {
    _commitLogMap.clear();
  }
}
