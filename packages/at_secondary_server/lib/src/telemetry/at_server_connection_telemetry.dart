import 'package:at_secondary/src/connection/inbound/inbound_connection_close_reason.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_web_socket_connection.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_telemetry/at_telemetry.dart';

import 'at_server_telemetry.dart';
import 'at_server_telemetry_constants.dart';

final class AtServerConnectionTelemetry {
  static const int maxValueLength = 64;
  static const String connectionIdAttribute = 'atsign.connection.id';
  static const String openedAtAttribute = 'atsign.connection.opened_at';
  static const String transportAttribute = 'atsign.connection.transport';
  static const String authTypeAttribute = 'atsign.connection.auth_type';
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

  final AtServerTelemetry _telemetry;

  AtServerConnectionTelemetry({required AtServerTelemetry telemetry})
      : _telemetry = telemetry;

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
