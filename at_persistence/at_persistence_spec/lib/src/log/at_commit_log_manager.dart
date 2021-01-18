import 'package:at_persistence_spec/src/compaction/at_compaction_strategy.dart';

/// Factory class. Responsible for returning instance of a AtCommitLog.
abstract class AtCommitLogManager {
  /// Retrieves an instance of AtCommitLog.
  ///
  /// @return An instance of the AtCommitLog for the given atSign.
  Future<AtLogType> getCommitLog(String atSign,
      {String commitLogPath, bool enableCommitId = true});
}
