import 'dart:async';

import 'package:at_secondary/src/connection/inbound/inbound_connection_close_reason.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_web_socket_connection.dart';
import 'package:at_server_spec/at_server_spec.dart';
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
    emitEvent(atServerStartedEventName);
    final Duration? interval = heartbeatInterval;
    if (interval != null) {
      _heartbeat = AtServerHeartbeatScheduler(
        telemetry: this,
        interval: interval,
      )..start();
    }
  }

  /// Sends the event [name], which must be in the atServer's namespace, or
  /// logs why it was dropped.
  void emitEvent(String name, {Map<String, Object?> attributes = const {}}) {
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
      telemetry.event(name, attributes: attributes);
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
    emitEvent(atServerStoppedEventName);
    _telemetry = null;
    return telemetry.shutdown(timeout: timeout);
  }

  void connectionAuthenticated(AtConnection connection) {
    if (!isEnabled || connection is! InboundConnection) {
      return;
    }
    final AtConnectionMetaData metaData = connection.metaData;
    if (metaData is! InboundConnectionMetadata || !metaData.isAuthenticated) {
      return;
    }
    metaData.telemetryAnnounced = true;
    emitEvent(
      atServerConnectionAuthenticatedEventName,
      attributes: _describeConnection(connection, metaData),
    );
  }

  void connectionMonitoring(
    InboundConnection connection, {
    required bool selfNotifications,
  }) {
    final AtConnectionMetaData metaData = connection.metaData;
    if (!isEnabled ||
        metaData is! InboundConnectionMetadata ||
        !metaData.telemetryAnnounced) {
      return;
    }
    emitEvent(
      atServerConnectionMonitoringEventName,
      attributes: <String, Object?>{
        connectionIdAttribute: metaData.connectionId,
        connectionSelfNotificationsAttribute: selfNotifications,
      },
    );
  }

  void connectionClosed(InboundConnection connection) {
    final AtConnectionMetaData metaData = connection.metaData;
    if (!isEnabled ||
        metaData is! InboundConnectionMetadata ||
        !metaData.telemetryAnnounced) {
      return;
    }
    metaData.telemetryAnnounced = false;
    final InboundConnectionCloseReason reason = metaData.closeReason ??
        (metaData.isStale
            ? InboundConnectionCloseReason.stale
            : InboundConnectionCloseReason.unknown);
    if (reason == InboundConnectionCloseReason.serverShutdown) {
      return;
    }
    final DateTime? created = metaData.created;
    emitEvent(
      atServerConnectionClosedEventName,
      attributes: <String, Object?>{
        connectionIdAttribute: metaData.connectionId,
        connectionCloseReasonAttribute: reason.wireName,
        if (created != null)
          connectionDurationAttribute:
              DateTime.timestamp().difference(created).inMilliseconds,
      },
    );
  }

  void _onError(Object error, StackTrace stackTrace) {
    _logger.warning('Telemetry export failed: $error');
  }

  Map<String, Object?> _describeConnection(
    InboundConnection connection,
    InboundConnectionMetadata metaData,
  ) {
    final DateTime? created = metaData.created;
    final AuthType? authType = metaData.authType;
    final String clientVersion = metaData.clientVersion;
    return <String, Object?>{
      connectionIdAttribute: metaData.connectionId,
      if (created != null)
        connectionOpenedAtAttribute: created.millisecondsSinceEpoch,
      connectionTransportAttribute:
          connection is InboundWebSocketConnection ? 'websocket' : 'tls',
      if (authType != null)
        connectionAuthTypeAttribute: _authTypeName(authType),
      if (metaData.enrollmentId case final String enrollmentId)
        AtTelemetryAttributes.enrollmentId: _bounded(enrollmentId),
      if (metaData.enrollmentAppName case final String appName)
        enrollmentAppNameAttribute: _bounded(appName),
      if (metaData.enrollmentDeviceName case final String deviceName)
        enrollmentDeviceNameAttribute: _bounded(deviceName),
      if (metaData.clientId case final String clientId)
        AtTelemetryAttributes.clientId: _bounded(clientId),
      if (metaData.appName case final String appName)
        clientAppNameAttribute: _bounded(appName),
      if (metaData.appVersion case final String appVersion)
        clientAppVersionAttribute: _bounded(appVersion),
      if (metaData.platform case final String platform)
        clientPlatformAttribute: _bounded(platform),
      if (clientVersion != AtConnectionMetaData.clientVersionNotAvailable)
        clientSdkVersionAttribute: _bounded(clientVersion),
    };
  }

  String _authTypeName(AuthType authType) {
    return switch (authType) {
      AuthType.cram => 'cram',
      AuthType.pkamLegacy => 'pkam_legacy',
      AuthType.apkam => 'apkam',
    };
  }

  String _bounded(String value) {
    return value.length <= atServerTelemetryMaxValueLength
        ? value
        : value.substring(0, atServerTelemetryMaxValueLength);
  }
}
