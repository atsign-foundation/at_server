import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/client/at_client_commit_log_keystore.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/server/at_server_commit_log.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/server/at_server_commit_log_keystore.dart';
import 'package:at_utils/at_logger.dart';

import 'client/at_client_commit_log.dart';

class AtCommitLogManagerImpl implements AtCommitLogManager {
  static final AtCommitLogManagerImpl _singleton =
      AtCommitLogManagerImpl._internal();

  AtCommitLogManagerImpl._internal();

  factory AtCommitLogManagerImpl.getInstance() {
    return _singleton;
  }

  var logger = AtSignLogger('AtCommitLogManagerImpl');

  final Map<String, AtCommitLog> _commitLogMap = {};

  @override
  Future<AtCommitLog?> getCommitLog(String atSign,
      {String? commitLogPath, bool enableCommitId = true}) async {
    //verify if an instance has been already created for the given instance.
    if (!_commitLogMap.containsKey(atSign)) {
      CommitLogKeyStore commitLogKeyStore =
          _getCommitLogKeyStore(enableCommitId, atSign);
      commitLogKeyStore.enableCommitId = enableCommitId;
      //TODO: If commitlog path is null, can we have default path and initialize commit log?
      if (commitLogPath != null) {
        await commitLogKeyStore.init(commitLogPath, isLazy: false);
      }
      _commitLogMap[atSign] =
          _getCommitLogInstance(enableCommitId, commitLogKeyStore);
    }
    return _commitLogMap[atSign];
  }

  CommitLogKeyStore _getCommitLogKeyStore(bool enableCommitId, String atSign) {
    if (enableCommitId == true) {
      return AtServerCommitLogKeyStore(atSign);
    }
    return AtClientCommitLogKeyStore(atSign);
  }

  AtCommitLog _getCommitLogInstance(
      bool enableCommitId, CommitLogKeyStore commitLogKeyStore) {
    if (enableCommitId == true) {
      return AtServerCommitLog(commitLogKeyStore as AtServerCommitLogKeyStore);
    }
    return AtClientCommitLog(commitLogKeyStore as AtClientCommitLogKeyStore);
  }

  Future<void> close() async {
    await Future.forEach(
        _commitLogMap.values, (AtCommitLog atCommitLog) => atCommitLog.close());
    _commitLogMap.clear();
  }

  void clear() {
    _commitLogMap.clear();
  }
}
