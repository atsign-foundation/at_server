import 'dart:math';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/compaction/at_compaction_service.dart';
import 'package:cron/cron.dart';

class AtCompactionJob {
  late Cron _cron;
  late ScheduledTask _schedule;
  AtCompaction _atCompaction;
  //instance of SecondaryPersistenceStore stored to be passed on to AtCompactionStatsImpl
  late final SecondaryPersistenceStore _secondaryPersistenceStore;
  static final Random _random = Random();

  AtCompactionJob(this._atCompaction, this._secondaryPersistenceStore);

  void scheduleCompactionJob(AtCompactionConfig atCompactionConfig) {
    var runFrequencyMins = atCompactionConfig.compactionFrequencyMins;
    _cron = Cron();
    _schedule =
        _cron.schedule(Schedule.parse('*/$runFrequencyMins * * * *'), () async {
      var compactionService = AtCompactionService.getInstance();
      // adding delay to randomize the cron jobs
      // Generates a random number between 0 and 12 and wait's for that many seconds.
      await Future.delayed(Duration(seconds: _random.nextInt(12)));
      compactionService.executeCompaction(
          atCompactionConfig, _atCompaction, _secondaryPersistenceStore);
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
