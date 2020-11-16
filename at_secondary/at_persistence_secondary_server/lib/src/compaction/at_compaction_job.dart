import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:cron/cron.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/src/compaction/at_compaction_service.dart';

class AtCompactionJob {
  static final AtCompactionJob _singleton = AtCompactionJob._internal();

  AtCompactionJob._internal();

  factory AtCompactionJob.getInstance() {
    return _singleton;
  }

  void scheduleCompactionJob(
      AtCompactionConfig atCompactionConfig, AtLogType atLogType) {
    var runFrequencyMins = atCompactionConfig.compactionFrequencyMins;
    var cron = Cron();
    cron.schedule(Schedule.parse('*/${runFrequencyMins} * * * *'), () async {
      var compactionService = AtCompactionService.getInstance();
      await compactionService.executeCompaction(atCompactionConfig, atLogType);
    });
  }
}
