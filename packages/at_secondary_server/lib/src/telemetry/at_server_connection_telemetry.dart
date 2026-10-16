import 'dart:convert';
import 'dart:math';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_close_reason.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_web_socket_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
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
  static const String outboundCountAttribute = 'atsign.connections.outbound';
  static const String peerAtSignAttribute = 'atsign.peer.atsign';
  static const String peerInboundAttribute = 'atsign.peer.inbound';
  static const String peerOutboundAttribute = 'atsign.peer.outbound';
  static const String peerLastActiveAtAttribute = 'atsign.peer.last_active_at';

  final AtServerTelemetry _telemetry;
  final Iterable<InboundConnection> Function() _connections;
  final int Function() _capacity;
  final Iterable<OutboundClient> Function() _outboundClients;

  AtServerConnectionTelemetry({
    required AtServerTelemetry telemetry,
    required Iterable<InboundConnection> Function() connections,
    required int Function() capacity,
    required Iterable<OutboundClient> Function() outboundClients,
  })  : _telemetry = telemetry,
        _connections = connections,
        _capacity = capacity,
        _outboundClients = outboundClients;

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
    int outbound = 0;
    final List<Map<String, Object?>> connections = <Map<String, Object?>>[];
    final Map<String, int> inboundPeers = <String, int>{};
    final Map<String, int> outboundPeers = <String, int>{};
    final Map<String, int> peerLastActiveAt = <String, int>{};
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
        if (metaData is InboundConnectionMetadata) {
          _tallyPeer(inboundPeers, peerLastActiveAt, metaData.fromAtSign,
              metaData.lastAccessed ?? metaData.created);
        }
      } else {
        anonymous++;
      }
    }
    for (final OutboundClient client in _outboundClients()) {
      if (!client.isConnectionCreated || client.isInValid()) {
        continue;
      }
      outbound++;
      _tallyPeer(
          outboundPeers, peerLastActiveAt, client.toAtSign, client.lastUsed);
    }
    _telemetry.emitEvent(
      atServerConnectionSnapshotEventName,
      attributes: <String, Object?>{
        selfCountAttribute: self,
        peerCountAttribute: peer,
        anonymousCountAttribute: anonymous,
        monitorCountAttribute: monitor,
        capacityAttribute: _capacity(),
        outboundCountAttribute: outbound,
      },
      body: jsonEncode(<String, Object?>{
        'version': snapshotVersion,
        'connections': connections,
        'peers': _describePeers(inboundPeers, outboundPeers, peerLastActiveAt),
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

  void _tallyPeer(
    Map<String, int> counts,
    Map<String, int> lastActiveAt,
    String? atSign,
    DateTime? lastActive,
  ) {
    final String? peer = _peerAtSign(atSign);
    if (peer == null) {
      return;
    }
    counts[peer] = (counts[peer] ?? 0) + 1;
    if (lastActive != null) {
      final int millis = lastActive.millisecondsSinceEpoch;
      lastActiveAt[peer] = max(lastActiveAt[peer] ?? millis, millis);
    }
  }

  List<Map<String, Object?>> _describePeers(
    Map<String, int> inbound,
    Map<String, int> outbound,
    Map<String, int> lastActiveAt,
  ) {
    return <Map<String, Object?>>[
      for (final String peer in <String>{...inbound.keys, ...outbound.keys})
        <String, Object?>{
          peerAtSignAttribute: peer,
          peerInboundAttribute: inbound[peer] ?? 0,
          peerOutboundAttribute: outbound[peer] ?? 0,
          if (lastActiveAt[peer] case final int millis)
            peerLastActiveAtAttribute: millis,
        },
    ];
  }

  String? _peerAtSign(String? atSign) {
    if (atSign == null) {
      return null;
    }
    try {
      return _bounded(atSign.toAtsign());
    } on InvalidAtSignException {
      return null;
    }
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
