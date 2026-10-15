import 'dart:convert';

import 'package:at_secondary/src/connection/inbound/inbound_connection_close_reason.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_web_socket_connection.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_telemetry/at_telemetry.dart';

import 'at_server_telemetry.dart';
import 'at_server_telemetry_constants.dart';

final class AtServerConnectionTelemetry {
  static const int snapshotVersion = 1;
  static const int maxValueLength = 64;
  static const String connectionIdAttribute = 'atsign.connection.id';
  static const String openedAtAttribute = 'atsign.connection.opened_at';
  static const String lastActiveAtAttribute =
      'atsign.connection.last_active_at';
  static const String transportAttribute = 'atsign.connection.transport';
  static const String authTypeAttribute = 'atsign.connection.auth_type';
  static const String monitorAttribute = 'atsign.connection.monitor';
  static const String selfNotificationsAttribute =
      'atsign.connection.self_notifications';
  static const String closeReasonAttribute = 'atsign.connection.close_reason';
  static const String durationAttribute = 'atsign.connection.duration_ms';
  static const String enrollmentAppNameAttribute = 'atsign.enrollment.app_name';
  static const String enrollmentDeviceNameAttribute =
      'atsign.enrollment.device_name';
  static const String clientAppNameAttribute = 'atsign.client.app_name';
  static const String clientAppVersionAttribute = 'atsign.client.app_version';
  static const String clientPlatformAttribute = 'atsign.client.platform';
  static const String clientSdkVersionAttribute = 'atsign.client.sdk_version';
  static const String selfCountAttribute = 'atsign.connections.self';
  static const String peerCountAttribute = 'atsign.connections.peer';
  static const String anonymousCountAttribute = 'atsign.connections.anonymous';
  static const String monitorCountAttribute = 'atsign.connections.monitor';
  static const String capacityAttribute = 'atsign.connections.capacity';

  final AtServerTelemetry _telemetry;
  final Iterable<InboundConnection> Function() _connections;
  final int Function() _capacity;

  AtServerConnectionTelemetry({
    required AtServerTelemetry telemetry,
    required Iterable<InboundConnection> Function() connections,
    required int Function() capacity,
  })  : _telemetry = telemetry,
        _connections = connections,
        _capacity = capacity;

  void authenticated(AtConnection connection) {
    if (!_telemetry.isEnabled || connection is! InboundConnection) {
      return;
    }
    final AtConnectionMetaData metaData = connection.metaData;
    if (metaData is! InboundConnectionMetadata || !metaData.isAuthenticated) {
      return;
    }
    metaData.telemetryAnnounced = true;
    _telemetry.emitEvent(
      atServerConnectionAuthenticatedEventName,
      attributes: _describe(connection, metaData),
    );
  }

  void monitoring(
    InboundConnection connection, {
    required bool selfNotifications,
  }) {
    final AtConnectionMetaData metaData = connection.metaData;
    if (!_telemetry.isEnabled ||
        metaData is! InboundConnectionMetadata ||
        !metaData.telemetryAnnounced) {
      return;
    }
    _telemetry.emitEvent(
      atServerConnectionMonitoringEventName,
      attributes: <String, Object?>{
        connectionIdAttribute: metaData.connectionId,
        selfNotificationsAttribute: selfNotifications,
      },
    );
  }

  void closed(InboundConnection connection) {
    final AtConnectionMetaData metaData = connection.metaData;
    if (!_telemetry.isEnabled ||
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
    _telemetry.emitEvent(
      atServerConnectionClosedEventName,
      attributes: <String, Object?>{
        connectionIdAttribute: metaData.connectionId,
        closeReasonAttribute: reason.wireName,
        if (created != null)
          durationAttribute:
              DateTime.timestamp().difference(created).inMilliseconds,
      },
    );
  }

  void snapshot() {
    if (!_telemetry.isEnabled) {
      return;
    }
    int self = 0;
    int peer = 0;
    int anonymous = 0;
    int monitor = 0;
    final List<Map<String, Object?>> connections = <Map<String, Object?>>[];
    for (final InboundConnection connection in _connections()) {
      if (connection.isInValid()) {
        continue;
      }
      final AtConnectionMetaData metaData = connection.metaData;
      if (metaData.isAuthenticated && metaData is InboundConnectionMetadata) {
        self++;
        final bool isMonitor = connection.isMonitor == true;
        if (isMonitor) {
          monitor++;
        }
        final DateTime? lastActive = metaData.lastAccessed ?? metaData.created;
        connections.add(<String, Object?>{
          ..._describe(connection, metaData),
          monitorAttribute: isMonitor,
          if (lastActive != null)
            lastActiveAtAttribute: lastActive.millisecondsSinceEpoch,
        });
      } else if (metaData.isPolAuthenticated) {
        peer++;
      } else {
        anonymous++;
      }
    }
    _telemetry.emitEvent(
      atServerConnectionSnapshotEventName,
      attributes: <String, Object?>{
        selfCountAttribute: self,
        peerCountAttribute: peer,
        anonymousCountAttribute: anonymous,
        monitorCountAttribute: monitor,
        capacityAttribute: _capacity(),
      },
      body: jsonEncode(<String, Object?>{
        'version': snapshotVersion,
        'connections': connections,
      }),
    );
  }

  Map<String, Object?> _describe(
    InboundConnection connection,
    InboundConnectionMetadata metaData,
  ) {
    final DateTime? created = metaData.created;
    final AuthType? authType = metaData.authType;
    final String clientVersion = metaData.clientVersion;
    return <String, Object?>{
      connectionIdAttribute: metaData.connectionId,
      if (created != null) openedAtAttribute: created.millisecondsSinceEpoch,
      transportAttribute:
          connection is InboundWebSocketConnection ? 'websocket' : 'tls',
      if (authType != null) authTypeAttribute: _authTypeName(authType),
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
    return value.length <= maxValueLength
        ? value
        : value.substring(0, maxValueLength);
  }
}
