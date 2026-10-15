import 'dart:async';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_refresh_job.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/gate/gatekeeper.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/config_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_fetch_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// The scenarios of refusals.feature that one atServer proves, each under
/// its title.
void main() {
  final Atsign chuck = '@chuck'.toAtsign();

  Gatekeeper gate() => AtSecondaryServerImpl.getInstance().gatekeeper;

  DummyInboundConnection fromAtServerOf(String other) =>
      DummyInboundConnection()
        ..metadata.isPolAuthenticated = true
        ..metadata.fromAtSign = other.toAtsign();

  DummyInboundConnection ownClient() => DummyInboundConnection()
    ..metadata.isAuthenticated = true
    ..metadata.authType = AuthType.cram;

  Future<Exception> refusal(Future<void> Function() exchange) async {
    try {
      await exchange();
    } on Exception catch (e) {
      return e;
    }
    fail('the exchange was not refused');
  }

  Future<String?> code(Future<void> Function() exchange) async =>
      GlobalExceptionHandler.getInstance()
          .getErrorCode(await refusal(exchange));

  Future<void> notifyFrom(String other, String command) =>
      NotifyVerbHandler(keyValueStore, notificationManager)
          .processInternal(command, fromAtServerOf(other));

  /// A cached copy of [key], refreshed every second.
  Future<void> cached(String key, {String value = 'v'}) => keyValueStore.put(
      key,
      AtData()
        ..data = value
        ..metaData = (AtMetaData()..ttr = 1));

  /// Waits until a copy written by [cached] is due for refresh.
  Future<void> dueForRefresh() =>
      Future.delayed(const Duration(milliseconds: 1100));

  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await verbTestsSetUp();
    await gate().setDefault(GateDefault.closed);
  });

  tearDown(() async => await verbTestsTearDown());

  group('A denied atSign and a closed namespace look the same to the sender',
      () {
    for (final String namespace in ['chat', 'photos']) {
      test(namespace, () async {
        await gate().setRule('chat', GateMode.closed);
        await gate().setRule('photos', GateMode.open);
        await gate().deny('photos', chuck);
        final Exception chat = await refusal(() =>
            notifyFrom('$chuck', 'notify:id:c1:@alice:msg.chat@chuck'));
        final Exception photos = await refusal(() =>
            notifyFrom('$chuck', 'notify:id:p1:@alice:pic.photos@chuck'));
        final Exception e = namespace == 'chat' ? chat : photos;
        expect(
            GlobalExceptionHandler.getInstance().getErrorCode(e), 'AT0033');
        expect('$chat', '$photos');
      });
    }
  });

  test('Keys shared with an atSign that loses admission stay', () async {
    await gate().setRule('chat', GateMode.closed, admit: bob.toAtsign());
    await keyValueStore.put('@bob:status.chat$alice', AtData()..data = 'v');
    await gate().remove('chat', bob.toAtsign());
    expect(await keyValueStore.exists('@bob:status.chat$alice'), isTrue);
    expect(
        await code(() => LookupVerbHandler(keyValueStore,
                mockOutboundClientManager, cacheManager, enMgr,
                accessLog: atAccessLog)
            .processInternal(
                'lookup:status.chat@alice', fromAtServerOf(bob))),
        'AT0033');
  });

  test('Stored notifications stay', () async {
    await gate().setRule('chat', GateMode.closed, admit: bob.toAtsign());
    await notifyFrom(bob, 'notify:id:7:@alice:msg.chat@bob');
    await gate().remove('chat', bob.toAtsign());
    final Map<String, dynamic> fetched = jsonDecode(
        (await NotifyFetchVerbHandler(keyValueStore, notificationManager)
                .processInternal('notify:fetch:7', ownClient()))
            .data!);
    expect(fetched['id'], '7');
  });

  test('Cached copies go when an atSign is removed from a closed namespace',
      () async {
    await gate().setRule('chat', GateMode.closed, admit: bob.toAtsign());
    await cached('cached:$alice:msg.chat$bob');
    await gate().remove('chat', bob.toAtsign());
    expect(
        await keyValueStore.exists('cached:$alice:msg.chat$bob'), isFalse);
  });

  test('Cached copies go when an atSign is denied in an open namespace',
      () async {
    await gate().setRule('photos', GateMode.open, admit: bob.toAtsign());
    await cached('cached:$alice:pic.photos$bob');
    await gate().deny('photos', bob.toAtsign());
    expect(await keyValueStore.exists('cached:$alice:pic.photos$bob'),
        isFalse);
  });

  test(
      'Cached copies go when an open namespace is closed to an atSign'
      ' admitted only atSign-wide', () async {
    await gate().setRule('photos', GateMode.open);
    await gate().admit(Gatekeeper.everyNamespace, bob.toAtsign());
    await cached('cached:$alice:pic.photos$bob');
    await gate().setRule('photos', GateMode.closed);
    expect(await keyValueStore.exists('cached:$alice:pic.photos$bob'),
        isFalse);
  });

  test(
      'Switching the default to closed removes cached copies in namespaces'
      ' without a rule', () async {
    await gate().setDefault(GateDefault.ungated);
    await cached('cached:$alice:pic.photos$chuck');
    await gate().setDefault(GateDefault.closed);
    expect(await keyValueStore.exists('cached:$alice:pic.photos$chuck'),
        isFalse);
  });

  test(
      'Switching the default to closed keeps cached copies from atSigns'
      ' recorded in a namespace without a rule', () async {
    await gate().setDefault(GateDefault.ungated);
    await gate().admit('photos', bob.toAtsign());
    await cached('cached:$alice:pic.photos$bob');
    await cached('cached:$alice:pic.photos$chuck');
    await gate().setDefault(GateDefault.closed);
    expect(
        await keyValueStore.exists('cached:$alice:pic.photos$bob'), isTrue);
    expect(await keyValueStore.exists('cached:$alice:pic.photos$chuck'),
        isFalse);
  });

  test(
      'Switching the default to closed keeps cached copies from the'
      ' atSign-wide admitted set', () async {
    await gate().setDefault(GateDefault.ungated);
    await gate().admit(Gatekeeper.everyNamespace, bob.toAtsign());
    await cached('cached:$alice:pic.photos$bob');
    await cached('cached:$alice:pic.photos$chuck');
    await gate().setDefault(GateDefault.closed);
    expect(
        await keyValueStore.exists('cached:$alice:pic.photos$bob'), isTrue);
    expect(await keyValueStore.exists('cached:$alice:pic.photos$chuck'),
        isFalse);
  });

  test('Blocklisting an atSign removes cached copies of its keys', () async {
    await gate().setRule('chat', GateMode.closed, admit: bob.toAtsign());
    await cached('cached:$alice:msg.chat$bob');
    await ConfigVerbHandler(keyValueStore, commitLog: atCommitLog)
        .processInternal('config:block:add:@bob', ownClient());
    expect(
        await keyValueStore.exists('cached:$alice:msg.chat$bob'), isFalse);
  });

  MockOutboundClient bobsAtServer() {
    final MockOutboundClient client = MockOutboundClient();
    when(() => mockOutboundClientManager.getClient(bob, any(),
            handshakeRequired: any(named: 'handshakeRequired')))
        .thenAnswer((_) async => client);
    return client;
  }

  test('A refused cache refresh removes the cached copy', () async {
    await gate().setDefault(GateDefault.ungated);
    await cached('cached:$alice:status.chat$bob');
    final MockOutboundClient client = bobsAtServer();
    when(() => client.lookUp(any(), handshake: any(named: 'handshake')))
        .thenThrow(NotAcceptedException('not accepted'));
    await dueForRefresh();
    final Map result =
        await AtCacheRefreshJob(alice, cacheManager).refreshNow();
    expect(result['refusedDeleted'], 1);
    expect(await keyValueStore.exists('cached:$alice:status.chat$bob'),
        isFalse);
  });

  test(
      'A cache refresh that completes after admission was lost leaves no'
      ' cached copy', () async {
    await gate().setRule('chat', GateMode.closed, admit: bob.toAtsign());
    await cached('cached:$alice:msg.chat$bob', value: 'old');
    final Completer<String> answer = Completer();
    final Completer<void> asked = Completer();
    final MockOutboundClient client = bobsAtServer();
    when(() => client.lookUp(any(), handshake: any(named: 'handshake')))
        .thenAnswer((_) {
      asked.complete();
      return answer.future;
    });
    await dueForRefresh();
    final Future<Map> refresh =
        AtCacheRefreshJob(alice, cacheManager).refreshNow();
    await asked.future;
    await gate().remove('chat', bob.toAtsign());
    final DateTime now = DateTime.now().toUtc();
    answer.complete('data:${jsonEncode((AtData()
          ..data = 'new'
          ..metaData = (AtMetaData()
            ..ttr = 1000
            ..createdAt = now
            ..updatedAt = now))
        .toJson())}');
    final Map result = await refresh;
    expect(
        await keyValueStore.exists('cached:$alice:msg.chat$bob'), isFalse);
    expect(result['gateChanged'], 1);
  });

  test(
      'A refused notification resent after its sender is admitted is'
      ' accepted', () async {
    await gate().setRule('chat', GateMode.closed);
    expect(
        await code(() =>
            notifyFrom('$chuck', 'notify:id:30:@alice:msg.chat@chuck')),
        'AT0033');
    await gate().admit('chat', chuck);
    await notifyFrom('$chuck', 'notify:id:30:@alice:msg.chat@chuck');
    expect(await notificationManager.isKeyExists('30'), isTrue);
  });

  test('Each retry of a refused notification is refused, and stores nothing',
      () async {
    await gate().setRule('chat', GateMode.closed);
    for (int i = 0; i < 3; i++) {
      expect(
          await code(() =>
              notifyFrom('$chuck', 'notify:id:31:@alice:msg.chat@chuck')),
          'AT0033');
    }
    expect(await notificationManager.isKeyExists('31'), isFalse);
  });

  test('A gate refusal leaves the connection open', () async {
    await gate().setRule('chat', GateMode.closed);
    final _ClosingConnection connection = _ClosingConnection();
    connection.metadata
      ..isPolAuthenticated = true
      ..fromAtSign = chuck;
    final Exception refused = await refusal(() =>
        NotifyVerbHandler(keyValueStore, notificationManager)
            .processInternal(
                'notify:id:13:@alice:msg.chat@chuck', connection));
    await GlobalExceptionHandler.getInstance()
        .handle(refused, atConnection: connection);
    expect(connection.lastWrittenData, startsWith('error:AT0033-'));
    expect(connection.closed, isFalse);
  });

}

/// A connection that records whether it was closed.
class _ClosingConnection extends DummyInboundConnection {
  bool closed = false;

  @override
  Future<void> close() async => closed = true;
}
