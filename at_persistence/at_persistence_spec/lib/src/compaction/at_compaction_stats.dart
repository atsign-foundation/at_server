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
        'compactionType': compactionType?.toString(),
        'lastCompactionRun': lastCompactionRun?.toString(),
        'duration': compactionDuration?.toString(),
        'preCompactionEntriesCount': preCompactionEntriesCount?.toString(),
        'postCompactionEntriesCount': postCompactionEntriesCount?.toString(),
        'deletedKeysCount': deletedKeysCount?.toString()
      };

  @override
  String toString() {
    return toJson().toString();
  }
}
