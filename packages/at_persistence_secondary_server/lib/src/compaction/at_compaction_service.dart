import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

class AtCompactionService {
  static final AtCompactionService _singleton = AtCompactionService._internal();

  AtCompactionService._internal();

  factory AtCompactionService.getInstance() {
    return _singleton;
  }

  AtCompactionStats atCompactionStats = AtCompactionStats();

  ///[atCompactionConfig] is an object containing compaction configuration/parameters
  ///[atLogType] specifies which logs the compaction job will run on
  ///Method chooses which type of compaction to be run based on [atCompactionConfig]
  Future<AtCompactionStats> executeCompaction(AtLogType atLogType) async {
    int dataTimeBeforeCompactionInMills =
        DateTime.now().toUtc().millisecondsSinceEpoch;
    int numberOfKeysBeforeCompaction = atLogType.entriesCount();
    await executeCompactionInternal(atLogType);
    int dataTimeAfterCompactionInMills =
        DateTime.now().toUtc().millisecondsSinceEpoch;
    int numberOfKeysAfterCompaction = atLogType.entriesCount();
    AtCompactionStats atCompactionStats = _generateStats(
        atLogType,
        dataTimeBeforeCompactionInMills,
        numberOfKeysBeforeCompaction,
        dataTimeAfterCompactionInMills,
        numberOfKeysAfterCompaction);
    return atCompactionStats;
  }

  Future<void> executeCompactionInternal(AtLogType atLogType) async {
    final keysToCompact = await atLogType.getKeysToDeleteOnCompaction();
    await atLogType.deleteKeyForCompaction(keysToCompact);
  }

  AtCompactionStats _generateStats(
      AtLogType atLogType,
      int dataTimeBeforeCompactionInMills,
      int numberOfKeysBeforeCompaction,
      int dataTimeAfterCompactionInMills,
      int numberOfKeysAfterCompaction) {
    _resetAtCompactionStats();
    atCompactionStats
      ..preCompactionEntriesCount = numberOfKeysBeforeCompaction
      ..postCompactionEntriesCount = numberOfKeysAfterCompaction
      ..compactionDuration =
          DateTime.fromMillisecondsSinceEpoch(dataTimeAfterCompactionInMills)
              .difference(DateTime.fromMillisecondsSinceEpoch(
                  dataTimeBeforeCompactionInMills))
      ..deletedKeysCount =
          (numberOfKeysBeforeCompaction - numberOfKeysAfterCompaction)
      ..lastCompactionRun = DateTime.now().toUtc()
      ..atCompaction = atLogType;
    return atCompactionStats;
  }

  _resetAtCompactionStats() {
    atCompactionStats
      ..preCompactionEntriesCount = -1
      ..postCompactionEntriesCount = -1
      ..deletedKeysCount = -1
      ..compactionDuration = Duration()
      ..lastCompactionRun = DateTime.now().toUtc();
  }
}
