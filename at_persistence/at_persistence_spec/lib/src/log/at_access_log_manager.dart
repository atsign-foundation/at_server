import 'package:at_persistence_spec/src/compaction/at_compaction_strategy.dart';

/// Factory class. Responsible for returning instance of a AtCommitLog.
abstract class AtAccessLogManager {
  /// Retrieves an instance of AtCommitLog.
  ///
  /// @return An instance of the AtCommitLog for the given atSign.
  Future<AtLogType?> getAccessLog(String atSign, {String? accessLogPath});
}
