import 'dart:async';

import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:at_telemetry/at_telemetry.dart';
import 'package:logging/logging.dart' show Level, LogRecord;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'enrollment_test_utils.dart';
import 'telemetry_test_support.dart';
import 'test_utils.dart';

/// Catalogue: features/telemetry/heartbeat_connections.feature
void main() {
  const Duration interval = Duration(milliseconds: 5);
  late RecordingExporter exporter;
  late AtServerTelemetry telemetry;
  int reads = 0;

  InboundConnectionPool pool() => atServer.inboundConnectionManager.pool;

  Map<String, int> connectedEnrollments() {
    reads++;
    return pool().getConnectedEnrollments();
  }

  void open(List<DummyInboundConnection> connections) {
    for (final DummyInboundConnection connection in connections) {
      pool().add(connection);
    }
  }

  Future<Map<String, Object?>> nextHeartbeat() async {
    exporter.records.clear();
    return (await exporter.firstNamed('atsign.atserver.lifecycle.heartbeat'))
        .attributes;
  }

  setUp(() async {
    await verbTestsSetUp();
    pool().resize(200);
    reads = 0;
    exporter = RecordingExporter();
    telemetry = AtServerTelemetry(heartbeatInterval: interval);
    enableRecording(telemetry, exporter,
        connectedEnrollments: connectedEnrollments);
  });

  tearDown(() async {
    await telemetry.shutdown();
    await verbTestsTearDown();
  });

  test('A heartbeat with no device connected counts 0 and lists none',
      () async {
    expect(await nextHeartbeat(), {
      'atsign.atserver.connected_enrollment_count': 0,
    });
  });

  test('An enrollment with two open connections is listed once, counting both',
      () async {
    final String e1 = Uuid().v4();
    open([_apkam(e1), _apkam(e1)]);

    expect(await nextHeartbeat(), {
      'atsign.atserver.connected_enrollment_count': 1,
      'atsign.atserver.connected_enrollments': [
        {'atsign.enrollment.id': e1, 'atsign.connection.count': 2},
      ],
    });
  });

  test('A legacy pkam connection is listed as primary', () async {
    final _Connection connection = _Connection();
    await legacyPkam(connection);
    expect(connection.metadata.authType, AuthType.pkamLegacy,
        reason: 'precondition: authenticated by legacy pkam');
    expect(connection.metadata.enrollmentId, 'primary',
        reason: 'precondition: legacy pkam stands on primary');
    open([connection]);

    expect(await nextHeartbeat(), {
      'atsign.atserver.connected_enrollment_count': 1,
      'atsign.atserver.connected_enrollments': [
        {'atsign.enrollment.id': 'primary', 'atsign.connection.count': 1},
      ],
    });
  });

  test('A CRAM connection is neither listed nor counted', () async {
    final _Connection enrolled = _cram();
    final String e3 = await cramEnrollRequest(enrolled);
    expect(enrolled.metadata.enrollmentId, e3,
        reason: 'precondition: the connection carries the new id');
    open([_cram(), enrolled]);

    expect(await nextHeartbeat(), {
      'atsign.atserver.connected_enrollment_count': 0,
    });
  });

  test(
      'Connections from other atSigns and unauthenticated connections are not '
      'counted', () async {
    final String e1 = Uuid().v4();
    final String e2 = Uuid().v4();
    final _Connection peer = _Connection()
      ..metadata.from = true
      ..metadata.fromAtSign = bob
      ..metadata.isPolAuthenticated = true;
    final _Connection fromSelf = _Connection()..metadata.self = true;
    final _Connection failedPkam = _apkam(e1)..metadata.isAuthenticated = false;
    open([peer, fromSelf, failedPkam, _apkam(e2)]);

    expect(await nextHeartbeat(), {
      'atsign.atserver.connected_enrollment_count': 1,
      'atsign.atserver.connected_enrollments': [
        {'atsign.enrollment.id': e2, 'atsign.connection.count': 1},
      ],
    });
  });

  test('Closed and invalid connections are not counted', () async {
    final String e1 = Uuid().v4();
    final String e2 = Uuid().v4();
    open([
      _apkam(e1),
      _apkam(e1)..metadata.isClosed = true,
      _apkam(e2)..metadata.isStale = true,
    ]);

    expect(await nextHeartbeat(), {
      'atsign.atserver.connected_enrollment_count': 1,
      'atsign.atserver.connected_enrollments': [
        {'atsign.enrollment.id': e1, 'atsign.connection.count': 1},
      ],
    });
  });

  test('More than 100 connected enrollments are cut to the first 100 by id',
      () async {
    final List<String> ids = [for (int i = 0; i < 150; i++) Uuid().v4()];
    open([for (final String id in ids) _apkam(id)]);

    final Map<String, Object?> heartbeat = await nextHeartbeat();

    expect(heartbeat['atsign.atserver.connected_enrollment_count'], 150);
    expect(heartbeat['atsign.atserver.connected_enrollments'], [
      for (final String id in (ids..sort()).take(100))
        {'atsign.enrollment.id': id, 'atsign.connection.count': 1},
    ]);
  });

  group('when management revokes and reinstates an enrollment', () {
    late ETU etu;
    late String e1;
    late String e2;

    Future<String> approved(String deviceName) async {
      final String enrollmentId = await etu.createPendingEnrollment(
          appName: 'chat',
          deviceName: deviceName,
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null);
      await etu.approveEnrollment(etu.primaryEnId, enrollmentId);
      return enrollmentId;
    }

    setUp(() async {
      etu = ETU();
      await etu.init();
      e1 = await approved('phone');
      e2 = await approved('tablet');
    });

    test('Revoking an enrollment drops it from the next heartbeat', () async {
      final List<_Connection> e1Connections = [_apkam(e1), _apkam(e1)];
      open([...e1Connections, _apkam(e2)]);
      expect(
          (await nextHeartbeat())['atsign.atserver.connected_enrollments'],
          unorderedEquals([
            {'atsign.enrollment.id': e1, 'atsign.connection.count': 2},
            {'atsign.enrollment.id': e2, 'atsign.connection.count': 1},
          ]),
          reason: 'precondition: both are listed');

      await etu.revokeEnrollment(etu.primaryEnId, e1);

      expect(
          e1Connections.every((_Connection c) => c.metadata.isClosed), isTrue,
          reason: "precondition: revoke closed e1's connections");
      expect(await nextHeartbeat(), {
        'atsign.atserver.connected_enrollment_count': 1,
        'atsign.atserver.connected_enrollments': [
          {'atsign.enrollment.id': e2, 'atsign.connection.count': 1},
        ],
      });
    });

    test('A reinstated enrollment is listed again once its device reconnects',
        () async {
      open([_apkam(e1)]);
      await etu.revokeEnrollment(etu.primaryEnId, e1);

      await etu.unrevokeEnrollment(etu.primaryEnId, e1);

      expect(await nextHeartbeat(), {
        'atsign.atserver.connected_enrollment_count': 0,
      });

      open([_apkam(e1)]);

      expect(await nextHeartbeat(), {
        'atsign.atserver.connected_enrollment_count': 1,
        'atsign.atserver.connected_enrollments': [
          {'atsign.enrollment.id': e1, 'atsign.connection.count': 1},
        ],
      });
    });
  });

  test('A failure reading the connections still sends the heartbeat', () async {
    final List<Object> uncaught = <Object>[];
    final List<String> warnings = <String>[];
    Map<String, Object?>? heartbeat;

    await runZonedGuarded(() async {
      final RecordingExporter failingExporter = RecordingExporter();
      final AtServerTelemetry failing =
          AtServerTelemetry(heartbeatInterval: interval);
      final Level priorLevel = failing.logger.logger.level;
      failing.logger.level = 'warning';
      addTearDown(() => failing.logger.logger.level = priorLevel);
      final StreamSubscription<LogRecord> subscription = failing
          .logger.logger.onRecord
          .where((LogRecord record) => record.level == Level.WARNING)
          .listen((LogRecord record) => warnings.add(record.message));
      enableRecording(failing, failingExporter,
          connectedEnrollments: () =>
              throw ConcurrentModificationError(pool()));
      heartbeat = (await failingExporter
              .firstNamed('atsign.atserver.lifecycle.heartbeat'))
          .attributes;
      await failing.shutdown();
      await subscription.cancel();
    }, (Object error, StackTrace _) => uncaught.add(error));

    expect(heartbeat, isEmpty,
        reason: 'neither attribute, so a reader takes it as unknown');
    expect(
        warnings,
        contains(
            startsWith('Heartbeat sent without its connected enrollments')));
    expect(uncaught, isEmpty);
  });

  test('No heartbeat follows lifecycle.stopped', () async {
    await nextHeartbeat();

    await telemetry.shutdown();
    final int readsAtShutdown = reads;
    await Future<void>.delayed(interval * 10);

    final List<String?> names = eventNames(exporter.records);
    expect(names.last, 'atsign.atserver.lifecycle.stopped');
    expect(names.where((String? name) => name == names.last), hasLength(1));
    expect(reads, readsAtShutdown);
  });

  test('lifecycle.started and lifecycle.stopped carry no connection attributes',
      () async {
    open([_apkam(Uuid().v4())]);
    final RecordingExporter lifecycleExporter = RecordingExporter();
    final AtServerTelemetry lifecycle =
        AtServerTelemetry(heartbeatInterval: interval)
          ..enable(
              exporter: lifecycleExporter,
              serverId: '@alice',
              bootId: 'boot',
              connectedEnrollments: connectedEnrollments);
    final AtTelemetryLogRecord heartbeat = await lifecycleExporter
        .firstNamed('atsign.atserver.lifecycle.heartbeat');
    expect(
        heartbeat.attributes['atsign.atserver.connected_enrollment_count'], 1,
        reason: 'control: the heartbeats of this telemetry count it');

    await lifecycle.shutdown();

    final AtTelemetryLogRecord started =
        await lifecycleExporter.firstNamed('atsign.atserver.lifecycle.started');
    final AtTelemetryLogRecord stopped =
        await lifecycleExporter.firstNamed('atsign.atserver.lifecycle.stopped');
    expect(started.attributes, isEmpty);
    expect(stopped.attributes, isEmpty);
  });
}

/// A connection that, like a socket, is invalid once closed or stale.
final class _Connection extends DummyInboundConnection {
  @override
  bool isInValid() => metadata.isClosed || metadata.isStale;

  @override
  Future<void> close() async {
    metadata.isClosed = true;
  }
}

_Connection _apkam(String enrollmentId) => _Connection()
  ..metadata.isAuthenticated = true
  ..metadata.authType = AuthType.apkam
  ..metadata.enrollmentId = enrollmentId
  ..metadata.sessionID = 'apkam-${Uuid().v4()}';

_Connection _cram() => _Connection()
  ..metadata.isAuthenticated = true
  ..metadata.authType = AuthType.cram
  ..metadata.sessionID = 'cram-${Uuid().v4()}';
