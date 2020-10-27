import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_logger.dart';
import 'package:cron/cron.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/src/compaction//at_compaction_service.dart';

class AtCompactionJob {
  static final AtCompactionJob _singleton = AtCompactionJob._internal();

  AtCompactionJob._internal();

  factory AtCompactionJob.getInstance() {
    return _singleton;
  }

  final logger = AtSignLogger('AtCompactionJob');

  void scheduleCompactionJob(
      AtCompactionConfig atCompactionConfig, AtLogType atLogType) {
    logger.finest('scheduleKeyExpireTask starting cron job.');
    var runFrequencyMins = atCompactionConfig.compactionFrequencyMins;
    var cron = Cron();
    cron.schedule(Schedule.parse('*/${runFrequencyMins} * * * *'), () async {
      logger.finest('scheduleCompactionJob calling expireAll()');
      var compactionService = AtCompactionService.getInstance();
      await compactionService.executeCompaction(atCompactionConfig, atLogType);
      logger.finest('scheduleCompactionJob executeCompaction completed');
    });
  }
}
