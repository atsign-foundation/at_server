import 'dart:async';
import 'dart:math';

import 'at_server_telemetry.dart';
import 'at_server_telemetry_event_names.dart';

final class AtServerHeartbeatScheduler {
  static const String eventName = atServerHeartbeatEventName;

  // minimum that the interval can be set to
  static const Duration _minimumInterval = Duration(milliseconds: 1);
  static const Duration defaultInterval = Duration(seconds: 60);

  final AtServerTelemetry
      _telemetry; // an object for atServer to push telemetry easily
  final Duration interval; // the interval at which heartbeats will be sent
  final Duration
      offset; // a random initial offset so that heartbeats are sent at random times
  Timer? _timer;

  AtServerHeartbeatScheduler({
    required AtServerTelemetry telemetry,
    this.interval = defaultInterval,
    Duration? offset,
    Random? random,
  })  : _telemetry = telemetry,
        offset = offset ?? _randomOffset(interval, random ?? Random.secure()) {
    // verify `interval`
    if (interval < _minimumInterval) {
      throw ArgumentError.value(
        interval,
        'interval',
        'must be at least one millisecond',
      );
    }

    // verify `offset`
    if (this.offset < Duration.zero || this.offset >= interval) {
      throw ArgumentError.value(
        this.offset,
        'offset',
        'must be at least zero and less than interval',
      );
    }
  }

  bool get isRunning => _timer != null;

  void start() {
    _timer ??= Timer(offset, () {
      _telemetry.push(eventName);
      _timer = Timer.periodic(interval, (_) => _telemetry.push(eventName));
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  static Duration _randomOffset(Duration interval, Random random) {
    if (interval < _minimumInterval) {
      throw ArgumentError.value(
        interval,
        'interval',
        'must be at least one millisecond',
      );
    }
    return Duration(milliseconds: random.nextInt(interval.inMilliseconds));
  }
}
