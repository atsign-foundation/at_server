import 'package:at_persistence_spec/at_persistence_spec.dart';

///Type to collect and store compaction statistics
class AtCompactionStats {
  CompactionType? compactionType;
  late DateTime? lastCompactionRun;
  late Duration? compactionDuration;
  int? preCompactionEntriesCount;
  int? postCompactionEntriesCount;
  int? deletedKeysCount;

  AtCompactionStats();

  ///maps predefined keys to their values which will be ready to encode to json
  Map toJson() => {
        'compaction_type': compactionType?.toString(),
        'last_compaction_run': lastCompactionRun?.toString(),
        'duration': compactionDuration?.toString(),
        'size_before_compaction': preCompactionEntriesCount?.toString(),
        'size_after_compaction': postCompactionEntriesCount?.toString(),
        'deleted_keys_count': deletedKeysCount?.toString()
      };

  @override
  String toString() {
    return toJson().toString();
  }
}
