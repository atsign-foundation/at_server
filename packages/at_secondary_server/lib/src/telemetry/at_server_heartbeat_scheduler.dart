import 'dart:async';
import 'dart:math';

import 'package:at_telemetry/at_telemetry.dart';

import 'at_server_telemetry.dart';
import 'at_server_telemetry_constants.dart';

final class AtServerHeartbeatScheduler {
  static const Duration defaultInterval = Duration(seconds: 60);
  static const Duration _minimumInterval = Duration(milliseconds: 1);

  final AtServerTelemetry _telemetry;
  final Duration interval;
  final Duration offset;
  final Stopwatch _uptime = Stopwatch();
  Timer? _timer;

  AtServerHeartbeatScheduler({
    required AtServerTelemetry telemetry,
    this.interval = defaultInterval,
    Duration? offset,
    Random? random,
  })  : _telemetry = telemetry,
        offset = offset ?? _randomOffset(interval, random ?? Random.secure()) {
    if (interval < _minimumInterval) {
      throw ArgumentError.value(
        interval,
        'interval',
        'must be at least one millisecond',
      );
    }

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
    if (_timer != null) {
      return;
    }
    _uptime.start();
    _timer = Timer(offset, () {
      _sendHeartbeat();
      _timer = Timer.periodic(interval, (Timer _) => _sendHeartbeat());
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _uptime.stop();
  }

  void _sendHeartbeat() {
    _telemetry.emitEvent(
      atServerHeartbeatEventName,
      attributes: <String, Object?>{
        ..._telemetry.healthAttributes(),
        AtTelemetryAttributes.atServerUptimeSeconds:
            _uptime.elapsedMicroseconds / Duration.microsecondsPerSecond,
        AtTelemetryAttributes.telemetryClasses: atServerEnabledTelemetryClasses,
      },
    );
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
