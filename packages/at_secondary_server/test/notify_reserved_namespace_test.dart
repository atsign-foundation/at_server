import 'dart:async';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/notification/reserved_namespace.dart';
import 'package:at_secondary/src/verb/handler/notify_all_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:at_utils/at_utils.dart' show AtSignLogger;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// Catalogue: features/notify/peer_reserved_namespace.feature
void main() {
  final Atsign carol = '@carol'.toAtsign();
  final String longName = 'a' * 5000;
  final Matcher isShortened =
      allOf(contains('[truncated'), isNot(contains('a' * (2100 + 1))));
  late NotifyVerbHandler notifyVerbHandler;
  late _ClosableConnection connection;
  late List<String> warnings;
  late List<StreamSubscription<LogRecord>> logs;

  Future<List<AtNotification>> stored() => notifStore.iterate().toList();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  setUp(() async {
    await verbTestsSetUp();
    notifyVerbHandler = NotifyVerbHandler(keyValueStore, notificationManager);
    warnings = [];
    // NOTE each AtSignLogger publishes on a detached logger of its own.
    logs = [
      for (final AtSignLogger logger in [
        notifyVerbHandler.logger,
        notificationManager.logger
      ])
        (logger..level = 'warning')
            .logger
            .onRecord
            .where((record) => record.level == Level.WARNING)
            .listen((record) => warnings.add(record.message))
    ];
    connection = _ClosableConnection();
  });

  tearDown(() async {
    for (final StreamSubscription<LogRecord> log in logs) {
      await log.cancel();
    }
    await verbTestsTearDown();
  });

  void asPeerBob() => connection.metadata
    ..isPolAuthenticated = true
    ..from = true
    ..fromAtSign = bob;

  // NOTE a CRAM connection passes every namespace check, so only the reserved
  // namespace rule stands between it and a notification.
  void asAlicesCramClient() => connection.metadata
    ..isAuthenticated = true
    ..self = true
    ..authType = AuthType.cram;

  group("Another atServer's notification into a reserved namespace is dropped",
      () {
    setUp(asPeerBob);

    for (final (String kind, String command, String namespace) in [
      (
        'update',
        'notify:update:messageType:key:$alice:x.__manage$bob:x',
        '__manage'
      ),
      (
        'delete',
        'notify:delete:messageType:key:$alice:x.__manage$bob',
        '__manage'
      ),
      ('update', 'notify:update:messageType:key:$alice:x.a.__e$bob:x', '__e'),
      (
        'update',
        'notify:update:messageType:key:$alice:x.__atserver$bob:x',
        '__atserver'
      ),
      (
        'update',
        'notify:update:messageType:key:$alice:x.__MANAGE$bob:x',
        '__MANAGE'
      ),
      (
        'update',
        'notify:update:messageType:key:$alice:x.__anything$bob:x',
        '__anything'
      ),
      (
        'update',
        'notify:update:messageType:key:$alice:x.__manage.wavi$bob:x',
        '__manage'
      ),
      (
        'update',
        'notify:update:messageType:key:$alice:x.__E.wavi$bob:x',
        '__E'
      ),
      (
        'update',
        'notify:update:messageType:key:$alice:public:__manage.wavi$bob:x',
        '__manage'
      ),
      (
        'update',
        'notify:update:messageType:key:'
            '$alice:x.new.enrollments.__managex.wavi$bob:x',
        '__managex'
      ),
      (
        'update',
        'notify:update:messageType:key:$alice:x.__manage-x.wavi$bob:x',
        '__manage-x'
      ),
    ]) {
      test('$kind: $command', () async {
        await notifyVerbHandler.process(command, connection);

        expect(connection.lastWrittenData, startsWith('data:success'));
        expect(await stored(), isEmpty, reason: 'nothing is stored');
        expect(warnings, contains(allOf(contains(namespace), contains('$bob'))),
            reason: "@alice's atServer logs a warning naming $namespace and "
                '$bob');
        expect(connection.closed, isFalse, reason: 'the connection stays open');
      });
    }

    test('update: naming a namespace of 5000 characters', () async {
      await notifyVerbHandler.process(
          'notify:update:messageType:key:$alice:x.__$longName$bob:x',
          connection);

      expect(connection.lastWrittenData, startsWith('data:success'));
      final String warning =
          warnings.singleWhere((w) => w.contains('reserved namespace'));
      expect(warning, contains('$bob'));
      expect(warning, isShortened);
    });
  });

  group('Given a peer that has proved itself as $bob by pol', () {
    setUp(asPeerBob);

    test(
        'when it sends a notification of $carol:x.__manage$bob, then it is '
        'refused as one for another atSign', () async {
      await expectLater(
          notifyVerbHandler.process(
              'notify:update:messageType:key:$carol:x.__manage$bob:x',
              connection),
          throwsA(isA<UnAuthorizedException>()
              .having((e) => e.message, 'message', contains('is for $carol'))));
      expect(await stored(), isEmpty, reason: 'nothing is stored');
    });
  });

  group(
      'Another atServer still notifies into an app namespace through a '
      'reserved-looking segment', () {
    setUp(asPeerBob);

    for (final String key in [
      'ck1.__ck.wavi',
      'x.__en.apkamSymmetricKey.wavi'
    ]) {
      test(key, () async {
        await notifyVerbHandler.process(
            'notify:update:messageType:key:$alice:$key$bob:x', connection);

        expect(connection.lastWrittenData, startsWith('data:success'));
        expect((await stored()).single.notification, '$alice:$key$bob');
        expect(warnings, isEmpty);
      });
    }
  });

  group(
      "An atSign's own client may not send a notification into a reserved "
      'namespace', () {
    for (final (String auth, AuthType authType, Atsign recipient) in [
      ('cram', AuthType.cram, bob),
      ('pkam', AuthType.pkamLegacy, bob),
      ('cram', AuthType.cram, alice),
      ('pkam', AuthType.pkamLegacy, alice),
    ]) {
      test('$auth, to $recipient', () async {
        connection.metadata
          ..isAuthenticated = true
          ..self = true
          ..authType = authType;

        await expectLater(
            notifyVerbHandler.process(
                'notify:update:messageType:key:$recipient:x.__manage$alice:x',
                connection),
            throwsA(isA<UnAuthorizedException>().having(
                (e) => e.message,
                'message',
                'Notification to $recipient may not use reserved namespace '
                    '__manage')));
        expect(await stored(), isEmpty, reason: 'nothing is sent or stored');
      });
    }

    test('cram, to $bob, naming a namespace of 5000 characters', () async {
      asAlicesCramClient();

      await expectLater(
          notifyVerbHandler.process(
              'notify:update:messageType:key:$bob:x.__$longName$alice:x',
              connection),
          throwsA(isA<UnAuthorizedException>()
              .having((e) => e.message, 'message', isShortened)));
      expect(await stored(), isEmpty, reason: 'nothing is sent or stored');
    });

    test('cram, to $bob, of PUBLIC:__manage.wavi', () async {
      asAlicesCramClient();

      await expectLater(
          notifyVerbHandler.process(
              'notify:update:messageType:key:$bob:PUBLIC:__manage.wavi$alice:x',
              connection),
          throwsA(isA<UnAuthorizedException>().having(
              (e) => e.message,
              'message',
              'Notification to $bob may not use reserved namespace '
                  '__manage')));
      expect(await stored(), isEmpty, reason: 'nothing is sent or stored');
    });

    test('cram, notify:all to $bob, naming a namespace of 5000 characters',
        () async {
      asAlicesCramClient();

      await expectLater(
          NotifyAllVerbHandler(keyValueStore, notificationManager)
              .process('notify:all:$bob:x.__$longName$alice', connection),
          throwsA(isA<UnAuthorizedException>().having(
              (e) => e.message,
              'message',
              allOf(startsWith('Notification may not use reserved namespace'),
                  isShortened))));
      expect(await stored(), isEmpty, reason: 'nothing is sent or stored');
    });

    test('cram, notify:all to $bob and $alice', () async {
      asAlicesCramClient();

      await expectLater(
          NotifyAllVerbHandler(keyValueStore, notificationManager)
              .process('notify:all:$bob,$alice:x.__manage$alice', connection),
          throwsA(isA<UnAuthorizedException>().having(
              (e) => e.message,
              'message',
              'Notification may not use reserved namespace __manage')));
      expect(await stored(), isEmpty, reason: 'nothing is sent or stored');
    });
  });

  group(
      "An atSign's own client may not send a notification whose key is not a "
      'well-formed atKey', () {
    setUp(asAlicesCramClient);

    for (final String key in [
      'x.__manage:y.wavi',
      'x.__manage y.wavi',
      'x#y.wavi',
    ]) {
      test('$bob:$key$alice', () async {
        await expectLater(
            notifyVerbHandler.process(
                'notify:update:messageType:key:$bob:$key$alice:x', connection),
            throwsA(isA<InvalidSyntaxException>()));
        expect(await stored(), isEmpty, reason: 'nothing is sent or stored');
      });
    }

    for (final String key in ['x#y.wavi', 'x.__manage#y.wavi']) {
      test('notify:all to $bob of $key$alice', () async {
        await expectLater(
            NotifyAllVerbHandler(keyValueStore, notificationManager)
                .process('notify:all:$bob:$key$alice', connection),
            throwsA(isA<InvalidSyntaxException>()));
        expect(await stored(), isEmpty, reason: 'nothing is sent or stored');
      });
    }
  });

  group(
      "Another atServer's notification whose key is not a well-formed atKey "
      'is dropped', () {
    setUp(asPeerBob);

    for (final String key in ['x.__manage:y.wavi', 'x.__manage y.wavi']) {
      test('$alice:$key$bob', () async {
        await notifyVerbHandler.process(
            'notify:update:messageType:key:$alice:$key$bob:x', connection);

        expect(connection.lastWrittenData, startsWith('data:success'));
        expect(await stored(), isEmpty, reason: 'nothing is stored');
        expect(
            warnings,
            contains(
                allOf(contains('$bob'), contains('not a well-formed atKey'))),
            reason: "@alice's atServer logs a warning naming $bob");
        expect(connection.closed, isFalse, reason: 'the connection stays open');
      });
    }

    test('$alice:stream_id.wavi $bob:s1:Zi50eHQ=:12', () async {
      await notifyVerbHandler.process(
          'notify:update:messageType:key:$alice:stream_id.wavi $bob:s1:Zi50eHQ=:12',
          connection);

      expect(connection.lastWrittenData, startsWith('data:success'));
      expect(await stored(), isEmpty, reason: 'nothing is stored');
      expect(
          warnings,
          contains(
              allOf(contains('$bob'), contains('not a well-formed atKey'))),
          reason: "@alice's atServer logs a warning naming $bob");
      expect(connection.closed, isFalse, reason: 'the connection stays open');
    });
  });

  group('Given a key at_commons would build', () {
    for (final String key in [
      'x.wavi',
      "x'y*z\"-_.wavi",
      'public:x.wavi',
      'cached:public:x.wavi',
      'x🛠.wavi',
    ]) {
      test('when it is $key, then it is a well-formed atKey', () {
        expect(isWellFormedAtKey(key), isTrue);
      });
    }
  });

  test(
      'Given a key whose scope is in capitals, when it is PUBLIC:x.wavi, then '
      'it is a well-formed atKey', () {
    expect(isWellFormedAtKey('PUBLIC:x.wavi'), isTrue);
  });

  group(
      "Given a key whose middle segment is or begins with one of the "
      "atServer's own namespaces", () {
    for (final String name in [
      '__manage',
      '__e',
      '__atserver',
      '__global',
      '__private',
      '__otp',
      '__config',
    ]) {
      test('when it is x.$name.wavi, then $name is its reserved namespace', () {
        expect(reservedNamespaceOf('x.$name.wavi'), name);
      });
    }

    for (final String name in [
      '__manage',
      '__atserver',
      '__global',
      '__private',
      '__otp',
      '__config',
    ]) {
      test(
          'when it is x.${name}x.wavi, then ${name}x is its reserved '
          'namespace', () {
        expect(reservedNamespaceOf('x.${name}x.wavi'), '${name}x');
      });
    }

    test('when a middle segment only begins with "__", then it has none', () {
      expect(reservedNamespaceOf('ck1.__ck.wavi'), isNull);
    });

    test('when a middle segment only begins with __e, then it has none', () {
      expect(reservedNamespaceOf('x.__en.apkamSymmetricKey.wavi'), isNull);
    });

    test(
        'when it is public:public:__manage.wavi, then __manage is its reserved '
        'namespace, and it is not a well-formed atKey', () {
      expect(reservedNamespaceOf('public:public:__manage.wavi'), '__manage');
      expect(isWellFormedAtKey('public:public:__manage.wavi'), isFalse);
    });

    test(
        'when it has 50000 public: prefixes, then __manage is its reserved '
        'namespace, found within a second', () {
      final String key = '${'public:' * 50000}__manage.wavi';
      final Stopwatch elapsed = Stopwatch()..start();

      expect(reservedNamespaceOf(key), '__manage');
      expect(elapsed.elapsed, lessThan(Duration(seconds: 1)));
    });

    test(
        'when a segment is __ma nage, then __ma nage is its reserved namespace',
        () {
      expect(reservedNamespaceOf('x.__ma nage.wavi'), '__ma nage');
    });

    test(
        'when its last segment is " __x", then " __x" is its reserved '
        'namespace', () {
      expect(reservedNamespaceOf('x. __x'), ' __x');
    });
  });

  group(
      'An atServer queues no notification to another atSign into a reserved '
      'namespace, whatever asked for it', () {
    test('a sent notification of $bob:x.__manage$alice', () async {
      await notificationManager.notify((AtNotificationBuilder()
            ..type = NotificationType.sent
            ..fromAtSign = '$alice'
            ..toAtSign = '$bob'
            ..notification = '$bob:x.__manage$alice')
          .build());

      expect(await stored(), isEmpty,
          reason: 'no notification of it is queued for @bob');
      expect(
          warnings,
          contains(allOf(
              contains('$bob'), endsWith('reserved namespace __manage'))));
    });

    test('control: a sent notification of $bob:x.wavi$alice is queued',
        () async {
      await notificationManager.notify((AtNotificationBuilder()
            ..type = NotificationType.sent
            ..fromAtSign = '$alice'
            ..toAtSign = '$bob'
            ..notification = '$bob:x.wavi$alice')
          .build());

      expect((await stored()).single.toAtSign, '$bob');
    });

    test('a sent notification of $bob:public:public:__manage.wavi$alice',
        () async {
      await notificationManager.notify((AtNotificationBuilder()
            ..type = NotificationType.sent
            ..fromAtSign = '$alice'
            ..toAtSign = '$bob'
            ..notification = '$bob:public:public:__manage.wavi$alice')
          .build());

      expect(await stored(), isEmpty,
          reason: 'no notification of it is queued for @bob');
      expect(warnings, contains(allOf(contains('__manage'), contains('$bob'))));
    });

    test('a sent notification naming a namespace with a control character',
        () async {
      await notificationManager.notify((AtNotificationBuilder()
            ..type = NotificationType.sent
            ..fromAtSign = '$alice'
            ..toAtSign = '$bob'
            ..notification = '$bob:x.__a\u0007b$alice')
          .build());

      expect(await stored(), isEmpty,
          reason: 'no notification of it is queued for @bob');
      final String warning =
          warnings.singleWhere((w) => w.contains('reserved namespace'));
      expect(warning, isNot(contains('\u0007')));
    });

    test('a queued sent notification of $bob:x.__manage$alice, at start-up',
        () async {
      AtNotification queuedFor(String key) => (AtNotificationBuilder()
            ..type = NotificationType.sent
            ..fromAtSign = '$alice'
            ..toAtSign = '$bob'
            ..notificationStatus = NotificationStatus.queued
            ..notification = key)
          .build();
      final AtNotification reservedOne = queuedFor('$bob:x.__manage$alice');
      final AtNotification appOne = queuedFor('$bob:x.wavi$alice');
      await notifStore.put(reservedOne.id!, reservedOne);
      await notifStore.put(appOne.id!, appOne);
      final List<String?> queued = [];
      final StreamSubscription<AtNotification> sent = notificationManager
          .sent.stream
          .listen((n) => queued.add(n.notification));
      addTearDown(sent.cancel);

      await notificationManager.reEnqueueUndelivered();
      await pumpEventQueue();

      expect(queued, ['$bob:x.wavi$alice'],
          reason: 'control: the stored notification outside a reserved '
              'namespace is queued for @bob, and the other is not');
      expect((await notifStore.get(reservedOne.id!))!.notificationStatus,
          NotificationStatus.errored);
    });

    test(
        'enqueuing a sent notification naming a namespace with a control '
        'character', () {
      expect(
          () => notificationManager.enqueue((AtNotificationBuilder()
                ..type = NotificationType.sent
                ..fromAtSign = '$alice'
                ..toAtSign = '$bob'
                ..notification = '$bob:x.__a\u0007b$alice')
              .build()),
          throwsA(isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                  contains('reserved namespace'), isNot(contains('\u0007'))))));
    });
  });
}

class _ClosableConnection extends DummyInboundConnection {
  bool closed = false;

  @override
  Future<void> close() async {
    closed = true;
  }
}
