import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:meta/meta.dart';

/// The [AtCompactionService] is runs on the [Keystore] and removes the oldest keys to
/// reduce the size of the Keystore.
///
/// The [executeCompaction] method is responsible for fetching the oldest keys and removing
/// from the keystore
///
/// The [_generateStats] method collects the metrics of the compaction and returns [AtCompactionStats]
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
    // Pre-compaction metrics
    int numberOfKeysBeforeCompaction = atLogType.entriesCount();
    int dateTimeBeforeCompactionInMills =
        DateTime.now().toUtc().millisecondsSinceEpoch;
    // Run compaction
    await executeCompactionInternal(atLogType);
    // Post-compaction metrics
    int dateTimeAfterCompactionInMills =
        DateTime.now().toUtc().millisecondsSinceEpoch;
    int numberOfKeysAfterCompaction = atLogType.entriesCount();
    // Sets the metrics to AtCompactionStats
    AtCompactionStats atCompactionStats = _generateStats(
        atLogType,
        dateTimeBeforeCompactionInMills,
        numberOfKeysBeforeCompaction,
        dateTimeAfterCompactionInMills,
        numberOfKeysAfterCompaction);
    return atCompactionStats;
  }

  /// Gets the keys to delete on compaction and removes from the keystore
  ///
  /// The [AtLogType] defines the type of Keystore to compaction (e.g. AtCommitLog, AtAccessLog)
  @visibleForTesting
  Future<void> executeCompactionInternal(AtLogType atLogType) async {
    final keysToCompact = await atLogType.getKeysToDeleteOnCompaction();
    await atLogType.deleteKeyForCompaction(keysToCompact);
  }

  AtCompactionStats _generateStats(
      AtLogType atLogType,
      int dateTimeBeforeCompactionInMills,
      int numberOfKeysBeforeCompaction,
      int dateTimeAfterCompactionInMills,
      int numberOfKeysAfterCompaction) {
    // Reset the compaction stats to clear the earlier stats metrics
    _resetAtCompactionStats();
    // Sets the compaction stats and return
    atCompactionStats
      ..preCompactionEntriesCount = numberOfKeysBeforeCompaction
      ..postCompactionEntriesCount = numberOfKeysAfterCompaction
      ..compactionDurationInMills =
          DateTime.fromMillisecondsSinceEpoch(dateTimeAfterCompactionInMills)
              .difference(DateTime.fromMillisecondsSinceEpoch(
                  dateTimeBeforeCompactionInMills))
              .inMilliseconds
      ..deletedKeysCount =
          (numberOfKeysBeforeCompaction - numberOfKeysAfterCompaction)
      ..lastCompactionRun = DateTime.now().toUtc()
      ..atCompactionType = atLogType.toString();
    return atCompactionStats;
  }

  /// Reset the state of the [AtCompactionStats]
  void _resetAtCompactionStats() {
    atCompactionStats
      ..preCompactionEntriesCount = -1
      ..postCompactionEntriesCount = -1
      ..deletedKeysCount = -1
      ..compactionDurationInMills = 0
      ..lastCompactionRun = DateTime.now().toUtc();
  }
}
