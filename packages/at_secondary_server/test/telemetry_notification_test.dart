import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops.dart' show MlDsa65PureDartAlgo;
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart'
    show OutboundClient;
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry.dart';
import 'package:at_secondary/src/telemetry/notification_telemetry.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/cram_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/monitor_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/otp_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/pkam_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:at_telemetry/at_telemetry.dart';
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart' show Level, LogRecord;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'telemetry_test_support.dart';
import 'test_utils.dart';

/// Catalogue: features/telemetry/notification_events.feature
void main() {
  late RecordingExporter exporter;

  setUpAll(() {
    registerFallbackValue(AtNotificationBuilder().build());
  });

  setUp(() {
    exporter = RecordingExporter();
  });

  group(
      'The sending atServer reports the outcome of each notification it sends',
      () {
    late AtServerTelemetry telemetry;
    late NotificationManager sender;

    AtNotification n1({DateTime? expiresAt}) => (AtNotificationBuilder()
          ..id = 'n1'
          ..type = NotificationType.sent
          ..fromAtSign = alice
          ..toAtSign = bob
          ..notification = '@bob:phone.wavi@alice'
          ..expiresAt = expiresAt)
        .build();

    Future<void> send(AtNotification n) =>
        sender.getPerAtSignNotifSender(bob).send(n);

    setUp(() {
      telemetry = AtServerTelemetry(heartbeatInterval: null);
      enableRecording(telemetry, exporter);
      sender = NotificationManager(
          alice, MockAtNotificationKeystore(), MockNotifyConnectionsPool(),
          telemetry: NotificationTelemetry(telemetry));
      when(() => sender.notifStore.put(any(), any(),
          skipCommit: any(named: 'skipCommit'))).thenAnswer((_) async => null);
    });

    tearDown(() async {
      await sender.close();
      await telemetry.shutdown();
    });

    test("@bob's atServer answers data:success", () async {
      final OutboundClient client = MockOutboundClient();
      when(() => sender.notifyConnectionsPool.getOutboundClient(bob))
          .thenAnswer((_) async => client);
      when(() => client.notify(any())).thenAnswer((_) async => 'data:success');

      await send(n1());

      expect(eventNames(exporter.records),
          ['atsign.atserver.notification.delivered']);
      expect(exporter.records.single.attributes, {
        'atsign.notification.to': '@bob',
        'atsign.notification.ids': ['n1'],
      });
    });

    test('n1 expires before it is delivered', () async {
      await send(
          n1(expiresAt: DateTime.now().subtract(const Duration(minutes: 1))));

      expect(eventNames(exporter.records),
          ['atsign.atserver.notification.expired']);
      expect(exporter.records.single.attributes, {
        'atsign.notification.to': '@bob',
        'atsign.notification.ids': ['n1'],
      });
    });

    test('@bob is not in the atDirectory', () async {
      final MockSecondaryAddressFinder directory = MockSecondaryAddressFinder();
      when(() => sender.notifyConnectionsPool.secondaryAddressFinder)
          .thenReturn(directory);
      when(() => sender.notifyConnectionsPool.getOutboundClient(bob))
          .thenAnswer((_) async => throw Exception('no route to @bob'));
      when(() => directory.findSecondary(bob)).thenAnswer(
          (_) async => throw SecondaryNotFoundException('@bob not found'));

      await send(n1());

      expect(
          eventNames(exporter.records), ['atsign.atserver.notification.error']);
      expect(exporter.records.single.attributes, {
        'atsign.notification.to': '@bob',
        'atsign.notification.ids': ['n1'],
      });
    });
  });

  group('on the receiving atServer', () {
    late NotifyVerbHandler notify;
    late _MonitorConnection Function(String) apkam;
    final Duration defaultTimeout = NotificationManager.livePushTimeout;

    setUp(() async {
      await verbTestsSetUp();
      enableRecording(serverTelemetry, exporter);
      notify = NotifyVerbHandler(keyValueStore, notificationManager);
      apkam = (String enrollmentId) => _MonitorConnection()
        ..metadata.isAuthenticated = true
        ..metadata.authType = AuthType.apkam
        ..metadata.enrollmentId = enrollmentId;
    });

    tearDown(() async {
      NotificationManager.livePushTimeout = defaultTimeout;
      await verbTestsTearDown();
    });

    Future<Response> deliver(String id, {Atsign? from}) async {
      final Atsign sender = from ?? bob;
      final DummyInboundConnection peer = DummyInboundConnection()
        ..metadata.isPolAuthenticated = true
        ..metadata.fromAtSign = sender;
      return notify.processInternal(
          'notify:id:$id:update:messageType:key:notifier:system'
          ':ttln:60000:@alice:phone.wavi$sender:v',
          peer);
    }

    Future<void> monitor(DummyInboundConnection connection) async {
      await MonitorVerbHandler(keyValueStore, notificationManager)
          .processVerb(Response(), HashMap<String, String?>(), connection);
    }

    Future<Map<String, Object?>> report() async =>
        (await exporter.firstNamed('atsign.atserver.notification.received'))
            .attributes;

    test('A received notification lists each device it was written to once',
        () async {
      final String e1 =
          await createAndPersistAnEnrollment('chat', 'phone', {'wavi': 'rw'});
      final String e2 =
          await createAndPersistAnEnrollment('chat', 'tablet', {'wavi': 'rw'});
      final List<_MonitorConnection> connections = [
        apkam(e1),
        apkam(e1),
        apkam(e2),
        _cram(),
      ];
      for (final _MonitorConnection connection in connections) {
        await monitor(connection);
      }

      await deliver('n-1');

      expect(await report(), {
        'atsign.notification.from': '@bob',
        'atsign.notification.push_count': 2,
        'atsign.notification.pushed_to': [
          {'atsign.enrollment.id': e1},
          {'atsign.enrollment.id': e2},
        ],
        'atsign.notification.ids': ['n-1'],
      });
      for (final _MonitorConnection connection in connections) {
        expect(connection.ids, ['n-1'],
            reason: 'all four were written it, CRAM included');
      }
    });

    test('A legacy pkam connection is listed as primary', () async {
      final _MonitorConnection connection = _MonitorConnection();
      await _legacyPkam(connection);
      expect(connection.metadata.enrollmentId, 'primary',
          reason: 'precondition: legacy pkam stands on primary');
      await monitor(connection);

      await deliver('n-2');

      expect((await report())['atsign.notification.pushed_to'], [
        {'atsign.enrollment.id': 'primary'},
      ]);
    });

    test('A CRAM connection that ran enroll:request is not listed', () async {
      final _MonitorConnection connection = _cram();
      final String e3 = await _cramEnrollRequest(connection);
      expect(connection.metadata.enrollmentId, e3,
          reason: 'precondition: the connection carries the new id');
      await monitor(connection);

      await deliver('n-3');

      final Map<String, Object?> attributes = await report();
      expect(attributes['atsign.notification.push_count'], 0);
      expect(attributes.containsKey('atsign.notification.pushed_to'), isFalse);
      expect(connection.ids, ['n-3'], reason: 'it was written, not listed');
    });

    test('A device that may not read the notification is not listed', () async {
      final String e1 =
          await createAndPersistAnEnrollment('chat', 'phone', {'wavi': 'rw'});
      final String e2 =
          await createAndPersistAnEnrollment('chat', 'tablet', {'buzz': 'rw'});
      await monitor(apkam(e1));
      await monitor(apkam(e2));

      await deliver('n-4');

      expect((await report())['atsign.notification.pushed_to'], [
        {'atsign.enrollment.id': e1},
      ]);
    });

    test('A push is reported under the enrollment it was written for',
        () async {
      final String e1 =
          await createAndPersistAnEnrollment('chat', 'phone', {'wavi': 'rw'});
      final String e2 =
          await createAndPersistAnEnrollment('chat', 'tablet', {'wavi': 'rw'});
      final _MonitorConnection connection = apkam(e1);
      await monitor(connection);
      connection.metadata.enrollmentId = e2;

      await deliver('n-5');

      expect((await report())['atsign.notification.pushed_to'], [
        {'atsign.enrollment.id': e2},
      ]);
    });

    test('A push still waiting after 10 seconds is not counted', () async {
      NotificationManager.livePushTimeout = const Duration(seconds: 1);
      final String e1 =
          await createAndPersistAnEnrollment('chat', 'phone', {'wavi': 'rw'});
      final _MonitorConnection connection = apkam(e1);
      await monitor(connection);
      final Completer<void> writing = connection.holdNextWrite();

      final Response response =
          await deliver('n-6').timeout(const Duration(milliseconds: 300));
      expect(response.data, 'data:success',
          reason: 'the notify verb answers before the report goes out');

      expect((await report())['atsign.notification.push_count'], 0);
      writing.complete();
      await notificationManager.monitorsIdle;
      expect(connection.ids, ['n-6'], reason: 'the push is still written');
    });

    test(
        'Given a sent report, when it has gone out, then the manager no longer holds it',
        () async {
      await deliver('n-sent');
      await report();
      await pumpEventQueue();

      expect(notificationManager.pendingReportCount, 0);
    });

    test(
        "Given a client's notify to its own atSign, when it is pushed to a monitor, then no notification.received is sent",
        () async {
      final _MonitorConnection monitoring = _cram();
      await monitor(monitoring);
      final DummyInboundConnection client = DummyInboundConnection()
        ..metadata.isAuthenticated = true
        ..metadata.authType = AuthType.cram;

      await notify.processInternal(
          'notify:update:messageType:key:@alice:phone.wavi@alice:v', client);
      await notificationManager.monitorsIdle;
      await pumpEventQueue();

      expect(monitoring.ids, hasLength(1), reason: 'control: it was pushed');
      expect(
          eventNames(exporter.records,
              prefix: 'atsign.atserver.notification.received'),
          isEmpty);
    });

    test(
        'A later notification with an id already held is dropped, whoever sent it',
        () async {
      final String e1 =
          await createAndPersistAnEnrollment('chat', 'phone', {'wavi': 'rw'});
      final _MonitorConnection connection = apkam(e1);
      await monitor(connection);
      final Level priorLevel = notify.logger.logger.level;
      notify.logger.level = 'warning';
      addTearDown(() => notify.logger.logger.level = priorLevel);
      final List<String> warnings = <String>[];
      final StreamSubscription<LogRecord> subscription = notify
          .logger.logger.onRecord
          .where((LogRecord record) => record.level == Level.WARNING)
          .listen((LogRecord record) => warnings.add(record.message));
      addTearDown(subscription.cancel);

      final Response first = await deliver('n9');
      await report();
      final Response second = await deliver('n9', from: '@carol'.toAtsign());
      await notificationManager.monitorsIdle;
      await pumpEventQueue();

      expect([first.data, second.data], ['data:success', 'data:success']);
      expect(warnings, ['We have already received notification n9']);
      expect((await notificationManager.get('n9'))?.fromAtSign, '@bob');
      expect(connection.ids, ['n9'], reason: "only @bob's was pushed");
      expect([
        for (final AtTelemetryLogRecord r in exporter.records)
          if (r.eventName == 'atsign.atserver.notification.received')
            r.attributes['atsign.notification.from']
      ], [
        '@bob'
      ]);
    });

    test('A repeated delivery of the same id is reported once', () async {
      await deliver('n-8');
      await deliver('n-8');
      await report();
      await pumpEventQueue();

      expect(eventNames(exporter.records),
          ['atsign.atserver.notification.received']);
    });

    test('A report still waiting at shutdown is sent before telemetry stops',
        () async {
      NotificationManager.livePushTimeout = const Duration(milliseconds: 200);
      final String e1 =
          await createAndPersistAnEnrollment('chat', 'phone', {'wavi': 'rw'});
      final String e2 =
          await createAndPersistAnEnrollment('chat', 'tablet', {'wavi': 'rw'});
      final _MonitorConnection written = apkam(e1);
      await monitor(written);
      final _MonitorConnection held = apkam(e2);
      await monitor(held);
      final Completer<void> writing = held.holdNextWrite();
      await deliver('n-9');
      await written.firstWrite;

      await notificationManager.close();
      await serverTelemetry.shutdown();
      writing.complete();

      expect(eventNames(exporter.records), [
        'atsign.atserver.notification.received',
        'atsign.atserver.lifecycle.stopped',
      ]);
      expect(
          exporter.records.first.attributes['atsign.notification.pushed_to'], [
        {'atsign.enrollment.id': e1},
      ]);
    });

    group('The atServer sends no connection events', () {
      List<String?> connectionEvents() =>
          eventNames(exporter.records, prefix: 'atsign.atserver.connection.');

      test('control: a notification event is recorded here', () async {
        await deliver('n-10');
        await report();
        expect(eventNames(exporter.records), isNotEmpty);
      });

      test('a client authenticates with cram', () async {
        final DummyInboundConnection connection = DummyInboundConnection()
          ..metadata.sessionID = 'cram-session';
        await keyValueStore.put(
            'privatekey:at_secret', AtData()..data = 'the-cram-secret');
        await keyValueStore.put(
            'private:cram-session$alice', AtData()..data = 'challenge');
        final String digest = sha512
            .convert(utf8.encode('the-cram-secretcram-session$alice:challenge'))
            .toString();
        final Response response = Response();

        await CramVerbHandler(keyValueStore, accessLog: atAccessLog)
            .processVerb(response,
                HashMap<String, String?>.of({'digest': digest}), connection);

        expect(response.data, 'success', reason: 'precondition');
        await pumpEventQueue();
        expect(connectionEvents(), isEmpty);
      });

      test('a client authenticates with pkam', () async {
        final _MonitorConnection connection = _MonitorConnection();
        await _legacyPkam(connection);
        expect(connection.metadata.isAuthenticated, isTrue,
            reason: 'precondition');
        await pumpEventQueue();
        expect(connectionEvents(), isEmpty);
      });

      test("a CRAM connection's enroll:request is approved", () async {
        await _cramEnrollRequest(_cram());
        await pumpEventQueue();
        expect(connectionEvents(), isEmpty);
      });

      test('an authenticated connection runs monitor', () async {
        await monitor(_cram());
        await pumpEventQueue();
        expect(connectionEvents(), isEmpty);
      });

      test('an authenticated connection closes', () async {
        final InboundConnectionImpl connection =
            InboundConnectionImpl(FakeSocket(), 'closing-session');
        connection.metaData
          ..isAuthenticated = true
          ..authType = AuthType.cram;

        await connection.close();

        expect(connection.metaData.isClosed, isTrue, reason: 'precondition');
        await pumpEventQueue();
        expect(connectionEvents(), isEmpty);
      });
    });
  });

  test(
      'Given telemetry off, when a received notification is queued for a report, then no report or timer is started',
      () async {
    await verbTestsSetUp();
    addTearDown(verbTestsTearDown);
    int timers = 0;

    runZoned(
        () => notificationManager.enqueue(
            (AtNotificationBuilder()
                  ..id = 'n-off'
                  ..fromAtSign = bob
                  ..toAtSign = alice
                  ..notification = '@alice:phone.wavi@bob'
                  ..notificationDateTime = DateTime.now()
                  ..type = NotificationType.received)
                .build(),
            report: true),
        zoneSpecification: ZoneSpecification(createTimer: (Zone self,
            ZoneDelegate parent,
            Zone zone,
            Duration duration,
            void Function() f) {
      timers++;
      return parent.createTimer(zone, duration, f);
    }));

    expect(notificationManager.pendingReportCount, 0);
    expect(timers, 0);
  });

  test('Nothing is sent while telemetry is off', () async {
    await verbTestsSetUp();
    addTearDown(verbTestsTearDown);
    final _MonitorConnection monitoring = _cram();
    await MonitorVerbHandler(keyValueStore, notificationManager)
        .processVerb(Response(), HashMap<String, String?>(), monitoring);
    final DummyInboundConnection peer = DummyInboundConnection()
      ..metadata.isPolAuthenticated = true
      ..metadata.fromAtSign = bob;
    serverTelemetry.enable(exporter: exporter, serverId: '@alice', bootId: 'b');
    await serverTelemetry.shutdown();
    exporter.records.clear();

    await NotifyVerbHandler(keyValueStore, notificationManager).processInternal(
        'notify:id:n-11:update:messageType:key:ttln:60000:@alice:phone.wavi@bob:v',
        peer);
    await notificationManager.monitorsIdle;
    final NotificationManager sender = NotificationManager(
        alice, MockAtNotificationKeystore(), MockNotifyConnectionsPool(),
        telemetry: NotificationTelemetry(serverTelemetry));
    addTearDown(sender.close);
    when(() => sender.notifStore.put(any(), any(),
        skipCommit: any(named: 'skipCommit'))).thenAnswer((_) async => null);
    final OutboundClient client = MockOutboundClient();
    when(() => sender.notifyConnectionsPool.getOutboundClient(bob))
        .thenAnswer((_) async => client);
    when(() => client.notify(any())).thenAnswer((_) async => 'data:success');
    await sender.getPerAtSignNotifSender(bob).send((AtNotificationBuilder()
          ..id = 'n-12'
          ..type = NotificationType.sent
          ..fromAtSign = alice
          ..toAtSign = bob
          ..notification = '@bob:phone.wavi@alice')
        .build());
    await pumpEventQueue();

    expect(monitoring.ids, ['n-11'], reason: 'control: it was pushed');
    expect(exporter.records, isEmpty);
  });

  group('undelivered events', () {
    late AtServerTelemetry telemetry;
    late NotificationTelemetry notifications;
    late List<String> warnings;
    AtNotification settledAs(NotificationStatus status) =>
        (AtNotificationBuilder()
              ..id = 'n-5'
              ..toAtSign = bob
              ..notificationStatus = status)
            .build();

    setUp(() async {
      telemetry = AtServerTelemetry(heartbeatInterval: null);
      notifications = NotificationTelemetry(telemetry);
      final Level priorLevel = telemetry.logger.logger.level;
      telemetry.logger.level = 'warning';
      addTearDown(() => telemetry.logger.logger.level = priorLevel);
      warnings = <String>[];
      final StreamSubscription<LogRecord> subscription = telemetry
          .logger.logger.onRecord
          .where((LogRecord record) => record.level == Level.WARNING)
          .listen((LogRecord record) => warnings.add(record.message));
      addTearDown(subscription.cancel);
      exporter = RecordingExporter(delivers: false);
      enableRecording(telemetry, exporter);
      await pumpEventQueue();
      exporter.records.clear();
      warnings.clear();
    });

    tearDown(() async {
      await telemetry.shutdown();
    });

    test('make one warning for each failure, not one for each event', () async {
      for (int i = 0; i < 500; i++) {
        notifications.settled(settledAs(NotificationStatus.delivered));
      }
      await pumpEventQueue();
      notifications.settled(settledAs(NotificationStatus.expired));
      await pumpEventQueue();

      expect(exporter.records, hasLength(501));
      expect(warnings, <String>[
        'Telemetry events not delivered: 500 '
            '(atsign.atserver.notification.delivered x500)',
        'Telemetry events not delivered: 1 '
            '(atsign.atserver.notification.expired x1)',
      ]);
    });

    test('are reported before shutdown returns', () async {
      for (int i = 0; i < 3; i++) {
        notifications.settled(settledAs(NotificationStatus.delivered));
      }

      await telemetry.shutdown();
      final List<String> atShutdown = List<String>.of(warnings);
      await pumpEventQueue();

      expect(atShutdown, <String>[
        'Telemetry events not delivered: 4 '
            '(atsign.atserver.notification.delivered x3, '
            'atsign.atserver.lifecycle.stopped x1)',
      ]);
      expect(warnings, atShutdown);
    });
  });
}

/// A monitor client's connection: keeps every write, and can hold its next.
class _MonitorConnection extends DummyInboundConnection {
  final List<String> _writes = <String>[];
  final Completer<void> _firstWrite = Completer<void>();
  Completer<void>? _hold;

  /// Completes once something has been written to this connection.
  Future<void> get firstWrite => _firstWrite.future;

  /// The ids of the notifications written to this connection, in order.
  List<Object?> get ids => [
        for (final String w in _writes)
          if (w.startsWith('notification: '))
            jsonDecode(w.substring('notification: '.length))['id'],
      ];

  /// Holds the next write until the returned completer completes.
  Completer<void> holdNextWrite() => _hold = Completer<void>();

  @override
  Future<void> write(String data) async {
    final Completer<void>? hold = _hold;
    _hold = null;
    if (hold != null) {
      await hold.future;
    }
    _writes.add(data);
    lastWrittenData = data;
    if (!_firstWrite.isCompleted) {
      _firstWrite.complete();
    }
  }
}

_MonitorConnection _cram() => _MonitorConnection()
  ..metadata.isAuthenticated = true
  ..metadata.authType = AuthType.cram
  ..metadata.sessionID = 'cram-${Uuid().v4()}';

/// Authenticates [connection] with a legacy pkam, as a flat credential.
Future<void> _legacyPkam(DummyInboundConnection connection) async {
  final keyPair = await MlDsa65PureDartAlgo().generateKeyPair();
  await keyValueStore.put(AtConstants.atPkamPublicKey,
      AtData()..data = base64Encode(keyPair.publicKey),
      skipCommit: true);
  const String sessionId = 'pkam-session';
  const String challenge = 'a-per-connection-challenge';
  await keyValueStore.put(
      'private:$sessionId$alice', AtData()..data = challenge);
  final signature = await MlDsa65PureDartAlgo().signBytes(
      Uint8List.fromList(utf8.encode('$sessionId$alice:$challenge')),
      secretKey: keyPair.secretKey);
  connection.metadata.sessionID = sessionId;
  final Response response = Response();
  await PkamVerbHandler(keyValueStore).processVerb(
      response,
      getVerbParam(VerbSyntax.pkam,
          'pkam:signingAlgo:mldsa65:${base64Encode(signature)}'),
      connection);
  expect(response.data, 'success', reason: 'precondition: legacy pkam');
}

/// Sends an enroll:request on CRAM [connection], approved on the spot, and
/// returns the new enrollment's id.
Future<String> _cramEnrollRequest(DummyInboundConnection connection) async {
  final OtpVerbHandler otp = OtpVerbHandler(keyValueStore);
  final String passcode = otp.generateOTP();
  await otp.savePasscode(passcode, ttl: 5000, isSpp: false);
  final Response response = Response();
  await EnrollVerbHandler(keyValueStore, enMgr, notificationManager)
      .processVerb(
          response,
          getVerbParam(
              VerbSyntax.enroll,
              'enroll:request:{"otp":"$passcode","appName":"chat"'
              ',"deviceName":"phone","namespaces":{"wavi":"rw"}'
              ',"apkamPublicKey":"pk-${Uuid().v4()}"'
              ',"encryptedAPKAMSymmetricKey":"sym"}'),
          connection);
  final Map<String, Object?> body =
      jsonDecode(response.data!) as Map<String, Object?>;
  expect(body['status'], 'approved', reason: 'precondition');
  return body['enrollmentId'] as String;
}
