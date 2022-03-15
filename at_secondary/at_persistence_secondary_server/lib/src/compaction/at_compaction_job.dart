import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/compaction/at_compaction_service.dart';
import 'package:at_utils/at_logger.dart';
import 'package:cron/cron.dart';

class AtCompactionJob {
  late Cron _cron;
  AtLogType atLogType;
  //instance of SecondaryPersistenceStore stored to be passed on to AtCompactionStatsImpl
  late SecondaryPersistenceStore _secondaryPersistenceStore;
  var logger = AtSignLogger('AtCompactionJob');

  AtCompactionJob(this.atLogType, this._secondaryPersistenceStore);

  void scheduleCompactionJob(AtCompactionConfig atCompactionConfig) {
    var runFrequencyMins = atCompactionConfig.compactionFrequencyMins;
    _cron = Cron();
    _cron.schedule(Schedule.parse('*/$runFrequencyMins * * * *'), () async {
      var compactionService = AtCompactionService.getInstance();
      logger.finer('booooooooooooooooooooooooooink');
      compactionService.executeCompaction(
          atCompactionConfig, atLogType, _secondaryPersistenceStore);
    });
  }

  void close() {
    _cron.close();
  }
}
