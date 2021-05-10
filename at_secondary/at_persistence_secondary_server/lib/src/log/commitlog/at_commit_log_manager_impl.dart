import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/commit_log_redis_keystore.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_utils/at_logger.dart';

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
  Future<AtCommitLog> getHiveCommitLog(String atSign,
      {String commitLogPath, bool enableCommitId = true}) async {
    //verify if an instance has been already created for the given instance.
    if (!_commitLogMap.containsKey(atSign)) {
      var commitLogKeyStore = CommitLogKeyStore(atSign);
      commitLogKeyStore.enableCommitId = enableCommitId;
      await commitLogKeyStore.init(commitLogPath);
      _commitLogMap[atSign] = AtCommitLog(commitLogKeyStore);
    }
    return _commitLogMap[atSign];
  }

  @override
  Future<AtCommitLog> getRedisCommitLog(String atSign, String url,
      {String password, bool enableCommitId = true}) async {
    //verify if an instance has been already created for the given instance.
    if (!_commitLogMap.containsKey(atSign)) {
      var commitLogKeyStore = CommitLogRedisKeyStore(atSign);
      commitLogKeyStore.enableCommitId = enableCommitId;
      await commitLogKeyStore.init(url, password: password);
      _commitLogMap[atSign] = AtCommitLog(commitLogKeyStore);
    }
    return _commitLogMap[atSign];
  }

  Future<void> close() async {
    await Future.forEach(
        _commitLogMap.values, (atCommitLog) => atCommitLog.close());
    _commitLogMap.clear();
  }

  void clear() {
    _commitLogMap.clear();
  }
}
