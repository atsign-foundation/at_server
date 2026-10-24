import 'dart:async';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
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
  final AtSignLogger logger = AtSignLogger('AtServerTelemetry');
  final Map<String, int> _undelivered = <String, int>{};
  AtTelemetry? _telemetry;
  AtServerHeartbeatScheduler? _heartbeat;
  Timer? _undeliveredReport;

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
      logger.warning('Ignoring telemetry event outside the atServer namespace');
      return;
    }

    // AtTelemetry throws on invalid attribute values. Telemetry must never
    // take the server down, so log and drop the event instead.
    try {
      telemetry.event(name, attributes: attributes);
    } on ArgumentError catch (error) {
      logger.warning('Ignoring invalid telemetry event $name: '
          '${error.name} ${error.message}');
    } on Object catch (error) {
      logger.warning('Dropped telemetry event $name: $error');
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
    return telemetry
        .shutdown(timeout: timeout)
        .whenComplete(_reportUndelivered);
  }

  void connectionAuthenticated(AtConnection connection) {
    if (!isEnabled || connection is! InboundConnection) {
      return;
    }
    final AtConnectionMetaData metaData = connection.metaData;
    if (metaData is! InboundConnectionMetadata ||
        metaData.isClosed ||
        !metaData.isAuthenticated) {
      return;
    }
    metaData.telemetryAnnounced = true;
    emitEvent(
      atServerConnectionAuthenticatedEventName,
      attributes: <String, Object?>{
        connectionIdAttribute: metaData.connectionId,
        connectionTransportAttribute: _transportOf(connection),
        if (_authTypeOf(metaData) case final String authType)
          connectionAuthTypeAttribute: authType,
        if (metaData.enrollmentId case final String enrollmentId)
          AtTelemetryAttributes.enrollmentId: _bounded(enrollmentId),
        if (metaData.enrollmentAppName case final String appName)
          enrollmentAppNameAttribute: _bounded(appName),
        if (metaData.enrollmentDeviceName case final String deviceName)
          enrollmentDeviceNameAttribute: _bounded(deviceName),
      },
    );
  }

  void connectionMonitoring(InboundConnection connection) {
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
    emitEvent(
      atServerConnectionClosedEventName,
      attributes: <String, Object?>{
        connectionIdAttribute: metaData.connectionId,
        connectionCloseReasonAttribute: reason.wireName,
      },
    );
  }

  void notificationDelivered(AtNotification notification) {
    _emitNotificationEvent(
      atServerNotificationDeliveredEventName,
      notification,
      <String, Object?>{
        if (notification.toAtSign case final String toAtSign)
          notificationToAttribute: toAtSign,
      },
    );
  }

  void notificationExpired(AtNotification notification) {
    _emitNotificationEvent(
      atServerNotificationExpiredEventName,
      notification,
      <String, Object?>{
        if (notification.toAtSign case final String toAtSign)
          notificationToAttribute: toAtSign,
      },
    );
  }

  void notificationError(AtNotification notification) {
    _emitNotificationEvent(
      atServerNotificationErrorEventName,
      notification,
      <String, Object?>{
        if (notification.toAtSign case final String toAtSign)
          notificationToAttribute: toAtSign,
      },
    );
  }

  void notificationReceived(
    AtNotification notification, {
    List<InboundConnectionMetadata> pushedTo =
        const <InboundConnectionMetadata>[],
  }) {
    _emitNotificationEvent(
      atServerNotificationReceivedEventName,
      notification,
      <String, Object?>{
        if (notification.fromAtSign case final String fromAtSign)
          notificationFromAttribute: fromAtSign,
        notificationPushCountAttribute: pushedTo.length,
        if (pushedTo.isNotEmpty)
          notificationPushedToAttribute: <Map<String, Object?>>[
            for (final InboundConnectionMetadata connection in pushedTo)
              _pushTargetOf(connection),
          ],
      },
    );
  }

  void _onError(Object error, StackTrace stackTrace) {
    if (error is AtTelemetryDroppedException) {
      _undelivered.update(
        error.logRecord.eventName ?? 'log record',
        (int count) => count + 1,
        ifAbsent: () => 1,
      );
      _undeliveredReport ??= Timer(Duration.zero, _reportUndelivered);
      return;
    }
    logger.warning('Telemetry export failed: $error');
  }

  void _reportUndelivered() {
    _undeliveredReport?.cancel();
    _undeliveredReport = null;
    if (_undelivered.isEmpty) {
      return;
    }
    final int total =
        _undelivered.values.fold(0, (int sum, int count) => sum + count);
    final String counts = _undelivered.entries
        .map((MapEntry<String, int> entry) => '${entry.key} x${entry.value}')
        .join(', ');
    _undelivered.clear();
    logger.warning('Telemetry events not delivered: $total ($counts)');
  }

  void _emitNotificationEvent(
    String name,
    AtNotification notification,
    Map<String, Object?> attributes,
  ) {
    emitEvent(
      name,
      attributes: <String, Object?>{
        ...attributes,
        if (notification.id case final String id)
          AtTelemetryAttributes.notificationIds: <String>[id],
      },
    );
  }

  Map<String, Object?> _pushTargetOf(InboundConnectionMetadata connection) {
    return <String, Object?>{
      connectionIdAttribute: connection.connectionId,
      if (connection.enrollmentId case final String enrollmentId)
        AtTelemetryAttributes.enrollmentId: _bounded(enrollmentId),
      if (_authTypeOf(connection) case final String authType)
        connectionAuthTypeAttribute: authType,
    };
  }

  String _transportOf(InboundConnection connection) {
    return connection is InboundWebSocketConnection ? 'websocket' : 'tls';
  }

  String? _authTypeOf(InboundConnectionMetadata metaData) {
    if (!metaData.isAuthenticated) {
      return null;
    }
    return switch (metaData.authType) {
      AuthType.cram => 'cram',
      AuthType.pkamLegacy => 'pkam_legacy',
      AuthType.apkam => 'apkam',
      null => null,
    };
  }

  String _bounded(String value) {
    return value.length <= atServerTelemetryMaxValueLength
        ? value
        : value.substring(0, atServerTelemetryMaxValueLength);
  }
}
