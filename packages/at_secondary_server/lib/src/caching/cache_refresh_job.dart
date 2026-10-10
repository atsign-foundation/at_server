import 'dart:math';

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
      var message =
          'refreshNow() called but the cache refresh job is already running';
      logger.severe(message);
      throw StateError(message);
    }
    running = true;
    int keysChecked = 0;
    int valueUnchanged = 0;
    int valueChanged = 0;
    int deletedByRemote = 0;
    int exceptionFromRemote = 0;
    int leftoversDeleted = 0;
    try {
      var keysToRefresh = await cacheManager.getKeyNamesToRefresh();

      var itr = keysToRefresh.iterator;
      while (itr.moveNext()) {
        keysChecked++;

        var cachedKeyName = itr.current;
        AtData? oldValue =
            await cacheManager.get(cachedKeyName, applyMetadataRules: false);
        if (AtCacheManager.isCopyNotKept(cachedKeyName, oldValue?.metaData)) {
          await cacheManager.delete(cachedKeyName);
          leftoversDeleted++;
          continue;
        }

        AtData? newValue;

        try {
          newValue = await cacheManager.remoteLookUp(cachedKeyName,
              maintainCache: false);
        } on KeyNotFoundException {
          await cacheManager.delete(cachedKeyName);
          deletedByRemote++;
          continue;
        } catch (e) {
          logger.info(
              "Exception while trying to get latest value for $cachedKeyName : $e");
          exceptionFromRemote++;
          continue;
        }
        // If new value is null, it means it no longer exists. We need to remove it from our cache.
        if (newValue == null) {
          await cacheManager.delete(cachedKeyName);
          deletedByRemote++;
          continue;
        }

        if (AtCacheManager.isCopyNotKept(cachedKeyName, newValue.metaData)) {
          await cacheManager.delete(cachedKeyName);
          leftoversDeleted++;
          continue;
        }

        final bool unchanged = oldValue?.data == newValue.data;
        // An unchanged copy is written only when its ttr lets it be served,
        // so that its refreshAt moves on and it is served again
        if (unchanged && !_servable(newValue.metaData)) {
          valueUnchanged++;
          continue;
        }
        await cacheManager.put(cachedKeyName, newValue);
        if (unchanged) {
          valueUnchanged++;
        } else {
          valueChanged++;
          logger.finer('Updated $cachedKeyName with $newValue');
        }
      }
    } finally {
      if (pauseAfterFinishing != null) {
        await Future.delayed(pauseAfterFinishing);
      }
      running = false;
    }
    return {
      "keysChecked": keysChecked,
      "valueUnchanged": valueUnchanged,
      "valueChanged": valueChanged,
      "deletedByRemote": deletedByRemote,
      "exceptionFromRemote": exceptionFromRemote,
      "leftoversDeleted": leftoversDeleted
    };
  }

  /// Whether a copy with [metaData] is ever served: only one whose ttr is -1,
  /// or positive and so gives it a refreshAt.
  static bool _servable(AtMetaData? metaData) {
    final int? ttr = metaData?.ttr;
    return ttr != null && (ttr == -1 || ttr > 0);
  }

  /// Runs [refreshNow] unless a refresh is already running, logging a
  /// failure rather than throwing it, for callers that do not await it.
  Future<void> refreshNowIfIdle() async {
    if (running) {
      logger.info('Cache refresh requested while one is running; skipping');
      return;
    }
    try {
      logger.info('Requested cache refresh completed: ${await refreshNow()}');
    } catch (e, st) {
      logger.severe('Requested cache refresh failed: $e\n$st');
    }
  }

  /// The hour to run the daily refresh at: [configured] when it is an hour
  /// from 0 to 23, otherwise one picked with [random], which spreads the
  /// refresh load across atServers. A [configured] value that is not an hour
  /// is reported to [warn].
  static int runJobHourFrom(String? configured,
      {required Random random, required void Function(String) warn}) {
    if (configured != null) {
      final int? hour = int.tryParse(configured.trim());
      if (hour != null && hour >= 0 && hour <= 23) {
        return hour;
      }
      warn('runRefreshJobHour "$configured" is not an hour from 0 to 23;'
          ' the cache refresh will run at a random hour');
    }
    return random.nextInt(24);
  }

  /// Schedule an execution of [refreshNow] at [runJobHour]:00
  void scheduleRefreshJob(int runJobHour) {
    if (cron != null) {
      var message =
          'scheduleRefreshJob() called but refresh job has already been scheduled';
      logger.severe(message);
      throw StateError(message);
    }
    logger.info('scheduleKeyRefreshTask runs at $runJobHour:00');
    cron = Cron();
    cron!.schedule(Schedule.parse('0 $runJobHour * * *'), () async {
      logger.info('Scheduled Cache Refresh Job started');
      try {
        var summary = await refreshNow();
        logger.info(
            'Scheduled Cache Refresh Job completed successfully: $summary');
      } catch (e, st) {
        logger.severe(
            'Scheduled Cache Refresh Job failed with exception $e and stackTrace $st');
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
