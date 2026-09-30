import 'dart:async';

import 'package:at_telemetry/at_telemetry.dart';
import 'package:at_utils/at_logger.dart';

import 'at_server_heartbeat_scheduler.dart';
import 'at_server_telemetry_constants.dart';

final class AtServerTelemetry {
  static const String serverIdAttribute =
      AtTelemetryHttpSignature.serverIdAttribute;
  static const int defaultMaxPendingEvents = 1000;
  static const String _eventNamePrefix = '$atServerTelemetryEventPrefix.';

  final int maxPendingEvents;

  /// How often the uptime heartbeat is sent while telemetry is enabled.
  /// Null turns the heartbeat off.
  final Duration? heartbeatInterval;
  final AtSignLogger _logger = AtSignLogger('AtServerTelemetry');
  final List<Future<void>> _pending = <Future<void>>[];
  AtTelemetryLogRecordExporter? _exporter;
  AtServerHeartbeatScheduler? _heartbeat;
  String? _serverId;

  AtServerTelemetry({
    this.maxPendingEvents = defaultMaxPendingEvents,
    this.heartbeatInterval = AtServerHeartbeatScheduler.defaultInterval,
  }) {
    if (maxPendingEvents < 1) {
      throw ArgumentError.value(
        maxPendingEvents,
        'maxPendingEvents',
        'must be at least one',
      );
    }
  }

  bool get isEnabled => _exporter != null;
  String? get serverId => _serverId;

  void enable({
    required AtTelemetryLogRecordExporter exporter,
    required String serverId,
  }) {
    if (_exporter != null) {
      throw StateError('Telemetry is already enabled');
    }
    _exporter = exporter;
    _serverId = serverId;
    final Duration? interval = heartbeatInterval;
    if (interval != null) {
      _heartbeat = AtServerHeartbeatScheduler(
        telemetry: this,
        interval: interval,
      )..start();
    }
  }

  void recordGauge(
    String name,
    double value, {
    String unit = '',
    Map<String, Object?> attributes = const <String, Object?>{},
  }) {
    final AtTelemetryLogRecordExporter? exporter = _exporter;
    if (exporter is! AtTelemetryMetricExporter) {
      return;
    }
    if (!name.startsWith(_eventNamePrefix) ||
        name.length == _eventNamePrefix.length ||
        name.trim() != name ||
        !value.isFinite) {
      _logger.warning('Ignoring invalid atServer gauge');
      return;
    }
    final AtTelemetryGauge gauge = AtTelemetryGauge(
      name: name,
      value: value,
      unit: unit,
      timestamp: DateTime.now().toUtc(),
      attributes: Map<String, Object?>.unmodifiable(<String, Object?>{
        ...attributes,
        serverIdAttribute: _serverId,
      }),
    );
    final AtTelemetryMetricExporter metricExporter =
        exporter as AtTelemetryMetricExporter;
    final Future<void> export = _guard(
      () => metricExporter.exportMetrics(<AtTelemetryGauge>[gauge]),
      'gauge export',
    );
    _pending.add(export);
    unawaited(export.whenComplete(() => _pending.remove(export)));
  }

  void emitEvent(String name, {Map<String, Object?> attributes = const {}}) {
    final AtTelemetryLogRecordExporter? exporter = _exporter;
    if (exporter == null) {
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
    if (_pending.length >= maxPendingEvents) {
      _logger.warning('Telemetry backlog full, dropping event');
      return;
    }

    final AtTelemetryLogRecord event = AtTelemetryLogRecord(
      name: name,
      timestamp: DateTime.now().toUtc(),
      attributes: Map<String, Object?>.unmodifiable(<String, Object?>{
        ...attributes,
        serverIdAttribute: _serverId,
      }),
    );
    final Future<void> export = _export(exporter, event);
    _pending.add(export);
    unawaited(export.whenComplete(() => _pending.remove(export)));
  }

  Future<void> flush({Duration? timeout}) async {
    final AtTelemetryLogRecordExporter? exporter = _exporter;
    if (exporter == null) {
      return;
    }
    await _bounded(_drain(exporter), timeout, 'flush');
  }

  Future<void> shutdown({Duration? timeout}) async {
    final AtTelemetryLogRecordExporter? exporter = _exporter;
    if (exporter == null) {
      return;
    }
    _exporter = null;
    _serverId = null;
    _heartbeat?.stop();
    _heartbeat = null;
    await _bounded(
      _drain(exporter).then((void _) => _guard(exporter.shutdown, 'shutdown')),
      timeout,
      'shutdown',
    );
  }

  Future<void> _drain(AtTelemetryLogRecordExporter exporter) async {
    await Future.wait(_pending.toList());
    await _guard(exporter.flush, 'flush');
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

  Future<void> _guard(Future<void> Function() action, String operation) async {
    try {
      await action();
    } on Object catch (error) {
      _logger.warning('Telemetry $operation failed: ${error.runtimeType}');
    }
  }

  Future<void> _export(
    AtTelemetryLogRecordExporter exporter,
    AtTelemetryLogRecord event,
  ) {
    return _guard(() => exporter.export(event), 'export');
  }
}
