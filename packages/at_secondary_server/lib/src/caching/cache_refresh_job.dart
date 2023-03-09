import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_utils/at_logger.dart';
import 'package:cron/cron.dart';
import 'package:meta/meta.dart';

class AtCacheRefreshJob {
  final String atSign;
  final AtCacheManager cacheManager;

  AtCacheRefreshJob(this.atSign, this.cacheManager);

  final logger = AtSignLogger('AtCacheRefreshJob');

  @visibleForTesting
  bool running = false;

  @visibleForTesting
  Cron? cron;

  /// The method which actually does the refresh.
  /// Gets everything that is currently cached,
  Future<Map> refreshNow({Duration? pauseAfterFinishing}) async {
    if (running) {
      var message = 'refreshNow() called but the cache refresh job is already running';
      logger.severe(message);
      throw StateError(message);
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
      if (pauseAfterFinishing != null) {
        await Future.delayed(pauseAfterFinishing);
      }
      running = false;
    }
    return {
      "keysChecked":keysChecked,
      "valueUnchanged":valueUnchanged,
      "valueChanged":valueChanged,
      "deletedByRemote":deletedByRemote,
      "exceptionFromRemote":exceptionFromRemote
    };
  }

  /// Schedule an execution of [refreshNow] at [runJobHour]:00
  void scheduleRefreshJob(int runJobHour) {
    if (cron != null) {
      var message = 'scheduleRefreshJob() called but refresh job has already been scheduled';
      logger.severe(message);
      throw StateError(message);
    }
    logger.info('scheduleKeyRefreshTask runs at $runJobHour:00');
    cron = Cron();
    cron!.schedule(Schedule.parse('0 $runJobHour * * *'), () async {
      logger.info('Scheduled Cache Refresh Job started');
      try {
        var summary = await refreshNow();
        logger.info('Scheduled Cache Refresh Job completed successfully: $summary');
      } catch (e, st) {
        logger.severe('Scheduled Cache Refresh Job failed with exception $e and stackTrace $st');
      }
    });
  }

  Cron? close() {
    Cron? cronBeforeClose = cron;
    cron?.close();
    cron = null;
    return cronBeforeClose;
  }
}
