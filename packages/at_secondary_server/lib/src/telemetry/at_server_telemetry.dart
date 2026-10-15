import 'dart:async';

import 'package:at_telemetry/at_telemetry.dart';
import 'package:at_utils/at_logger.dart';

import 'at_server_heartbeat_scheduler.dart';
import 'at_server_telemetry_constants.dart';

/// The atServer's telemetry facade. Nothing here throws into the server, and
/// flush and shutdown always return within their timeouts.
final class AtServerTelemetry {
  static const String _eventNamePrefix = '$atServerTelemetryEventPrefix.';

  /// How often the heartbeat is sent while telemetry is enabled. Null turns
  /// the heartbeat off.
  final Duration? heartbeatInterval;
  final AtSignLogger _logger = AtSignLogger('AtServerTelemetry');
  AtTelemetry? _telemetry;
  AtServerHeartbeatScheduler? _heartbeat;
  void Function()? _reportState;

  AtServerTelemetry({
    this.heartbeatInterval = AtServerHeartbeatScheduler.defaultInterval,
  });

  bool get isEnabled => _telemetry != null;

  /// Starts sending telemetry, beginning with the started event. [serverId]
  /// is the atSign and [bootId] the per-start id that also prefixes every
  /// batch's sequence.
  void enable({
    required AtTelemetryLogRecordExporter exporter,
    required String serverId,
    required String bootId,
    String? serviceVersion,
    void Function()? reportState,
  }) {
    if (_telemetry != null) {
      throw StateError('Telemetry is already enabled');
    }
    _telemetry = AtTelemetry(
      serviceName: atServerServiceName,
      resourceAttributes: AtTelemetryResource.atServer(
        atServerId: serverId,
        serviceVersion: serviceVersion,
        serviceInstanceId: bootId,
      ),
      exporter: exporter,
      onError: _onError,
    );
    _reportState = reportState;
    emitEvent(atServerStartedEventName);
    _sendState();
    final Duration? interval = heartbeatInterval;
    if (interval != null) {
      _heartbeat = AtServerHeartbeatScheduler(
        telemetry: this,
        interval: interval,
        onBeat: _sendState,
      )..start();
    }
  }

  /// Sends the event [name], which must be in the atServer's namespace, or
  /// logs why it was dropped.
  void emitEvent(
    String name, {
    Map<String, Object?> attributes = const {},
    Object? body,
  }) {
    final AtTelemetry? telemetry = _telemetry;
    if (telemetry == null) {
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
      telemetry.event(name, attributes: attributes, body: body);
    } on ArgumentError catch (error) {
      _logger.warning('Ignoring invalid telemetry event $name: '
          '${error.name} ${error.message}');
    } on Object catch (error) {
      _logger.warning('Dropped telemetry event $name: $error');
    }
  }

  /// Sends what is batched, returning within [timeout].
  Future<void> flush({Duration timeout = AtTelemetry.defaultFlushTimeout}) {
    final AtTelemetry? telemetry = _telemetry;
    if (telemetry == null) {
      return Future<void>.value();
    }
    return telemetry.flush(timeout: timeout);
  }

  /// Sends the stopped event, then shuts the exporter down.
  Future<void> shutdown({
    Duration timeout = AtTelemetry.defaultShutdownTimeout,
  }) {
    final AtTelemetry? telemetry = _telemetry;
    if (telemetry == null) {
      return Future<void>.value();
    }
    _heartbeat?.stop();
    _heartbeat = null;
    _reportState = null;
    emitEvent(atServerStoppedEventName);
    _telemetry = null;
    return telemetry.shutdown(timeout: timeout);
  }

  void _onError(Object error, StackTrace stackTrace) {
    _logger.warning('Telemetry export failed: $error');
  }

  void _sendState() {
    final void Function()? reportState = _reportState;
    if (reportState == null || _telemetry == null) {
      return;
    }
    try {
      reportState();
    } on Object catch (error) {
      _logger.warning('Dropped telemetry state report: $error');
    }
  }
}
