import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/info_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:logging/logging.dart' show Level;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// An expiry [fromNow] away, at millisecond precision, as `eAtn` carries it.
String eAtn(Duration fromNow) => VerbUtil.formatIso8601Micros(
    DateTime.now().toUtcMillisecondsPrecision().add(fromNow));

void main() {
  late NotifyVerbHandler notify;

  setUp(() async {
    await verbTestsSetUp();
    notify = NotifyVerbHandler(keyValueStore, notificationManager);
    inboundConnection.metadata
      ..isAuthenticated = true
      ..authType = AuthType.cram;
  });
  tearDown(() async => await verbTestsTearDown());

  /// Runs [command] through [handler] and returns its reply.
  Future<String> run(dynamic handler, String command) async =>
      (await handler.processInternal(command, inboundConnection)).data!;

  /// Runs [command] as another atServer delivering [from]'s notification.
  Future<String> deliver(String command, {String from = '@bob'}) async {
    inboundConnection.metadata
      ..isAuthenticated = false
      ..isPolAuthenticated = true
      ..fromAtSign = from.toAtsign();
    return run(notify, command);
  }

  /// The notifications the persistent store holds.
  Future<List<AtNotification>> persisted() => notifStore.iterate().toList();

  group('eAtn', () {
    test('sets the notification\'s expiry as the client gives it', () async {
      final expiry = eAtn(const Duration(minutes: 5));
      final id =
          await run(notify, 'notify:eAtn:$expiry:@bob:phone.wavi@alice:v');
      expect((await notificationManager.get(id))!.expiresAt,
          DateTime.parse(expiry));
    });

    test('is honoured by the receiving atServer', () async {
      final expiry = eAtn(const Duration(minutes: 5));
      await deliver('notify:id:n2:update:messageType:key:notifier:system'
          ':eAtn:$expiry:@alice:phone.wavi@bob:v');
      expect((await notificationManager.get('n2'))!.expiresAt,
          DateTime.parse(expiry),
          reason: 'the receiver honours the sender\'s expiry rather than '
              'deriving it again');
    });

    test('with ttln is refused, naming both', () async {
      await expectLater(
          run(
              notify,
              'notify:ttln:60000:eAtn:${eAtn(const Duration(minutes: 5))}'
              ':@bob:phone.wavi@alice:v'),
          throwsA(isA<InvalidSyntaxException>().having((e) => e.message,
              'message', allOf(contains('eAtn'), contains('ttln')))));
      expect(await persisted(), isEmpty);
    });

    test('already past is accepted and the notification dropped', () async {
      final id = await run(notify,
          'notify:eAtn:${eAtn(const Duration(minutes: -1))}:@bob:phone.wavi@alice:v');
      expect(id, isNotEmpty, reason: 'the client still gets its id');
      expect(await notificationManager.get(id), isNull);
      expect(await persisted(), isEmpty);
    });

    test('already past on arrival from another atServer answers success',
        () async {
      final reply = await deliver(
          'notify:id:n3:update:messageType:key:notifier:system'
          ':eAtn:${eAtn(const Duration(minutes: -1))}:@alice:phone.wavi@bob:v');
      expect(reply, 'data:success',
          reason: 'anything else makes the sender retry it');
      expect(await notificationManager.get('n3'), isNull);
    });

    test('takes the FROZEN plain notify literal at_commons pins', () async {
      // FROZEN: at_commons' notification lifetime pin for plain notify.
      final reply = await run(
          notify,
          'notify:id:n1:update:notifier:SYSTEM'
          ':eAtn:2026-10-04T10:45:00.721000Z:eph:isEncrypted:true'
          ':@bob:msg.chat.myapp@alice:CIPHERTEXT');
      expect(reply, 'n1');
    });
  });

  group('eph', () {
    test('is held in memory and never in the store', () async {
      final id = await run(notify, 'notify:eph:@bob:phone.wavi@alice:v');
      expect(await persisted(), isEmpty);
      final held = await notificationManager.get(id);
      expect(held, isNotNull);
      expect(notificationManager.isEphemeral(held!), isTrue);
      expect(await notificationManager.getKeys(), contains(id),
          reason: 'notify:list finds notifications through getKeys');
    });

    test('is a bare flag: eph:true is a syntax error', () async {
      const command = 'notify:eph:@bob:phone.wavi@alice:v';
      await run(notify, command);
      await expectLater(
          run(notify, command.replaceFirst(':eph:', ':eph:true:')),
          throwsA(isA<InvalidSyntaxException>()));
    });

    test('lives no more than two minutes', () async {
      for (final lifetime in [
        'ttln:600000:eph',
        'eAtn:${eAtn(const Duration(minutes: 10))}:eph',
      ]) {
        final id =
            await run(notify, 'notify:$lifetime:@bob:phone.wavi@alice:v');
        final n = (await notificationManager.get(id))!;
        expect(n.expiresAt!.difference(n.notificationDateTime!),
            NotifyVerbHandler.ephemeralMaxLifetime,
            reason: '$lifetime is clamped');
      }
    });

    for (final field in ['ttr:60000', 'ccd:true']) {
      test('with $field is refused, naming it', () async {
        await expectLater(
            run(notify, 'notify:eph:$field:@bob:phone.wavi@alice:v'),
            throwsA(isA<InvalidSyntaxException>().having((e) => e.message,
                'message', contains(field.split(':').first))));
      });
    }

    test('on a delete is refused, naming it', () async {
      await expectLater(
          run(notify, 'notify:delete:eph:@bob:phone.wavi@alice'),
          throwsA(isA<InvalidSyntaxException>()
              .having((e) => e.message, 'message', contains('delete'))));
      expect(await persisted(), isEmpty);
    });

    test('from another atServer is held in memory and never in the store',
        () async {
      await deliver('notify:id:n4:update:messageType:key:notifier:system'
          ':ttln:60000:eph:@alice:phone.wavi@bob:v');
      expect(await persisted(), isEmpty);
      expect(await notificationManager.get('n4'), isNotNull);
    });

    test('from another atServer twice is received once', () async {
      final received = <AtNotification>[];
      final sub = notificationManager.received.stream.listen(received.add);
      for (var i = 0; i < 2; i++) {
        await deliver('notify:id:n5:update:messageType:key:notifier:system'
            ':ttln:60000:eph:@alice:phone.wavi@bob:v');
      }
      await Future.delayed(Duration.zero);
      await sub.cancel();
      expect(received.map((n) => n.id), ['n5'],
          reason: 'a resent eph notification is recognised as already held');
    });

    test('is served to a monitor\'s backlog and notify:list', () async {
      final id = await run(notify, 'notify:eph:@bob:phone.wavi@alice:v');
      final listed = await notificationManager.getFilteredSorted(
          retain: (_) => true, comparator: null);
      expect(listed.map((n) => n.id), contains(id));
    });

    test('is gone after a restart', () async {
      await run(notify, 'notify:eph:@bob:phone.wavi@alice:v');
      final afterRestart =
          NotificationManager(alice, notifStore, MockNotifyConnectionsPool());
      expect(await afterRestart.getUndelivered(), isEmpty,
          reason: 'a restart re-sends only what the store holds');
    });

    test('is dropped from memory once expired', () async {
      final id = await run(
          notify,
          'notify:eAtn:${eAtn(const Duration(milliseconds: 100))}:eph'
          ':@bob:phone.wavi@alice:v');
      expect(await notificationManager.get(id), isNotNull);
      await Future.delayed(const Duration(milliseconds: 200));
      await notificationManager.removeExpired();
      expect(await notificationManager.get(id), isNull);
    });
  });

  group('forwarding to another atServer', () {
    /// The body sent to an atServer listing [features], for the notification
    /// [command] makes.
    Future<(String, AtNotification)> body(
        String command, Set<String> features) async {
      final n = (await notificationManager.get(await run(notify, command)))!;
      final b = notificationManager.prepareNotifyCommandBody(n,
          peerFeatures: features);
      return (b.replaceFirst('id:${n.id}:', 'id:<id>:'), n);
    }

    test('sends eAtn and eph to an atServer listing them', () async {
      final expiry = eAtn(const Duration(minutes: 1));
      final (sent, n) = await body(
          'notify:eAtn:$expiry:eph:@bob:phone.wavi@alice:v',
          {'notify.eAtn', 'notify.eph'});
      // FROZEN: the lifetime fields' wire form between atServers.
      expect(
          sent,
          'id:<id>:update:messageType:key:notifier:SYSTEM:eAtn:$expiry'
          ':eph:ttl:0:ttb:0:isEncrypted:true:@bob:phone.wavi@alice:v');
      final HashMap<String, String?> parsed = getVerbParam(VerbSyntax.notify,
          'notify:${sent.replaceFirst('id:<id>:', 'id:${n.id}:')}');
      expect(parsed[AtConstants.notificationExpiresAt], expiry);
      expect(parsed[AtConstants.ephemeral], 'eph');
    });

    test('sends ttln and no eph to an atServer listing neither', () async {
      final (sent, _) = await body(
          'notify:eAtn:${eAtn(const Duration(minutes: 1))}:eph'
          ':@bob:phone.wavi@alice:v',
          const {});
      expect(
          sent, startsWith('id:<id>:update:messageType:key:notifier:SYSTEM'));
      expect(sent, matches(RegExp(r':ttln:\d+:ttl:0:')),
          reason: 'it still expires when the client asked');
      expect(sent, isNot(contains('eAtn')));
      expect(sent, isNot(contains('eph')),
          reason: 'that atServer persists it instead: correct, just more load');
    });

    test('sends eph after ttln to an atServer listing only eph', () async {
      final (sent, _) = await body(
          'notify:ttln:60000:eph:@bob:phone.wavi@alice:v', {'notify.eph'});
      expect(sent, matches(RegExp(r':ttln:\d+:eph:ttl:0:')));
    });

    test('sends ttln for a notification whose expiry the client left alone',
        () async {
      final (sent, _) = await body('notify:ttln:60000:@bob:phone.wavi@alice:v',
          {'notify.eAtn', 'notify.eph'});
      expect(sent, matches(RegExp(r':ttln:\d+:ttl:0:')));
      expect(sent, isNot(contains('eAtn')));
    });
  });

  group('the sender asks an atServer for its features', () {
    late NotificationManager nm;
    late OutboundClient client;

    setUp(() {
      registerFallbackValue(bob);
      nm = NotificationManager(
          alice, MockAtNotificationKeystore(), MockNotifyConnectionsPool());
      when(() => nm.notifStore.put(any(), any(),
          skipCommit: any(named: 'skipCommit'))).thenAnswer((_) async => null);
      client = MockOutboundClient();
      when(() => nm.notifyConnectionsPool.getOutboundClient(any(),
          connect: any(named: 'connect'))).thenAnswer((_) async => client);
      when(() => client.notify(any(), handshake: any(named: 'handshake')))
          .thenAnswer((_) async => 'data:success');
      when(() => client.usePeerFeature(any())).thenAnswer((invocation) async =>
          invocation.positionalArguments.first == 'notify.eph');
    });
    tearDown(() async => await nm.close());

    AtNotification sentTo(String id) => (AtNotificationBuilder()
          ..id = id
          ..type = NotificationType.sent
          ..fromAtSign = alice
          ..toAtSign = bob
          ..notification = '$bob:phone.wavi$alice'
          ..ttl = 60000)
        .build();

    test('only for a notification carrying eph or eAtn', () async {
      final bodies = <String>[];
      final bothSent = Completer<void>();
      when(() => client.notify(any(), handshake: any(named: 'handshake')))
          .thenAnswer((invocation) async {
        bodies.add(invocation.positionalArguments.first as String);
        if (bodies.length == 2) bothSent.complete();
        return 'data:success';
      });

      await nm.notify(sentTo('plain'));
      await nm.notify(sentTo('ephemeral'), ephemeral: true);
      await bothSent.future.timeout(const Duration(seconds: 5));

      expect(verify(() => client.usePeerFeature(captureAny())).captured,
          ['notify.eph']);
      expect(bodies.first, isNot(contains('eph')));
      expect(bodies.last, contains(':eph:'),
          reason: 'the atServer takes notify.eph');
    });

    test('leaves out a feature the atServer does not take', () async {
      when(() => client.usePeerFeature(any())).thenAnswer((_) async => false);
      final sent = Completer<String>();
      when(() => client.notify(any(), handshake: any(named: 'handshake')))
          .thenAnswer((invocation) async {
        sent.complete(invocation.positionalArguments.first as String);
        return 'data:success';
      });

      await nm.notify(sentTo('ephemeral'), ephemeral: true);

      expect(await sent.future.timeout(const Duration(seconds: 5)),
          isNot(contains(':eph:')),
          reason: 'an atServer listing notify.eph as Retired, or not at all, '
              'would refuse it');
    });
  });

  group('an expiry the client set', () {
    test('is forgotten once delivery ends', () async {
      final nm = NotificationManager(
          alice, MockAtNotificationKeystore(), MockNotifyConnectionsPool());
      when(() => nm.notifStore.put(any(), any(),
          skipCommit: any(named: 'skipCommit'))).thenAnswer((_) async => null);
      final client = MockOutboundClient();
      when(() => nm.notifyConnectionsPool.getOutboundClient(any(),
          connect: any(named: 'connect'))).thenAnswer((_) async => client);
      when(() => client.usePeerFeature(any())).thenAnswer((_) async => false);
      final delivered = Completer<void>();
      when(() => client.notify(any(), handshake: any(named: 'handshake')))
          .thenAnswer((_) async {
        delivered.complete();
        return 'data:success';
      });
      final n = (AtNotificationBuilder()
            ..id = 'explicit'
            ..type = NotificationType.sent
            ..fromAtSign = alice
            ..toAtSign = bob
            ..notification = '$bob:phone.wavi$alice'
            ..expiresAt = DateTime.now().add(const Duration(minutes: 1)))
          .build();
      await nm.notify(n, explicitExpiry: true);
      expect(nm.hasExplicitExpiry(n), isTrue);
      await delivered.future.timeout(const Duration(seconds: 5));
      await Future.delayed(Duration.zero);
      expect(nm.hasExplicitExpiry(n), isFalse,
          reason: 'its delivered status is recorded, so the mark goes');
      await nm.close();
    });
  });

  group('an atServer\'s features over the wire', () {
    /// Answers `info:brief` with [features], a JSON list.
    void answerInfo(String features) =>
        when(() => mockOutboundConnection.write('info:brief\n'))
            .thenAnswer((_) async {
          socketOnDataFn(
              'data:{"version":"3.16.6","features":$features}\n$alice@'
                  .codeUnits);
        });

    /// The warnings [OutboundClient] logs while [body] runs.
    Future<List<String>> warningsDuring(Future<void> Function() body) async {
      final prior = OutboundClient.logger.logger.level;
      OutboundClient.logger.level = 'warning';
      final warnings = <String>[];
      final sub = OutboundClient.logger.logger.onRecord.listen((r) {
        if (r.level >= Level.WARNING) warnings.add(r.message);
      });
      try {
        await body();
      } finally {
        await sub.cancel();
        OutboundClient.logger.logger.level = prior;
      }
      return warnings;
    }

    test('are asked for once per connection', () async {
      await outboundClientWithHandshake.connect();
      answerInfo('[{"name":"notify.eph","status":"GA"}]');
      expect(await outboundClientWithHandshake.usePeerFeature('notify.eph'),
          isTrue);
      expect(await outboundClientWithHandshake.usePeerFeature('notify.eph'),
          isTrue);
      expect(await outboundClientWithHandshake.usePeerFeature('notify.eAtn'),
          isFalse);
      verify(() => mockOutboundConnection.write('info:brief\n')).called(1);
    });

    test('are none when the atServer answers info with an error', () async {
      await outboundClientWithHandshake.connect();
      expect(await outboundClientWithHandshake.usePeerFeature('notify.eph'),
          isFalse,
          reason: 'the mock answers every unstubbed command with an error, '
              'as an atServer refusing the request does');
    });

    test('are none when the atServer\'s answer to info cannot be read',
        () async {
      await outboundClientWithHandshake.connect();
      when(() => mockOutboundConnection.write('info:brief\n'))
          .thenAnswer((_) async {
        socketOnDataFn('data:not json\n$alice@'.codeUnits);
      });
      expect(await outboundClientWithHandshake.usePeerFeature('notify.eph'),
          isFalse);
    });

    test('leave out one listed as Retired', () async {
      await outboundClientWithHandshake.connect();
      answerInfo('[{"name":"notify.eph","status":"Retired"},'
          '{"name":"notify.eAtn","status":"GA"}]');
      expect(await outboundClientWithHandshake.usePeerFeature('notify.eph'),
          isFalse);
      expect(await outboundClientWithHandshake.usePeerFeature('notify.eAtn'),
          isTrue,
          reason: 'the same answer lists a GA feature, which is taken');
    });

    test('warn once per connection on using one that is not GA', () async {
      final client = outboundClientWithHandshake;
      await client.connect();
      answerInfo('[{"name":"notify.eph","status":"Beta"},'
          '{"name":"notify.eAtn","status":"GA"}]');
      final warned = [
        allOf(contains('@bob'), contains('notify.eph'), contains('Beta'))
      ];

      expect(
          await warningsDuring(() async {
            expect(await client.usePeerFeature('notify.eph'), isTrue);
            expect(await client.usePeerFeature('notify.eph'), isTrue);
            expect(await client.usePeerFeature('notify.eAtn'), isTrue);
          }),
          warned,
          reason: 'one warning for the Beta feature, none for the GA one');

      client.isConnectionCreated = false;
      await client.connect();
      expect(
          await warningsDuring(() async {
            expect(await client.usePeerFeature('notify.eph'), isTrue);
          }),
          warned,
          reason: 'a new connection asks again and warns again');
      verify(() => mockOutboundConnection.write('info:brief\n')).called(2);
    });
  });

  test('another atServer reads info\'s features as the statuses listed', () {
    final features = InfoFeatures.parse('data:${jsonEncode({
          'version': '3.16.6',
          'features': InfoVerbHandler.features,
        })}')!;
    // FROZEN: the names and statuses on the wire.
    expect(features.statusOf('notify.eph'), 'GA');
    expect(features.statusOf('notify.eAtn'), 'GA');
    expect(features.statusOf('notify.all'), 'Deprecated');
    expect(['notify.eph', 'notify.eAtn', 'notify.all'].every(features.has),
        isTrue);
  });

  test('info lists notify.eph and notify.eAtn', () async {
    final response = await InfoVerbHandler(keyValueStore)
        .processInternal('info:brief', inboundConnection);
    final List features = jsonDecode(response.data!)['features'];
    expect(features.map((f) => f['name']),
        containsAll(['notify.eph', 'notify.eAtn']));
  });
}
