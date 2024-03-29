import 'dart:math';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:cron/cron.dart';

/// The class responsible for the triggering the compaction job.
///
/// The configurations for the compaction job can be set in [AtCompactionConfig]
/// The [AtCompactionConfig.compactionFrequencyInMins] defines the time interval of the compaction job
/// The [AtCompactionConfig.compactionPercentage] defines the amount of keystore to shrink.
///
/// The [AtCompactionStats] contains the metrics of the compaction job.
class AtCompactionJob {
  final Cron _cron = Cron();
  ScheduledTask? _schedule;
  late AtCompactionService atCompactionService;
  late AtCompactionStatsService atCompactionStatsService;
  final AtLogType _atLogType;

  //instance of SecondaryPersistenceStore stored to be passed on to AtCompactionStatsImpl
  late final SecondaryPersistenceStore _secondaryPersistenceStore;
  static final Random _random = Random();

  AtCompactionJob(this._atLogType, this._secondaryPersistenceStore);

  /// Triggers the compaction job.
  ///
  /// Accepts [AtCompactionConfig] that contains the configurations required for the compaction job
  /// The [AtCompactionConfig.compactionFrequencyInMins] defines the time interval of the compaction job
  /// The [AtCompactionConfig.compactionPercentage] defines the amount of keystore to shrink.
  void scheduleCompactionJob(AtCompactionConfig atCompactionConfig) {
    var runFrequencyInMins = atCompactionConfig.compactionFrequencyInMins;
    _schedule = _cron.schedule(Schedule.parse('*/$runFrequencyInMins * * * *'),
        () async {
      atCompactionService = AtCompactionService.getInstance();
      atCompactionStatsService =
          AtCompactionStatsServiceImpl(_atLogType, _secondaryPersistenceStore);
      // adding delay to randomize the cron jobs
      // Generates a random number between 0 and 12 and wait's for that many seconds.
      await Future.delayed(Duration(seconds: _random.nextInt(12)));
      _atLogType.setCompactionConfig(atCompactionConfig);
      AtCompactionStats atCompactionStats =
          await atCompactionService.executeCompaction(_atLogType);
      await atCompactionStatsService.handleStats(atCompactionStats);
    });
  }

  //Method to cancel the current schedule. The Cron instance is not close and can be re-used
  Future<void> stopCompactionJob() async {
    await _schedule?.cancel();
    _schedule = null;
  }

  //Method to stop compaction and also close the Cron instance.
  void close() {
    _cron.close();
  }

  /// Returns true if the compaction job is not running, else returns false.
  bool isScheduled() {
    return _schedule != null;
  }
}
