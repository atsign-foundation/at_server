import 'dart:math';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/compaction/at_compaction_service.dart';
import 'package:cron/cron.dart';

class AtCompactionJob {
  final Cron _cron = Cron();
  late ScheduledTask _schedule;
  late AtCompactionService atCompactionService;
  late AtCompactionStatsService atCompactionStatsService;
  final AtLogType _atLogType;

  //instance of SecondaryPersistenceStore stored to be passed on to AtCompactionStatsImpl
  late final SecondaryPersistenceStore secondaryPersistenceStore;
  static final Random _random = Random();

  AtCompactionJob(this._atLogType, this.secondaryPersistenceStore);

  void scheduleCompactionJob(AtCompactionConfig atCompactionConfig) {
    var runFrequencyInMins = atCompactionConfig.compactionFrequencyInMins;
    _schedule = _cron.schedule(Schedule.parse('*/$runFrequencyInMins * * * *'),
        () async {
      atCompactionService = AtCompactionService.getInstance();
      atCompactionStatsService =
          AtCompactionStatsServiceImpl(_atLogType, secondaryPersistenceStore);
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
    await _schedule.cancel();
  }

  //Method to stop compaction and also close the Cron instance.
  void close() {
    _cron.close();
  }
}
