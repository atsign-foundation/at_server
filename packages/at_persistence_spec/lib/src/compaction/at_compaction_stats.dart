import 'dart:convert';

import 'package:at_persistence_spec/at_persistence_spec.dart';

///Type to collect and store compaction statistics
class AtCompactionStats {
  @Deprecated('Use AtCompaction')
  CompactionType? compactionType;
  late String atCompactionType;
  late DateTime lastCompactionRun;
  late int compactionDurationInMills;
  late int preCompactionEntriesCount;
  late int postCompactionEntriesCount;
  late int deletedKeysCount;

  AtCompactionStats();

  ///maps predefined keys to their values which will be ready to encode to json
  Map toJson() => {
        AtCompactionConstants.atCompactionType: atCompactionType,
        AtCompactionConstants.lastCompactionRun: lastCompactionRun.toString(),
        AtCompactionConstants.compactionDurationInMills:
            compactionDurationInMills.toString(),
        AtCompactionConstants.preCompactionEntriesCount:
            preCompactionEntriesCount.toString(),
        AtCompactionConstants.postCompactionEntriesCount:
            postCompactionEntriesCount.toString(),
        AtCompactionConstants.deletedKeysCount: deletedKeysCount.toString()
      };

  @override
  String toString() {
    return jsonEncode(toJson());
  }
}

class AtCompactionConstants {
  static const atCompactionType = 'atCompactionType';
  static const lastCompactionRun = 'lastCompactionRun';
  static const compactionDurationInMills = 'compactionDurationInMills';
  static const preCompactionEntriesCount = 'preCompactionEntriesCount';
  static const postCompactionEntriesCount = 'postCompactionEntriesCount';
  static const deletedKeysCount = 'deletedKeysCount';
}
