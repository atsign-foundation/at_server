import '../../at_persistence_secondary_server.dart';

///Type to collect and store compaction statistics
class AtCompactionStats {
  late CompactionType compactionType;
  late DateTime lastCompactionRun;
  late Duration compactionDuration;
  late int sizeBeforeCompaction;
  late int sizeAfterCompaction;
  late int deletedKeysCount;

  ///maps predefined keys to their values which will be ready to encode to json
  Map toJson() => {
        'compaction_type': compactionType.toString(),
        'last_compaction_run': lastCompactionRun.toString(),
        'duration': compactionDuration.toString(),
        'size_before_compaction': sizeBeforeCompaction.toString(),
        'size_after_compaction': sizeAfterCompaction.toString(),
        'deleted_keys_count': deletedKeysCount.toString()
      };

  @override
  String toString() {
    return "compaction type: $compactionType \n..."
        "compaction last run at: $lastCompactionRun \n..."
        "compaction duration: $compactionDuration \n..."
        "size before compaction: $sizeBeforeCompaction \n..."
        "size after compaction: $sizeAfterCompaction \n..."
        "no. of keys deleted: $deletedKeysCount";
  }
}
