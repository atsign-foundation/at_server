import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_utils/at_logger.dart';
import 'package:cron/cron.dart';

class AtRefreshJob {
  final String atSign;
  late Cron _cron;
  final CacheManager cacheManager;

  AtRefreshJob(this.atSign, this.cacheManager);

  final logger = AtSignLogger('AtRefreshJob');

  /// The refresh job
  Future<void> _refreshJob(int runFrequencyHours) async {
    var keysToRefresh = await cacheManager.getCachedKeys();

    var itr = keysToRefresh.iterator;
    while (itr.moveNext()) {
      var cachedKeyName = itr.current;
      String? newValue;

      try {
          newValue = await cacheManager.lookUpRemoteValue(cachedKeyName);
      } catch (e) {
        logger.info("Exception while trying to get latest value for $cachedKeyName : $e");
        continue;
      }
      // If new value is null, do nothing. Continue for next key.
      if (newValue == null) {
        continue;
      }
      newValue = newValue.replaceAll('data:', '');
      // If new value is 'null' or empty
      // do not update the cached key. Do nothing. Continue for next key.
      if (newValue.trim().isEmpty || newValue == 'null') {
        logger.finest(
            'value not found for $cachedKeyName. Failed updating the cached key');
        continue;
      }
      // If old value and new value are equal, then do not update;
      // Continue for next key.
      AtData? oldValue = await cacheManager.getCachedValue(cachedKeyName);
      if (oldValue?.data == newValue) {
        logger.finest(
            '$cachedKeyName cached value is same as looked-up value. Not updating the cached key');
        continue;
      }

      await cacheManager.updateCachedValue(newValue, oldValue, cachedKeyName);
      logger.finer('Updated the cached key value of $cachedKeyName with $newValue');
    }
  }

  /// The Cron Job which runs at a frequent time interval.
  void scheduleRefreshJob(int runJobHour) {
    logger.finest('scheduleKeyRefreshTask runs at $runJobHour hours');
    _cron = Cron();
    _cron.schedule(Schedule.parse('0 $runJobHour * * *'), () async {
      logger.finest('Scheduled Refresh Job started');
      await _refreshJob(runJobHour);
      logger.finest('scheduled Refresh Job completed');
    });
  }

  void close() {
    _cron.close();
  }
}
