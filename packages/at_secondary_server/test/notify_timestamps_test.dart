// The notify half of the at_commons 5.10.0 protocol enhancements:
// server-to-server transmission of cAt/uAt/eAt/aAt.
//
//   * the outbound notify command body emits the four timestamps between
//     ccd and isEncrypted (wire-shape pins, raw literals)
//   * a delete notification carries its deletion time as :uAt: and NOTHING
//     else — in particular no isEncrypted, whose absence deployed receivers
//     default to true for non-public keys
//   * the receiving side stores cached keys with the ORIGIN's timestamps,
//     on first cache and on refresh, and records a transmitted deletion
//     time as the cached key's DELETE commit entry opTime
//   * the lookup-driven cache (AtCacheManager) stores the origin's
//     timestamps on the cached copy
//
// Isolation: per-test, via verbTestsSetUp/verbTestsTearDown.

import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  // Millisecond-precision instants (what the store holds) and their exact
  // wire spellings (formatIso8601Micros pads to six fractional digits).
  final cAt = DateTime.utc(2020, 1, 2, 3, 4, 5, 678);
  const cAtWire = '2020-01-02T03:04:05.678000Z';
  final uAt = DateTime.utc(2021, 2, 3, 4, 5, 6, 789);
  const uAtWire = '2021-02-03T04:05:06.789000Z';
  final eAt = DateTime.utc(2030, 1, 1);
  const eAtWire = '2030-01-01T00:00:00.000000Z';
  final aAt = DateTime.utc(2022, 3, 4, 5, 6, 7, 890);
  const aAtWire = '2022-03-04T05:06:07.890000Z';

  verbTestsSetUpLogging();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  setUp(() async {
    await verbTestsSetUp();
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  group('outbound notify command body', () {
    test('update notification emits cAt/uAt/eAt/aAt between ccd and '
        'isEncrypted (wire-shape pin)', () {
      final n = (AtNotificationBuilder()
            ..id = 'ts-pin-1'
            ..fromAtSign = alice
            ..toAtSign = '@bob'
            ..notification = '@bob:phone.wavi$alice'
            ..type = NotificationType.sent
            ..opType = OperationType.update
            ..ttl = 60000
            ..atValue = 'hello'
            ..atMetaData = (AtMetaData()
              ..ttr = 10
              ..isCascade = false
              ..isEncrypted = true
              ..createdAt = cAt
              ..updatedAt = uAt
              ..expiresAt = eAt
              ..availableAt = aAt))
          .build();

      final body = notificationManager.prepareNotifyCommandBody(n);
      // Wire-shape pin: this is the contract every deployed receiver's
      // regex must accept — the fragment order is frozen by
      // VerbSyntax.metadataFragment (timestamps sit between ccd and
      // isEncrypted). Only ttln's value is clock-dependent.
      expect(
          body,
          matches(RegExp(r'^id:ts-pin-1:update:messageType:key'
              r':notifier:system:ttln:\d+'
              r':ttr:10:ccd:false'
              ':cAt:$cAtWire:uAt:$uAtWire:eAt:$eAtWire:aAt:$aAtWire'
              ':isEncrypted:true'
              ':@bob:phone.wavi$alice:hello\$')));

      // And the receiving grammar accepts it verbatim.
      final HashMap<String, String?> reParsed =
          getVerbParam(Notify().syntax(), 'notify:$body');
      expect(reParsed[AtConstants.createdAt], cAtWire);
      expect(reParsed[AtConstants.updatedAt], uAtWire);
      expect(reParsed['expiresAt'], eAtWire);
      expect(reParsed['availableAt'], aAtWire);
    });

    test('a metadata-less notification emits no timestamp fragments '
        '(unchanged wire shape)', () {
      final n = (AtNotificationBuilder()
            ..id = 'ts-pin-2'
            ..fromAtSign = alice
            ..toAtSign = '@bob'
            ..notification = '@bob:phone.wavi$alice'
            ..type = NotificationType.sent
            ..opType = OperationType.update
            ..ttl = 60000)
          .build();
      final body = notificationManager.prepareNotifyCommandBody(n);
      expect(
          body,
          matches(RegExp(r'^id:ts-pin-2:update:messageType:key'
              r':notifier:system:ttln:\d+'
              ':@bob:phone.wavi$alice\$')));
    });

    test('delete notification carries :uAt: and NOTHING else — no '
        'isEncrypted (wire-shape pin)', () {
      final n = (AtNotificationBuilder()
            ..id = 'del-pin-1'
            ..fromAtSign = alice
            ..toAtSign = '@bob'
            ..notification = '@bob:phone.wavi$alice'
            ..type = NotificationType.sent
            ..opType = OperationType.delete
            ..ttl = 60000
            ..atMetaData = (AtMetaData()..updatedAt = uAt))
          .build();

      final body = notificationManager.prepareNotifyCommandBody(n);
      expect(
          body,
          matches(RegExp(r'^id:del-pin-1:delete:messageType:key'
              r':notifier:system:ttln:\d+'
              ':uAt:$uAtWire'
              ':@bob:phone.wavi$alice\$')));
      expect(body, isNot(contains('isEncrypted')),
          reason: 'delete notifications have never carried a metadata '
              'fragment; deployed receivers default an ABSENT isEncrypted '
              'to true for non-public keys, so emitting isEncrypted:false '
              'here would silently flip that default');

      final HashMap<String, String?> reParsed =
          getVerbParam(Notify().syntax(), 'notify:$body');
      expect(reParsed[AtConstants.updatedAt], uAtWire);
    });
  });

  group('receiving side: cached keys carry the origin\'s timestamps', () {
    late NotifyVerbHandler notifyHandler;

    setUp(() {
      notifyHandler = NotifyVerbHandler(keyValueStore, notificationManager);
      inboundConnection.metadata.isPolAuthenticated = true;
      inboundConnection.metadata.fromAtSign = bob;
    });

    test('a ttr notification with cAt/uAt/eAt stores the cached key with '
        'the origin values; a refresh updates them', () async {
      await notifyHandler.process(
          'notify:id:rcv-1:update:messageType:key:ttr:100000:ccd:true'
          ':cAt:$cAtWire:uAt:$uAtWire:eAt:$eAtWire'
          ':$alice:phone.wavi$bob:hello',
          inboundConnection);

      var cached = await keyValueStore.get('cached:$alice:phone.wavi$bob');
      expect(cached!.metaData!.createdAt, cAt,
          reason: 'the cached copy must carry the ORIGIN\'s createdAt, not '
              'one stamped on this server\'s clock at cache time');
      expect(cached.metaData!.updatedAt, uAt);
      expect(cached.metaData!.expiresAt, eAt,
          reason: 'an origin absolute expiry must not be rederived');

      // A refresh notification transmits newer values; the cached copy
      // adopts them (direct keystore writes have no retain-merge, so the
      // receiver re-passes what each notification transmits).
      final uAt2 = DateTime.utc(2021, 6, 1, 12);
      const uAt2Wire = '2021-06-01T12:00:00.000000Z';
      await notifyHandler.process(
          'notify:id:rcv-2:update:messageType:key:ttr:100000:ccd:true'
          ':cAt:$cAtWire:uAt:$uAt2Wire'
          ':$alice:phone.wavi$bob:hello2',
          inboundConnection);
      cached = await keyValueStore.get('cached:$alice:phone.wavi$bob');
      expect(cached!.metaData!.updatedAt, uAt2);
      expect(cached.metaData!.createdAt, cAt);
    });

    test('a ttr notification without timestamps stamps them on this '
        'server\'s clock (unchanged behaviour)', () async {
      final before = DateTime.now().toUtcMillisecondsPrecision();
      await notifyHandler.process(
          'notify:id:rcv-3:update:messageType:key:ttr:100000'
          ':$alice:phone.wavi$bob:hello',
          inboundConnection);
      final cached = await keyValueStore.get('cached:$alice:phone.wavi$bob');
      expect(cached!.metaData!.createdAt!.isBefore(before), isFalse);
      expect(cached.metaData!.updatedAt!.isBefore(before), isFalse);
    });

    test('a delete notification\'s :uAt: becomes the cached key\'s DELETE '
        'commit entry opTime (ccd case)', () async {
      await notifyHandler.process(
          'notify:id:rcv-4:update:messageType:key:ttr:100000:ccd:true'
          ':$alice:phone.wavi$bob:hello',
          inboundConnection);
      expect(await keyValueStore.exists('cached:$alice:phone.wavi$bob'),
          isTrue);

      await notifyHandler.process(
          'notify:id:rcv-5:delete:messageType:key'
          ':uAt:$uAtWire'
          ':$alice:phone.wavi$bob',
          inboundConnection);

      expect(await keyValueStore.exists('cached:$alice:phone.wavi$bob'),
          isFalse,
          reason: 'the cached key was stored with isCascade, so the delete '
              'notification removes it');
      final entry =
          atCommitLog.getLatestCommitEntry('cached:$alice:phone.wavi$bob')!;
      expect(entry.operation, CommitOp.DELETE);
      expect(entry.opTime, uAt,
          reason: 'the DELETE entry records the origin deletion time');
    });
  });

  group('lookup-driven cache (AtCacheManager)', () {
    test('the cached copy of a remotely-looked-up key carries the origin\'s '
        'timestamps', () async {
      inboundConnection.metadata.isAuthenticated = true;
      const keyName = 'some_key.some_namespace@bob';

      final AtData bobData = createRandomAtData(bob);
      bobData.metaData!.ttr = 10;
      bobData.metaData!.ttb = null;
      bobData.metaData!.ttl = null;
      bobData.metaData!.createdAt = cAt;
      bobData.metaData!.updatedAt = uAt;
      bobData.metaData!.expiresAt = eAt;
      final String bobDataAsJsonWithKey = SecondaryUtil.prepareResponseData(
          'all', bobData,
          key: '$alice:$keyName')!;

      when(() => mockOutboundConnection.write('lookup:all:$keyName\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:$bobDataAsJsonWithKey\n$alice@".codeUnits);
      });

      final lookupHandler = LookupVerbHandler(
          keyValueStore, mockOutboundClientManager, cacheManager, enMgr,
          accessLog: atAccessLog);
      await lookupHandler.process('lookup:all:$keyName', inboundConnection);

      final cached = await keyValueStore.get('cached:$alice:$keyName');
      expect(cached!.metaData!.createdAt, cAt,
          reason: 'the cache must hold the origin\'s createdAt, not a '
              'cache-time stamp');
      expect(cached.metaData!.updatedAt, uAt);
      expect(cached.metaData!.expiresAt, eAt);
    });
  });
}
