import 'dart:async';
import 'dart:math';

import 'at_server_telemetry.dart';

final class AtServerHeartbeat {
  static const String eventName = 'atsign.server.heartbeat';

  final AtServerTelemetry _telemetry;

  AtServerHeartbeat({required AtServerTelemetry telemetry})
      : _telemetry = telemetry;

  void send() {
    _telemetry.push(eventName);
  }
}

final class AtServerHeartbeatScheduler {
  static const Duration defaultInterval = Duration(seconds: 60);

  // minimum that the interval can be set to
  static const Duration _minimumInterval = Duration(milliseconds: 1);

  final AtServerHeartbeat _heartbeat;
  final Duration interval;
  final Duration offset;
  final DateTime Function() _now;
  Timer? _timer;
  DateTime? _previousSlot;

  AtServerHeartbeatScheduler({
    required AtServerHeartbeat heartbeat,
    this.interval = defaultInterval,
    Duration? offset,
    Random? random,
    DateTime Function()? now,
  })  : _heartbeat = heartbeat,
        offset = offset ?? randomOffset(interval, random ?? Random.secure()),
        _now = now ?? DateTime.now {
    _requireInterval(interval);
    if (this.offset < Duration.zero || this.offset >= interval) {
      throw ArgumentError.value(
        this.offset,
        'offset',
        'must be at least zero and less than interval',
      );
    }
  }

  static Duration randomOffset(Duration interval, Random random) {
    _requireInterval(interval);
    return Duration(milliseconds: random.nextInt(interval.inMilliseconds));
  }

  static void _requireInterval(Duration interval) {
    if (interval < _minimumInterval) {
      throw ArgumentError.value(
        interval,
        'interval',
        'must be at least one millisecond',
      );
    }
  }

  bool get isRunning => _timer != null;

  DateTime nextSlot({required DateTime now, DateTime? previousSlot}) {
    final int intervalMicroseconds = interval.inMicroseconds;
    final int nowMicroseconds = now.microsecondsSinceEpoch;
    int slotMicroseconds = nowMicroseconds -
        nowMicroseconds % intervalMicroseconds +
        offset.inMicroseconds;
    if (slotMicroseconds <= nowMicroseconds) {
      slotMicroseconds += intervalMicroseconds;
    }

    final DateTime slot = DateTime.fromMicrosecondsSinceEpoch(
      slotMicroseconds,
      isUtc: true,
    );
    if (previousSlot != null && slot.isAtSameMomentAs(previousSlot)) {
      return slot.add(interval);
    }
    return slot;
  }

  void start() {
    if (_timer == null) {
      _scheduleNext();
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _scheduleNext() {
    final DateTime now = _now().toUtc();
    final DateTime slot = nextSlot(now: now, previousSlot: _previousSlot);
    _timer = Timer(slot.difference(now), () {
      _previousSlot = slot;
      _scheduleNext();
      _heartbeat.send();
    });
  }
}
