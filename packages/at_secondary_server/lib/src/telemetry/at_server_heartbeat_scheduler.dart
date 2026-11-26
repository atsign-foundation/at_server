import 'dart:async';
import 'dart:math';

import 'package:at_telemetry/at_telemetry.dart' show AtTelemetryAttributes;

import 'at_server_telemetry.dart';
import 'at_server_telemetry_constants.dart';

/// How many open device connections each enrollment has now, by id.
typedef ConnectedEnrollments = Map<String, int> Function();

/// Sends the heartbeat event every [interval], the first after a random
/// [offset] so that atServers started together don't send together.
///
/// Each heartbeat counts the enrollments that `connectedEnrollments` reports
/// and lists the first [maxListedEnrollments] of them by id. Without
/// `connectedEnrollments`, or when it fails, the heartbeat carries neither.
final class AtServerHeartbeatScheduler {
  static const Duration defaultInterval = Duration(seconds: 60);
  static const int maxListedEnrollments = 100;
  static const Duration _minimumInterval = Duration(milliseconds: 1);

  final AtServerTelemetry _telemetry;
  final ConnectedEnrollments? _connectedEnrollments;
  final Duration interval;
  final Duration offset;
  Timer? _timer;

  AtServerHeartbeatScheduler({
    required AtServerTelemetry telemetry,
    ConnectedEnrollments? connectedEnrollments,
    this.interval = defaultInterval,
    Duration? offset,
    Random? random,
  })  : _telemetry = telemetry,
        _connectedEnrollments = connectedEnrollments,
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

  /// Starts the heartbeat; does nothing if it is already running.
  void start() {
    if (_timer != null) {
      return;
    }
    _timer = Timer(offset, () {
      _sendHeartbeat();
      _timer = Timer.periodic(interval, (Timer _) => _sendHeartbeat());
    });
  }

  /// Stops the heartbeat.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _sendHeartbeat() {
    if (!_telemetry.isEnabled) {
      return;
    }
    _telemetry.emitEvent(atServerHeartbeatEventName,
        attributes: _connectionAttributes());
  }

  Map<String, Object?> _connectionAttributes() {
    final ConnectedEnrollments? connectedEnrollments = _connectedEnrollments;
    if (connectedEnrollments == null) {
      return const <String, Object?>{};
    }
    try {
      final List<MapEntry<String, int>> connected =
          connectedEnrollments().entries.toList();
      connected.sort((MapEntry<String, int> a, MapEntry<String, int> b) =>
          a.key.compareTo(b.key));
      return <String, Object?>{
        connectedEnrollmentCountAttribute: connected.length,
        if (connected.isNotEmpty)
          connectedEnrollmentsAttribute: <Map<String, Object?>>[
            for (final MapEntry<String, int> enrollment
                in connected.take(maxListedEnrollments))
              <String, Object?>{
                AtTelemetryAttributes.enrollmentId: enrollment.key,
                connectionCountAttribute: enrollment.value,
              },
          ],
      };
    } on Object catch (error) {
      _telemetry.logger
          .warning('Heartbeat sent without its connected enrollments: $error');
      return const <String, Object?>{};
    }
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
