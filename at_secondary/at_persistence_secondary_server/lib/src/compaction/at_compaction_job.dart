import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/compaction/at_compaction_service.dart';
import 'package:cron/cron.dart';

class AtCompactionJob {
  static const server = AtServerAnnotation();
  late Cron _cron;
  late ScheduledTask _schedule;
  AtLogType atLogType;
  //instance of SecondaryPersistenceStore stored to be passed on to AtCompactionStatsImpl
  late final SecondaryPersistenceStore _secondaryPersistenceStore;

  AtCompactionJob(this.atLogType, this._secondaryPersistenceStore);

  @server
  void scheduleCompactionJob(AtCompactionConfig atCompactionConfig) {
    var runFrequencyMins = atCompactionConfig.compactionFrequencyMins;
    _cron = Cron();
    _schedule =
        _cron.schedule(Schedule.parse('*/$runFrequencyMins * * * *'), () async {
      var compactionService = AtCompactionService.getInstance();
      compactionService.executeCompaction(
          atCompactionConfig, atLogType, _secondaryPersistenceStore);
    });
  }

  @server
  void close() {
    _cron.close();
  }
}
