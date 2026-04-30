import 'dart:math';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:cron/cron.dart';

/// Schedules periodic compaction by delegating to an
/// [AtCompactionStrategy]. The strategy decides what "compact"
/// means for its backend; this class just runs it on a cron and
/// records the resulting [AtCompactionStats] via an
/// [AtCompactionStatsService].
///
/// The configurations come from [AtCompactionConfig]:
/// - [AtCompactionConfig.compactionFrequencyInMins] sets the cron
///   tick (the scheduler's concern).
/// - [AtCompactionConfig.compactionPercentage] sets how aggressive
///   each pass is (the strategy's concern, set via
///   [AtCompactionStrategy.setConfig]).
class AtCompactionJob {
  final Cron _cron = Cron();
  ScheduledTask? _schedule;
  final AtCompactionStrategy _strategy;
  final AtCompactionStatsService? _statsService;

  // Per-instance so concurrent jobs across different atSigns / log
  // types don't share an RNG.
  final Random _random = Random();

  /// Construct a scheduler for [_strategy]. If [_statsService] is
  /// supplied, each pass's stats are written to it; otherwise the
  /// stats are dropped.
  AtCompactionJob(this._strategy, [this._statsService]);

  /// Triggers the compaction job at [config.compactionFrequencyInMins]
  /// intervals.
  void scheduleCompactionJob(AtCompactionConfig config) {
    _strategy.setConfig(config);
    var runFrequencyInMins = config.compactionFrequencyInMins;
    _schedule = _cron.schedule(Schedule.parse('*/$runFrequencyInMins * * * *'),
        () async {
      // Adding delay to randomize the cron jobs (so per-atSign jobs
      // don't all fire at the same wall-clock instant).
      await Future.delayed(Duration(seconds: _random.nextInt(12)));
      final stats = await _strategy.compact();
      await _statsService?.handleStats(stats);
    });
  }

  /// Cancel the current schedule. The Cron instance is not closed
  /// and can be re-used.
  Future<void> stopCompactionJob() async {
    await _schedule?.cancel();
    _schedule = null;
  }

  /// Stop compaction and close the Cron instance.
  void close() {
    _cron.close();
  }

  /// Returns true if the compaction job is scheduled, else false.
  bool isScheduled() {
    return _schedule != null;
  }
}
