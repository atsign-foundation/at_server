import 'package:at_persistence_spec/src/compaction/at_compaction_strategy.dart';

/// Factory class. Responsible for returning instance of a AtCommitLog.
abstract class AtCommitLogManager {
  /// Retrieves an instance of AtCommitLog with hive as keystore.
  ///
  /// @return An instance of the AtCommitLog for the given atSign.
  Future<AtLogType> getHiveCommitLog(String atSign,
      {String commitLogPath, bool enableCommitId = true});

  /// Retrieves an instance of AtCommitLog with redis as keystore.
  ///
  /// @return An instance of the AtCommitLog for the given atSign.
  Future<AtLogType> getRedisCommitLog(String atSign, String url,
      {String password, bool enableCommitId = true});
}
