import 'dart:async';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_lookup/at_lookup.dart' as at_lookup;
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/bootstrapper.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/executor/default_verb_executor.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// An atSign of 55 characters after its @.
final Atsign max = '@${'m' * 55}'.toAtsign();

/// An atSign of 56 characters after its @.
final String over = '@${'o' * 56}';

/// What the atServer answers an atSign of more than 55 characters with, on a
/// connection that has not authenticated or on a peer's.
const String tooLongUnauthenticated = 'error:AT0003-Exception: invalid @sign:'
    ' must have at most 55 characters after the @\n@';

/// What the atServer answers an atSign of more than 55 characters with, on
/// @alice's authenticated client's connection.
const String tooLongForAlice = 'error:AT0003-Invalid syntax : invalid @sign:'
    ' must have at most 55 characters after the @\n@alice@';

/// The atDirectory as the outbound clients see it: it holds no atSign.
late MockSecondaryAddressFinder atDirectory;
late OutboundClientManager outbound;
late DefaultVerbHandlerManager verbs;

/// Serves [atSign], as the atServer's own, with the verb handlers it runs.
void serve(Atsign atSign) {
  AtSecondaryServerImpl.getInstance().currentAtSign = atSign;
  outbound = OutboundClientManager(atDirectory, mockOutboundConnectionFactory);
  verbs = DefaultVerbHandlerManager(
    keyValueStore,
    outbound,
    AtCacheManager(atSign, keyValueStore, outbound, notificationManager),
    statsNotificationService,
    notificationManager,
    enMgr,
    atSign,
    commitLog: atCommitLog,
    accessLog: atAccessLog,
  );
}

/// Sends [command] on [connection] as the atServer does: the executor picks
/// the handler, and GlobalExceptionHandler answers whatever it throws.
Future<void> send(String command, FakeInboundConnection connection) async {
  try {
    await DefaultVerbExecutor().execute(command, connection, verbs);
  } on Exception catch (e) {
    await GlobalExceptionHandler.getInstance()
        .handle(e, atConnection: connection);
  }
}

/// A [FakeInboundConnection] that also records the atSign a from: binds it
/// to.
class Connection extends FakeInboundConnection {
  Connection(InboundConnectionMetadata metadata)
      : super(FakeSocket(), metadata);

  String? _initiatedBy;

  @override
  String? get initiatedBy => _initiatedBy;

  @override
  set initiatedBy(String? atSign) => _initiatedBy = atSign;
}

/// A connection that has sent nothing yet.
Connection unauthenticated() => Connection(InboundConnectionMetadata());

/// @alice's authenticated client's connection.
Connection client() => Connection(InboundConnectionMetadata()
  ..isAuthenticated = true
  ..authType = AuthType.cram);

/// A connection on which [atSign]'s atServer has proved itself by pol.
Connection peer(Atsign atSign) => Connection(InboundConnectionMetadata()
  ..isPolAuthenticated = true
  ..fromAtSign = atSign);

/// The atServer's keys, last commit, access-log entries and notifications.
Future<List<Object?>> footprint() async => [
      (await (await keyValueStore.getKeys()).toList())..sort(),
      atCommitLog.lastCommittedSequenceNumber(),
      atAccessLog.entriesCount(),
      (await notifStore.iterate().toList()).length,
    ];

/// The status of each notification stored for [atSign] to deliver.
Future<List<NotificationStatus?>> sentTo(String atSign) async => [
      await for (final n in notifStore.iterate())
        if (n.type == NotificationType.sent && n.toAtSign == atSign)
          n.notificationStatus
    ];

/// Expects that no outbound client asked the atDirectory for any atSign.
void expectNothingLookedUp() {
  verifyNever(() => atDirectory.findSecondary(any()));
  verifyNever(() => mockSecondaryAddressFinder.findSecondary(any()));
}

void main() {
  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await verbTestsSetUp();
    atDirectory = MockSecondaryAddressFinder();
    when(() => atDirectory.findSecondary(any())).thenAnswer(
        (invocation) async => throw SecondaryNotFoundException(
            'No entry in atDirectory for ${invocation.positionalArguments[0]}'));
    // NOTE delivery waits here, so a queued notification stays queued.
    when(() => mockSecondaryAddressFinder.findSecondary(any(that: isNot(bob))))
        .thenAnswer((_) => Completer<at_lookup.SecondaryAddress>().future);
    serve(alice);
  });
  tearDown(() async => await verbTestsTearDown());

  group(
      'A connection that has not authenticated is refused an atSign longer than 55 characters',
      () {
    for (final command in [
      'from:$over',
      'to:$over',
      'lookup:phone.wavi$over'
    ]) {
      test(command.replaceAll(over, '@over'), () async {
        final connection = unauthenticated();
        await send(command, connection);
        expect(connection.writes, [tooLongUnauthenticated]);
        expect(connection.closeCount, 1);
      });
    }
  });

  group('An atServer whose atSign has 55 characters answers for it', () {
    setUp(() => serve(max));

    test('from:@max', () async {
      final connection = unauthenticated();
      await send('from:$max', connection);
      expect(connection.writes.single, startsWith('data:'));
      expect(connection.writes.single, contains('$max:'));
      expect(connection.closeCount, 0);
    });

    test('to:@max', () async {
      await keyValueStore.put(
          '${AtConstants.atEncryptionPublicKey}$max', AtData()..data = 'pk');
      await keyValueStore.put(
          '${AtConstants.atSigningPublicKey}$max', AtData()..data = 'spk');
      final connection = unauthenticated();
      await send('to:$max', connection);
      final written = connection.writes.single;
      final envelope =
          jsonDecode(written.substring('data:'.length, written.indexOf('\n')));
      expect(envelope['publickey']['data'], 'pk');
      expect(envelope['signing_publickey']['data'], 'spk');
    });
  });

  test('An atServer does not start for an atSign longer than 55 characters',
      () async {
    await expectLater(
        SecondaryServerBootStrapper(['-a', over, '-p', '6464', '-s', 'secret'])
            .run(),
        throwsA(isA<InvalidAtSignException>().having(
            (e) => e.message,
            'message',
            'invalid @sign: must have at most 55 characters after the @')));
  });

  group(
      'A client\'s command naming an atSign longer than 55 characters is refused before anything is done',
      () {
    for (final command in [
      'notify:update:messageType:key:$over:phone.wavi@alice:v',
      'notify:all:@bob,$over:phone.wavi@alice:v',
      'update:$over:phone.wavi@alice v',
      'update:$over:shared_key.bob@alice v',
      'update:phone.wavi$over v',
      'update:meta:$over:phone.wavi@alice:ttl:60000',
      'update:json:{"atKey":"phone.wavi","sharedBy":"@alice",'
          '"sharedWith":"$over","value":"v","metadata":{"isPublic":false,'
          '"isBinary":false,"isEncrypted":false}}',
      'delete:$over:phone.wavi@alice',
      'delete:phone.wavi$over',
      'lookup:phone.wavi$over',
      'lookup:all:phone.wavi$over',
      'plookup:phone.wavi$over',
      'plookup:bypassCache:true:phone.wavi$over',
      'llookup:phone.wavi$over',
      'llookup:$over:phone.wavi@alice',
      'llookup:cached:@alice:phone.wavi$over',
      'scan:$over',
      'stream:init$over namespace:wavi startByte:0 s1 f.txt 10',
    ]) {
      test(command.replaceAll(over, '@over'), () async {
        final before = await footprint();
        final connection = client();
        await send(command, connection);
        expect(connection.writes, [tooLongForAlice]);
        expect(await footprint(), before);
        expectNothingLookedUp();
        expect(connection.closeCount, 0);
      });
    }
  });

  group(
      'A client\'s command naming an atSign of exactly 55 characters is accepted',
      () {
    late Connection connection;

    setUp(() async {
      await keyValueStore.put('$max:phone.wavi@alice', AtData()..data = 'held');
      connection = client();
    });

    test('notify:update:messageType:key:@max:phone.wavi@alice:v', () async {
      await send(
          'notify:update:messageType:key:$max:phone.wavi@alice:v', connection);
      expect(await sentTo(max), [NotificationStatus.queued]);
    });

    test('notify:all:@bob,@max:phone.wavi@alice:v', () async {
      await send('notify:all:@bob,$max:phone.wavi@alice:v', connection);
      expect(await sentTo('@bob'), [NotificationStatus.queued]);
      expect(await sentTo(max), [NotificationStatus.queued]);
    });

    test('update:@max:phone.wavi@alice v', () async {
      await send('update:$max:phone.wavi@alice v', connection);
      expect((await keyValueStore.get('$max:phone.wavi@alice'))!.data, 'v');
    });

    test('update:meta:@max:phone.wavi@alice:ttl:60000', () async {
      await send('update:meta:$max:phone.wavi@alice:ttl:60000', connection);
      expect((await keyValueStore.get('$max:phone.wavi@alice'))!.metaData!.ttl,
          60000);
    });

    test('delete:@max:phone.wavi@alice', () async {
      await send('delete:$max:phone.wavi@alice', connection);
      expect(await keyValueStore.exists('$max:phone.wavi@alice'), isFalse);
    });

    test('llookup:@max:phone.wavi@alice', () async {
      await send('llookup:$max:phone.wavi@alice', connection);
      expect(connection.writes, ['data:held\n@alice@']);
    });

    for (final command in [
      'lookup:phone.wavi$max',
      'plookup:phone.wavi$max',
      'scan:$max',
    ]) {
      test(command.replaceAll(max, '@max'), () async {
        await send(command, connection);
        verify(() => atDirectory.findSecondary(max)).called(greaterThan(0));
      });
    }

    test('config:block:add:@max', () async {
      await send('config:block:add:$max', connection);
      await send('config:block:show', connection);
      expect(connection.writes.last, 'data:["$max"]\n@alice@');
    });

    test('stream:init@max namespace:wavi startByte:0 s1 f.txt 10', () async {
      await send(
          'stream:init$max namespace:wavi startByte:0 s1 f.txt 10', connection);
      expect(await sentTo(max), [NotificationStatus.queued]);
    });
  });

  group('An atSign is measured in characters after its @, without its dots',
      () {
    final dotted55 = '@${List.filled(55, 'a').join('.')}';
    final dotted56 = '@${List.filled(56, 'a').join('.')}';
    final emoji55 = '@${'\u{1F600}' * 55}';
    final emoji56 = '@${'\u{1F600}' * 56}';
    final capitals56 = '@${'A' * 56}';

    String notify(String recipient) =>
        'notify:update:messageType:key:$recipient:phone.wavi@alice:v';

    test('@ and 55 letters with a dot between each', () async {
      await send(notify(dotted55), client());
      expect(await sentTo('@${'a' * 55}'), [NotificationStatus.queued]);
    });

    test('@ and 55 emoji', () async {
      await send(notify(emoji55), client());
      expect(await sentTo(emoji55), [NotificationStatus.queued]);
    });

    for (final (description, recipient) in [
      ('@ and 56 letters with a dot between each', dotted56),
      ('@ and 56 emoji', emoji56),
      ('@ and 56 capital letters', capitals56),
    ]) {
      test(description, () async {
        final connection = client();
        await send(notify(recipient), connection);
        expect(connection.writes, [tooLongForAlice]);
      });
    }
  });

  group(
      'A peer that has proved itself by pol is refused an atSign longer than 55 characters',
      () {
    for (final command in [
      'notify:update:messageType:key:$over:phone.wavi@bob:v',
      'notify:update:messageType:key:@alice:phone.wavi$over:v',
      'lookup:phone.wavi$over',
    ]) {
      test(command.replaceAll(over, '@over'), () async {
        final before = await footprint();
        final connection = peer(bob);
        await send(command, connection);
        expect(connection.writes, [tooLongUnauthenticated]);
        expect(await footprint(), before);
        expect(connection.closeCount, 0);
      });
    }
  });

  group(
      'A pol challenge naming a verifier longer than 55 characters is not signed',
      () {
    /// Has @bob's atServer answer @alice's atServer's from: with a pol
    /// challenge naming [verifier].
    void challengeNaming(String verifier) {
      final payload = jsonEncode({'v': verifier, 'n': 'nonce'});
      final challenge = '${SecondaryUtil.polChallengeV1Prefix}'
          '${base64Url.encode(utf8.encode(payload))}';
      when(() => mockOutboundConnection.write('from:$alice\n'))
          .thenAnswer((_) async {
        socketOnDataFn(
            'data:proof:mock-session-id$bob:$challenge\n@'.codeUnits);
      });
    }

    setUp(() => outboundClientWithHandshake.productionMode = true);

    test('naming @over', () async {
      challengeNaming(over);
      await expectLater(outboundClientWithHandshake.connect(), throwsException);
      expect(await keyValueStore.exists('public:mock-session-id$bob'), isFalse);
      verifyNever(() => mockOutboundConnection.write('pol\n'));
    });

    test('naming the atSign it dialed', () async {
      challengeNaming(bob);
      expect(await outboundClientWithHandshake.connect(), isTrue);
      expect(await keyValueStore.exists('public:mock-session-id$bob'), isTrue);
      verify(() => mockOutboundConnection.write('pol\n')).called(1);
    });
  });

  test('An atSign with a reserved character is refused with AT0003', () async {
    final connection = unauthenticated();
    await send('from:@a!b', connection);
    expect(connection.writes, [
      "error:AT0003-Exception: invalid @sign: Cannot contain !*'`();:&=+\$,/?#[]{} characters\n@"
    ]);
    expect(connection.closeCount, 1);
  });
}
