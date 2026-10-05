import 'dart:async';

import 'package:at_telemetry/at_telemetry.dart';
import 'package:at_utils/at_logger.dart';

import 'at_server_heartbeat_scheduler.dart';
import 'at_server_telemetry_constants.dart';

final class AtServerTelemetry {
  static const String serverIdAttribute =
      AtTelemetryHttpSignature.serverIdAttribute;
  static const String _eventNamePrefix = '$atServerTelemetryEventPrefix.';

  /// How often the uptime heartbeat is sent while telemetry is enabled.
  /// Null turns the heartbeat off.
  final Duration? heartbeatInterval;
  final AtSignLogger _logger = AtSignLogger('AtServerTelemetry');
  AtTelemetry? _telemetry;
  AtServerHeartbeatScheduler? _heartbeat;
  String? _serverId;

  AtServerTelemetry({
    this.heartbeatInterval = AtServerHeartbeatScheduler.defaultInterval,
  });

  bool get isEnabled => _telemetry != null;
  String? get serverId => _serverId;

  void enable({
    required AtTelemetryLogRecordExporter exporter,
    required String serverId,
  }) {
    if (_telemetry != null) {
      throw StateError('Telemetry is already enabled');
    }
    _telemetry = AtTelemetry(
      serviceName: atServerServiceName,
      exporter: exporter,
      onError: _onError,
    );
    _serverId = serverId;
    final Duration? interval = heartbeatInterval;
    if (interval != null) {
      _heartbeat = AtServerHeartbeatScheduler(
        telemetry: this,
        interval: interval,
      )..start();
    }
  }

  void emitEvent(String name, {Map<String, Object?> attributes = const {}}) {
    final AtTelemetry? telemetry = _telemetry;
    if (telemetry == null) {
      return;
    }
    if (name.trim().isEmpty) {
      _logger.warning('Ignoring telemetry event with an empty name');
      return;
    }
    if (!name.startsWith(_eventNamePrefix) ||
        name.length == _eventNamePrefix.length ||
        name.trim() != name) {
      _logger
          .warning('Ignoring telemetry event outside the atServer namespace');
      return;
    }

    // AtTelemetry throws on invalid attribute values. Telemetry must never
    // take the server down, so log and drop the event instead.
    try {
      telemetry.event(
        name,
        attributes: <String, Object?>{
          ...attributes,
          serverIdAttribute: _serverId,
        },
      );
    } on ArgumentError catch (error) {
      _logger.warning('Ignoring invalid telemetry event $name: '
          '${error.name} ${error.message}');
    }
  }

  Future<void> flush({Duration? timeout}) async {
    final AtTelemetry? telemetry = _telemetry;
    if (telemetry == null) {
      return;
    }
    await _bounded(telemetry.flush(), timeout, 'flush');
  }

  Future<void> shutdown({Duration? timeout}) async {
    final AtTelemetry? telemetry = _telemetry;
    if (telemetry == null) {
      return;
    }
    _telemetry = null;
    _serverId = null;
    _heartbeat?.stop();
    _heartbeat = null;
    await _bounded(telemetry.shutdown(), timeout, 'shutdown');
  }

  void _onError(Object error, StackTrace stackTrace) {
    _logger.warning('Telemetry export failed: ${error.runtimeType}');
  }

  Future<void> _bounded(
    Future<void> work,
    Duration? timeout,
    String operation,
  ) async {
    if (timeout == null) {
      return work;
    }
    try {
      await work.timeout(timeout);
    } on TimeoutException {
      _logger.warning('Telemetry $operation timed out after $timeout');
    }
  }
}
