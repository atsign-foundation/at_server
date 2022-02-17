import 'package:at_persistence_spec/at_persistence_spec.dart';

///Type to collect and store compaction statistics
class AtCompactionStats {
  CompactionType? compactionType;
  late DateTime? lastCompactionRun;
  late Duration? compactionDuration;
  int? sizeBeforeCompaction;
  int? sizeAfterCompaction;
  int? deletedKeysCount;

  AtCompactionStats();

  ///maps predefined keys to their values which will be ready to encode to json
  Map toJson() => {
        'compaction_type': compactionType?.toString()  ,
        'last_compaction_run': lastCompactionRun?.toString(),
        'duration': compactionDuration?.toString(),
        'size_before_compaction': sizeBeforeCompaction?.toString(),
        'size_after_compaction': sizeAfterCompaction?.toString(),
        'deleted_keys_count': deletedKeysCount?.toString()
      };

  @override
  String toString() {
    return toJson().toString();
    //return "compaction type: $compactionType, compaction last run at: $lastCompactionRun, compaction duration: $compactionDuration, size before compaction: $sizeBeforeCompaction, size after compaction: $sizeAfterCompaction, no. of keys deleted: $deletedKeysCount";
  }
}
