import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_utils/at_logger.dart';
import 'package:cron/cron.dart';

class AtCacheRefreshJob {
  final String atSign;
  late Cron _cron;
  final AtCacheManager cacheManager;

  AtCacheRefreshJob(this.atSign, this.cacheManager);

  final logger = AtSignLogger('AtCacheRefreshJob');

  bool running = false;

  /// The method which actually does the refresh.
  /// Gets everything that is currently cached,
  Future<String> refreshCache() async {
    if (running) {
      throw StateError('The cache refresh job is already running');
    }
    running = true;
    int keysChecked = 0;
    int valueUnchanged = 0;
    int valueChanged = 0;
    int deletedByRemote = 0;
    int exceptionFromRemote = 0;
    try {
      var keysToRefresh = await cacheManager.getKeyNamesToRefresh();

      var itr = keysToRefresh.iterator;
      while (itr.moveNext()) {
        keysChecked++;

        var cachedKeyName = itr.current;
        AtData? newValue;

        try {
          newValue = await cacheManager.remoteLookUp(cachedKeyName, maintainCache: false);
        } on KeyNotFoundException {
          deletedByRemote++;
          continue;
        } catch (e) {
          logger.info("Exception while trying to get latest value for $cachedKeyName : $e");
          exceptionFromRemote++;
          continue;
        }
        // If new value is null, it means it no longer exists. We need to remove it from our cache.
        if (newValue == null) {
          await cacheManager.delete(cachedKeyName);
          deletedByRemote++;
          continue;
        }

        // If old value and new value are equal, then do not update;
        // Continue for next key.
        AtData? oldValue = await cacheManager.get(cachedKeyName, applyMetadataRules: false);
        if (oldValue?.data == newValue.data) {
          logger.finer(
              '$cachedKeyName cached value is same as looked-up value. Not updating the cached key');
          valueUnchanged++;
          continue;
        }

        await cacheManager.put(cachedKeyName, newValue);
        valueChanged++;
        logger.finer('Updated $cachedKeyName with $newValue');
      }
    } finally {
      running = false;
    }
    return {
      "keysChecked":keysChecked,
      "valueUnchanged":valueUnchanged,
      "valueChanged":valueChanged,
      "deletedByRemote":deletedByRemote,
      "exceptionFromRemote":exceptionFromRemote
    }.toString();
  }

  /// Schedule an execution of [refreshCache] at [runJobHour]:00
  void scheduleRefreshJob(int runJobHour) {
    logger.info('scheduleKeyRefreshTask runs at $runJobHour:00');
    _cron = Cron();
    _cron.schedule(Schedule.parse('0 $runJobHour * * *'), () async {
      logger.info('Scheduled Cache Refresh Job started');
      try {
        var summary = await refreshCache();
        logger.info('Scheduled Cache Refresh Job completed successfully: $summary');
      } catch (e, st) {
        logger.severe('Scheduled Cache Refresh Job failed with exception $e and stackTrace $st');
      }
    });
  }

  void close() {
    _cron.close();
  }
}
