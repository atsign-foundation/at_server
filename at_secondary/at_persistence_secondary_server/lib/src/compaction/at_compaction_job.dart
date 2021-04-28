import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/compaction/at_compaction_service.dart';
import 'package:at_utils/at_logger.dart';
import 'package:cron/cron.dart';

class AtCompactionJob {
  Cron _cron;
  AtLogType atLogType;

  AtCompactionJob(this.atLogType);

  void scheduleCompactionJob(AtCompactionConfig atCompactionConfig) {
    var runFrequencyMins = atCompactionConfig.compactionFrequencyMins;
    _cron = Cron();
    _cron.schedule(Schedule.parse('*/$runFrequencyMins * * * *'), () async {
      AtSignLogger(runtimeType.toString()).severe('$atLogType starting');
      var compactionService = AtCompactionService.getInstance();
      compactionService.executeCompaction(atCompactionConfig, atLogType);
    });
  }

  void close() {
    _cron.close();
  }
}
