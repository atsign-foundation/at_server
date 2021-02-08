import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/conf/at_persistence_secondary_config.dart';
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

  Map<String, AtCommitLog> _commitLogMap = {};

  @override
  Future<AtCommitLog> getCommitLog(String atSign,
      {String commitLogPath, bool enableCommitId = true}) async {
    //verify if an instance has been already created for the given instance.
    if (!_commitLogMap.containsKey(atSign)) {
      if (AtPersistenceSecondaryConfig.keyStore == 'redis') {
        var commitLogKeyStore = CommitLogRedisKeyStore(atSign);
        await commitLogKeyStore.init(commitLogPath);
        _commitLogMap[atSign] = AtCommitLog(commitLogKeyStore);
      } else {
        var commitLogKeyStore = CommitLogKeyStore(atSign);
        commitLogKeyStore.enableCommitId = enableCommitId;
        await commitLogKeyStore.init(commitLogPath);
        _commitLogMap[atSign] = AtCommitLog(commitLogKeyStore);
      }
    }
    return _commitLogMap[atSign];
  }

  void close() {
    _commitLogMap.forEach((key, value) {
      value.close();
    });
  }

  void clear() {
    _commitLogMap.clear();
  }
}
