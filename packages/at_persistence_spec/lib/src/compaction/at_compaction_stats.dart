import 'dart:convert';

import 'package:at_persistence_spec/at_persistence_spec.dart';

///Type to collect and store compaction statistics
class AtCompactionStats {
  @Deprecated('Use AtCompaction')
  CompactionType? compactionType;
  late AtCompaction atCompaction;
  late DateTime lastCompactionRun;
  late Duration compactionDuration;
  late int preCompactionEntriesCount;
  late int postCompactionEntriesCount;
  late int deletedKeysCount;

  AtCompactionStats();

  ///maps predefined keys to their values which will be ready to encode to json
  Map toJson() => {
        'compactionType': compactionType?.toString(),
        'atCompaction': atCompaction.toString(),
        'lastCompactionRun': lastCompactionRun.toString(),
        'duration': compactionDuration.toString(),
        'preCompactionEntriesCount': preCompactionEntriesCount.toString(),
        'postCompactionEntriesCount': postCompactionEntriesCount.toString(),
        'deletedKeysCount': deletedKeysCount.toString()
      };

  @override
  String toString() {
    return jsonEncode(toJson());
  }
}

class AtCompactionConstants {
  static final compactionType = 'compactionType';
}
