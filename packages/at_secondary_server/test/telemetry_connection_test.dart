import 'dart:convert';

import 'package:at_secondary/src/connection/inbound/inbound_connection_close_reason.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/telemetry/at_server_connection_telemetry.dart';
import 'package:at_secondary/src/telemetry/at_server_heartbeat_scheduler.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_constants.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_telemetry/at_telemetry.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  late List<AtTelemetryLogRecord> records;
  late AtServerTelemetry telemetry;
  late List<InboundConnection> connections;
  late AtServerConnectionTelemetry subject;

  InboundConnectionImpl newConnection() {
    return InboundConnectionImpl(FakeSocket(), '_session');
  }

  InboundConnectionMetadata metaDataOf(InboundConnection connection) {
    return connection.metaData as InboundConnectionMetadata;
  }

  InboundConnectionImpl apkamConnection() {
    final InboundConnectionImpl connection = newConnection();
    metaDataOf(connection)
      ..isAuthenticated = true
      ..authType = AuthType.apkam
      ..enrollmentId = 'enrollment-1'
      ..enrollmentAppName = 'wavi'
      ..enrollmentDeviceName = 'pixel-8'
      ..clientId = 'client-1'
      ..appName = 'wavi'
      ..appVersion = '2.1.0'
      ..platform = 'android'
      ..clientVersion = '3.15.0';
    return connection;
  }

  List<String?> names() {
    return records
        .map((AtTelemetryLogRecord record) => record.eventName)
        .toList();
  }

  setUp(() {
    records = <AtTelemetryLogRecord>[];
    telemetry = AtServerTelemetry(heartbeatInterval: null)
      ..enable(
        exporter: _RecordingExporter(records),
        serverId: '$alice',
        bootId: 'boot-1',
      );
    connections = <InboundConnection>[];
    subject = AtServerConnectionTelemetry(
      telemetry: telemetry,
      connections: () => connections,
      capacity: () => 200,
    );
    records.clear();
  });

  tearDown(() async {
    await telemetry.shutdown();
  });

  group('authenticated', () {
    test('describes the enrollment and the client', () {
      final InboundConnectionImpl connection = apkamConnection();
      final InboundConnectionMetadata metaData = metaDataOf(connection);

      subject.authenticated(connection);

      expect(names(), <String>[atServerConnectionAuthenticatedEventName]);
      expect(records.single.attributes, <String, Object?>{
        AtServerConnectionTelemetry.connectionIdAttribute:
            metaData.connectionId,
        AtServerConnectionTelemetry.openedAtAttribute:
            metaData.created!.millisecondsSinceEpoch,
        AtServerConnectionTelemetry.transportAttribute: 'tls',
        AtServerConnectionTelemetry.authTypeAttribute: 'apkam',
        AtTelemetryAttributes.enrollmentId: 'enrollment-1',
        AtServerConnectionTelemetry.enrollmentAppNameAttribute: 'wavi',
        AtServerConnectionTelemetry.enrollmentDeviceNameAttribute: 'pixel-8',
        AtTelemetryAttributes.clientId: 'client-1',
        AtServerConnectionTelemetry.clientAppNameAttribute: 'wavi',
        AtServerConnectionTelemetry.clientAppVersionAttribute: '2.1.0',
        AtServerConnectionTelemetry.clientPlatformAttribute: 'android',
        AtServerConnectionTelemetry.clientSdkVersionAttribute: '3.15.0',
      });
      expect(metaData.telemetryAnnounced, isTrue);
    });

    test('leaves out what the connection does not know', () {
      final InboundConnectionImpl connection = newConnection();
      metaDataOf(connection)
        ..isAuthenticated = true
        ..authType = AuthType.cram;

      subject.authenticated(connection);

      expect(
        records.single.attributes.keys,
        unorderedEquals(<String>[
          AtServerConnectionTelemetry.connectionIdAttribute,
          AtServerConnectionTelemetry.openedAtAttribute,
          AtServerConnectionTelemetry.transportAttribute,
          AtServerConnectionTelemetry.authTypeAttribute,
        ]),
      );
      expect(
        records
            .single.attributes[AtServerConnectionTelemetry.authTypeAttribute],
        'cram',
      );
    });

    test('bounds long values', () {
      final InboundConnectionImpl connection = apkamConnection();
      metaDataOf(connection).enrollmentDeviceName = 'd' * 500;

      subject.authenticated(connection);

      expect(
        records.single.attributes[
            AtServerConnectionTelemetry.enrollmentDeviceNameAttribute],
        'd' * AtServerConnectionTelemetry.maxValueLength,
      );
    });

    test('ignores connections that are not the atSign\'s own', () {
      final InboundConnectionImpl anonymous = newConnection();
      final InboundConnectionImpl peer = newConnection();
      metaDataOf(peer).isPolAuthenticated = true;

      subject.authenticated(anonymous);
      subject.authenticated(peer);

      expect(records, isEmpty);
      expect(metaDataOf(anonymous).telemetryAnnounced, isFalse);
      expect(metaDataOf(peer).telemetryAnnounced, isFalse);
    });

    test('sends nothing while telemetry is off', () async {
      await telemetry.shutdown();
      records.clear();
      final InboundConnectionImpl connection = apkamConnection();

      subject.authenticated(connection);

      expect(records, isEmpty);
      expect(metaDataOf(connection).telemetryAnnounced, isFalse);
    });
  });

  group('closed', () {
    test('reports the first reason the connection was closed for', () {
      final InboundConnectionImpl connection = apkamConnection();
      subject.authenticated(connection);
      records.clear();

      InboundConnectionCloseReason.idleTimeout.markOn(connection);
      InboundConnectionCloseReason.clientClosed.markOn(connection);
      subject.closed(connection);
      subject.closed(connection);

      expect(names(), <String>[atServerConnectionClosedEventName]);
      final Map<String, Object?> attributes = records.single.attributes;
      expect(attributes[AtServerConnectionTelemetry.connectionIdAttribute],
          metaDataOf(connection).connectionId);
      expect(attributes[AtServerConnectionTelemetry.closeReasonAttribute],
          'idle_timeout');
      expect(attributes[AtServerConnectionTelemetry.durationAttribute],
          isA<int>().having((int value) => value, 'duration', isNonNegative));
    });

    test('falls back to stale, then unknown', () {
      final InboundConnectionImpl stale = apkamConnection();
      final InboundConnectionImpl unexplained = apkamConnection();
      subject.authenticated(stale);
      subject.authenticated(unexplained);
      records.clear();
      metaDataOf(stale).isStale = true;

      subject.closed(stale);
      subject.closed(unexplained);

      expect(
        records.map((AtTelemetryLogRecord record) => record
            .attributes[AtServerConnectionTelemetry.closeReasonAttribute]),
        <String>['stale', 'unknown'],
      );
    });

    test('says nothing about a connection it never announced', () {
      final InboundConnectionImpl connection = apkamConnection();

      subject.closed(connection);

      expect(records, isEmpty);
    });

    test('says nothing when the server shuts down', () {
      final InboundConnectionImpl connection = apkamConnection();
      subject.authenticated(connection);
      records.clear();

      InboundConnectionCloseReason.serverShutdown.markOn(connection);
      subject.closed(connection);

      expect(records, isEmpty);
      expect(metaDataOf(connection).telemetryAnnounced, isFalse);
    });
  });

  group('monitoring', () {
    test('follows only announced connections', () {
      final InboundConnectionImpl quiet = apkamConnection();
      final InboundConnectionImpl announced = apkamConnection();
      subject.authenticated(announced);
      records.clear();

      subject.monitoring(quiet, selfNotifications: false);
      subject.monitoring(announced, selfNotifications: true);

      expect(names(), <String>[atServerConnectionMonitoringEventName]);
      expect(records.single.attributes, <String, Object?>{
        AtServerConnectionTelemetry.connectionIdAttribute:
            metaDataOf(announced).connectionId,
        AtServerConnectionTelemetry.selfNotificationsAttribute: true,
      });
    });
  });

  group('snapshot', () {
    test('lists valid own connections and counts the rest', () {
      final InboundConnectionImpl device = apkamConnection()..isMonitor = true;
      final InboundConnectionImpl closed = apkamConnection();
      metaDataOf(closed).isClosed = true;
      final InboundConnectionImpl peer = newConnection();
      metaDataOf(peer).isPolAuthenticated = true;
      final InboundConnectionImpl anonymous = newConnection();
      connections.addAll(<InboundConnection>[device, closed, peer, anonymous]);

      subject.snapshot();

      expect(names(), <String>[atServerConnectionSnapshotEventName]);
      final AtTelemetryLogRecord record = records.single;
      expect(record.attributes, <String, Object?>{
        AtServerConnectionTelemetry.selfCountAttribute: 1,
        AtServerConnectionTelemetry.peerCountAttribute: 1,
        AtServerConnectionTelemetry.anonymousCountAttribute: 1,
        AtServerConnectionTelemetry.monitorCountAttribute: 1,
        AtServerConnectionTelemetry.capacityAttribute: 200,
      });
      final Map<String, Object?> body =
          jsonDecode(record.body as String) as Map<String, Object?>;
      expect(body['version'], AtServerConnectionTelemetry.snapshotVersion);
      final List<Object?> listed = body['connections'] as List<Object?>;
      final Map<String, Object?> entry = listed.single as Map<String, Object?>;
      expect(entry[AtServerConnectionTelemetry.connectionIdAttribute],
          metaDataOf(device).connectionId);
      expect(entry[AtServerConnectionTelemetry.enrollmentDeviceNameAttribute],
          'pixel-8');
      expect(entry[AtServerConnectionTelemetry.monitorAttribute], isTrue);
      expect(entry[AtServerConnectionTelemetry.lastActiveAtAttribute],
          metaDataOf(device).created!.millisecondsSinceEpoch);
    });

    test('is sent even when nothing is connected', () {
      subject.snapshot();

      final AtTelemetryLogRecord record = records.single;
      expect(
          record.attributes[AtServerConnectionTelemetry.selfCountAttribute], 0);
      expect(
        jsonDecode(record.body as String),
        <String, Object?>{
          'version': AtServerConnectionTelemetry.snapshotVersion,
          'connections': <Object?>[],
        },
      );
    });
  });

  group('state reports', () {
    test('follow the started event when telemetry is enabled', () async {
      final List<AtTelemetryLogRecord> exported = <AtTelemetryLogRecord>[];
      final AtServerTelemetry reporting =
          AtServerTelemetry(heartbeatInterval: null);
      reporting.enable(
        exporter: _RecordingExporter(exported),
        serverId: '$alice',
        bootId: 'boot-2',
        reportState: () =>
            reporting.emitEvent(atServerConnectionSnapshotEventName),
      );
      await reporting.shutdown();

      expect(
        exported.map((AtTelemetryLogRecord record) => record.eventName),
        <String>[
          atServerStartedEventName,
          atServerConnectionSnapshotEventName,
          atServerStoppedEventName,
        ],
      );
    });

    test('that throw are dropped', () async {
      final List<AtTelemetryLogRecord> exported = <AtTelemetryLogRecord>[];
      final AtServerTelemetry reporting =
          AtServerTelemetry(heartbeatInterval: null)
            ..enable(
              exporter: _RecordingExporter(exported),
              serverId: '$alice',
              bootId: 'boot-3',
              reportState: () => throw StateError('broken'),
            );

      expect(reporting.isEnabled, isTrue);
      await reporting.shutdown();
      expect(
        exported.map((AtTelemetryLogRecord record) => record.eventName),
        <String>[atServerStartedEventName, atServerStoppedEventName],
      );
    });

    test('follow every heartbeat', () async {
      int beats = 0;
      final AtServerHeartbeatScheduler scheduler = AtServerHeartbeatScheduler(
        telemetry: telemetry,
        interval: const Duration(milliseconds: 10),
        offset: Duration.zero,
        onBeat: () => beats++,
      )..start();

      await Future<void>.delayed(const Duration(milliseconds: 60));
      scheduler.stop();

      final int heartbeats = names()
          .where((String? name) => name == atServerHeartbeatEventName)
          .length;
      expect(beats, greaterThan(0));
      expect(beats, heartbeats);
    });
  });

  group('close reasons', () {
    test('the pool marks every connection it clears at shutdown', () {
      final InboundConnectionPool pool =
          InboundConnectionPool(serverAtSign: alice, size: 10);
      final InboundConnectionImpl connection = apkamConnection();
      pool.add(connection);

      pool.clearAllConnections();

      expect(metaDataOf(connection).closeReason,
          InboundConnectionCloseReason.serverShutdown);
    });

    test('the pool marks stale connections it reaps', () {
      final InboundConnectionPool pool =
          InboundConnectionPool(serverAtSign: alice, size: 10);
      final InboundConnectionImpl connection = apkamConnection();
      metaDataOf(connection).isStale = true;
      pool.add(connection);

      pool.clearInvalidConnections();

      expect(metaDataOf(connection).closeReason,
          InboundConnectionCloseReason.stale);
    });

    test('every connection gets its own id', () {
      final Set<String> ids = <String>{
        for (int i = 0; i < 100; i++) metaDataOf(newConnection()).connectionId,
      };

      expect(ids, hasLength(100));
      expect(ids.first, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
    });
  });
}

final class _RecordingExporter implements AtTelemetryLogRecordExporter {
  final List<AtTelemetryLogRecord> _records;

  _RecordingExporter(this._records);

  @override
  Future<bool> export(
    AtTelemetryLogRecord logRecord,
    AtTelemetryResource resource,
  ) async {
    _records.add(logRecord);
    return true;
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> shutdown() async {}
}
