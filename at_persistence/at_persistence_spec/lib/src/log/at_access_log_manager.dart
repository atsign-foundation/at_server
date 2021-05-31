import 'package:at_persistence_spec/src/compaction/at_compaction_strategy.dart';

/// Factory class. Responsible for returning instance of a AtCommitLog.
abstract class AtAccessLogManager {
  /// Retrieves an instance of AtAccessLog with Hive keystore.
  ///
  /// @return An instance of the AtAccessLog for the given atSign.
  Future<AtLogType> getHiveAccessLog(String atSign, {String accessLogPath});

  /// Retrieves an instance of AtAccessLog with redis keystore.
  ///
  /// @return An instance of the AtAccessLog for the given atSign.
  Future<AtLogType> getRedisAccessLog(String atSign, String url,
      {String password});
}
