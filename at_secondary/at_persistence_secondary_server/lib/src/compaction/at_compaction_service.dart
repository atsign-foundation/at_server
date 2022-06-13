import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/compaction/at_size_based_compaction.dart';
import 'package:at_persistence_secondary_server/src/compaction/at_time_based_compaction.dart';

class AtCompactionService {
  static final AtCompactionService _singleton = AtCompactionService._internal();

  AtCompactionService._internal();

  factory AtCompactionService.getInstance() {
    return _singleton;
  }

  late AtCompactionStatsService atCompactionStatsService;
  late AtCompactionStats? atCompactionStats;

  ///[atCompactionConfig] is an object containing compaction configuration/parameters
  ///[atLogType] specifies which logs the compaction job will run on
  ///Method chooses which type of compaction to be run based on [atCompactionConfig]
  Future<void> executeCompaction(
      AtCompactionConfig atCompactionConfig,
      AtLogType atLogType,
      SecondaryPersistenceStore secondaryPersistenceStore) async {
    var timeBasedCompactionConfigured =
        atCompactionConfig.timeBasedCompaction();
    var sizeBasedCompactionConfigured =
        atCompactionConfig.sizeBasedCompaction();
    atCompactionStatsService =
        AtCompactionStatsServiceImpl(atLogType, secondaryPersistenceStore);

    // Check if any of the compaction strategy's configured.
    // If none of the are configured return.
    if ((timeBasedCompactionConfigured || sizeBasedCompactionConfigured) ==
        false) {
      // Log no compaction strategy is configured. Which means logs will live for ever.
      return;
    }

    // Time based compaction is configured
    if (timeBasedCompactionConfigured) {
      // If the are logs that met the time criteria delete them.
      var timeBasedCompaction = TimeBasedCompaction(
          atCompactionConfig.timeInDays,
          atCompactionConfig.compactionPercentage);
      atCompactionStats =
          await timeBasedCompaction.performCompaction(atLogType);
      //write compaction statistics returned by timeBasedCompaction into keystore
      await atCompactionStatsService.handleStats(atCompactionStats);
    }

    // Size based compaction is configured
    // When both are configured we have to run both.
    if (sizeBasedCompactionConfigured) {
      // If the are logs that met the size criteria delete them.
      var sizeBasedCompaction = SizeBasedCompaction(
          atCompactionConfig.sizeInKB, atCompactionConfig.compactionPercentage);
      atCompactionStats =
          (await sizeBasedCompaction.performCompaction(atLogType));
      //write compaction statistics returned by sizeBasedCompaction into keystore
      await atCompactionStatsService.handleStats(atCompactionStats);
    }
  }
}
