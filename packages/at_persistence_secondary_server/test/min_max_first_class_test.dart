// Tests for the first-class min/max/floor persistence surface:
//   KeyValueStore.nextExpiresAt / peekExpired
//   AtKeyValueStore.nextAvailableAt / peekNewlyAvailable
//   AtCommitLog.firstCommittedSequenceNumber
// plus the commit-log cache-eviction guard (deleting an older
// duplicate entry must not evict the newer live cache entry).
//
// Isolation: per-test. Each setUp opens fresh storage under a
// uuid-suffixed dir; tearDown closes and wipes it.

import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/src/impl/hive/hive_commit_log_keystore.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

void main() {
  group('main keystore: nextExpiresAt / peekExpired', () {
    const atSign = '@minmax_ttl';
    late String storageDir;
    late HiveAtKeyValueStore keyStore;

    setUp(() async {
      storageDir = '${Directory.current.path}/test/hive/${Uuid().v4()}';
      keyStore = await setUpTestKeyStore(atSign, storageDir: storageDir);
    });
    tearDown(() async => await tearDownTestPersistence(storageDir: storageDir));

    AtData dataWith({int? ttl, int? ttb}) => AtData()
      ..data = 'value'
      ..metaData = (AtMetaData()
        ..ttl = ttl
        ..ttb = ttb);

    test('nextExpiresAt returns null when no key has a ttl', () async {
      await keyStore.put('plain.wavi$atSign', AtData()..data = 'value');
      expect(await keyStore.nextExpiresAt(), isNull);
    });

    test('nextExpiresAt returns the smallest expiresAt', () async {
      await keyStore.put('later.wavi$atSign', dataWith(ttl: 200000));
      await keyStore.put('soonest.wavi$atSign', dataWith(ttl: 100000));
      await keyStore.put('latest.wavi$atSign', dataWith(ttl: 300000));

      final soonestMeta = await keyStore.getMeta('soonest.wavi$atSign');
      expect(await keyStore.nextExpiresAt(), soonestMeta!.expiresAt);
    });

    test('nextExpiresAt moves when the soonest key is removed', () async {
      await keyStore.put('soonest.wavi$atSign', dataWith(ttl: 100000));
      await keyStore.put('later.wavi$atSign', dataWith(ttl: 200000));
      await keyStore.remove('soonest.wavi$atSign');

      final laterMeta = await keyStore.getMeta('later.wavi$atSign');
      expect(await keyStore.nextExpiresAt(), laterMeta!.expiresAt);
    });

    test('peekExpired yields ascending-expiresAt order, honours limit',
        () async {
      await keyStore.put('second.wavi$atSign', dataWith(ttl: 200000));
      await keyStore.put('first.wavi$atSign', dataWith(ttl: 100000));
      await keyStore.put('third.wavi$atSign', dataWith(ttl: 300000));

      // Nothing has actually expired yet.
      expect(await (await keyStore.peekExpired()).toList(), isEmpty);

      // As-of a day from now, everything has, in ttl order.
      final tomorrow = DateTime.timestamp().add(Duration(days: 1));
      expect(await (await keyStore.peekExpired(asOf: tomorrow)).toList(), [
        'first.wavi$atSign',
        'second.wavi$atSign',
        'third.wavi$atSign',
      ]);
      expect(
          await (await keyStore.peekExpired(asOf: tomorrow, limit: 2)).toList(),
          ['first.wavi$atSign', 'second.wavi$atSign']);
      expect(
          await (await keyStore.peekExpired(asOf: tomorrow, limit: 0)).toList(),
          isEmpty);
    });

    test('peekExpired agrees with getExpiredKeys on actually-expired keys',
        () async {
      await keyStore.put('gone.wavi$atSign', dataWith(ttl: 1));
      await keyStore.put('alive.wavi$atSign', dataWith(ttl: 600000));
      await Future.delayed(Duration(milliseconds: 5));

      final viaGet = await (await keyStore.getExpiredKeys()).toList();
      final viaPeek = await (await keyStore.peekExpired()).toList();
      expect(viaGet, ['gone.wavi$atSign']);
      expect(viaPeek, viaGet);
    });
  });

  group('main keystore: nextAvailableAt / peekNewlyAvailable', () {
    const atSign = '@minmax_ttb';
    late String storageDir;
    late HiveAtKeyValueStore keyStore;

    setUp(() async {
      storageDir = '${Directory.current.path}/test/hive/${Uuid().v4()}';
      keyStore = await setUpTestKeyStore(atSign, storageDir: storageDir);
    });
    tearDown(() async => await tearDownTestPersistence(storageDir: storageDir));

    AtData dataWith({int? ttl, int? ttb}) => AtData()
      ..data = 'value'
      ..metaData = (AtMetaData()
        ..ttl = ttl
        ..ttb = ttb);

    test('nextAvailableAt returns null when no key has a future ttb', () async {
      await keyStore.put('plain.wavi$atSign', AtData()..data = 'value');
      await keyStore.put('ttlonly.wavi$atSign', dataWith(ttl: 600000));
      expect(await keyStore.nextAvailableAt(), isNull);
    });

    test('nextAvailableAt returns smallest not-yet-born availableAt', () async {
      await keyStore.put('later.wavi$atSign', dataWith(ttb: 200000));
      await keyStore.put('soonest.wavi$atSign', dataWith(ttb: 100000));

      final soonestMeta = await keyStore.getMeta('soonest.wavi$atSign');
      expect(await keyStore.nextAvailableAt(), soonestMeta!.availableAt);
    });

    test('nextAvailableAt excludes keys already born as of asOf', () async {
      await keyStore.put('early.wavi$atSign', dataWith(ttb: 100000));
      await keyStore.put('late.wavi$atSign', dataWith(ttb: 200000));

      final earlyMeta = await keyStore.getMeta('early.wavi$atSign');
      final lateMeta = await keyStore.getMeta('late.wavi$atSign');

      // As-of exactly early's availableAt, early is born (not "next").
      expect(await keyStore.nextAvailableAt(asOf: earlyMeta!.availableAt),
          lateMeta!.availableAt);
      // As-of past both, nothing is next.
      expect(
          await keyStore.nextAvailableAt(asOf: lateMeta.availableAt), isNull);
    });

    test('peekNewlyAvailable: (since, asOf] window, ordering, limit', () async {
      await keyStore.put('b.wavi$atSign', dataWith(ttb: 200000));
      await keyStore.put('a.wavi$atSign', dataWith(ttb: 100000));
      await keyStore.put('c.wavi$atSign', dataWith(ttb: 300000));

      final aAt = (await keyStore.getMeta('a.wavi$atSign'))!.availableAt!;
      final cAt = (await keyStore.getMeta('c.wavi$atSign'))!.availableAt!;
      final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

      // Full window: ascending availableAt order.
      expect(
          await (await keyStore.peekNewlyAvailable(since: epoch, asOf: cAt))
              .toList(),
          ['a.wavi$atSign', 'b.wavi$atSign', 'c.wavi$atSign']);

      // since is exclusive: a key at exactly `since` is not yielded.
      expect(
          await (await keyStore.peekNewlyAvailable(since: aAt, asOf: cAt))
              .toList(),
          ['b.wavi$atSign', 'c.wavi$atSign']);

      // asOf is inclusive (c at exactly asOf was yielded above); limit caps.
      expect(
          await (await keyStore.peekNewlyAvailable(
                  since: epoch, asOf: cAt, limit: 1))
              .toList(),
          ['a.wavi$atSign']);
    });
  });

  group('notification keystore: nextExpiresAt / peekExpired / index', () {
    const atSign = '@minmax_notif';
    late String storageDir;
    late HiveAtNotificationKeystore notifStore;

    setUp(() async {
      storageDir = '${Directory.current.path}/test/hive/${Uuid().v4()}';
      notifStore = HiveAtNotificationKeystore(atSign);
      await notifStore.init(storageDir);
    });
    tearDown(() async {
      await notifStore.close();
      final dir = Directory(storageDir);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    AtNotification notif(String id, {int? ttlMs}) => (AtNotificationBuilder()
          ..id = id
          ..fromAtSign = atSign
          ..toAtSign = '@bob'
          ..ttl = ttlMs)
        .build();

    test('nextExpiresAt is null on an empty queue, set when populated',
        () async {
      expect(await notifStore.nextExpiresAt(), isNull);

      await notifStore.put('soon', notif('soon', ttlMs: 100000));
      await notifStore.put('late', notif('late', ttlMs: 600000));
      final soonest = (await notifStore.get('soon'))!.expiresAt;
      expect(await notifStore.nextExpiresAt(), soonest);
    });

    test('status=expired entries surface immediately (epoch sentinel)',
        () async {
      final expired = (AtNotificationBuilder()
            ..id = 'dead'
            ..fromAtSign = atSign
            ..toAtSign = '@bob'
            ..ttl = 3600000
            ..notificationStatus = NotificationStatus.expired)
          .build();
      await notifStore.put('dead', expired);
      await notifStore.put('live', notif('live', ttlMs: 3600000));

      expect((await notifStore.nextExpiresAt())!.millisecondsSinceEpoch, 0);
      expect(await (await notifStore.peekExpired()).toList(), ['dead']);
      expect(await (await notifStore.getExpiredKeys()).toList(), ['dead']);
    });

    test(
        'notificationDateTime older than maxTtl expires the entry even '
        'with a future expiresAt', () async {
      final now = DateTime.timestamp().toUtcMillisecondsPrecision();
      final stale = (AtNotificationBuilder()
            ..id = 'stale'
            ..fromAtSign = atSign
            ..toAtSign = '@bob'
            ..notificationDateTime =
                now.subtract(AtNotification.maxTtl + Duration(days: 1))
            ..expiresAt = now.add(Duration(hours: 1)))
          .build();
      await notifStore.put('stale', stale);
      expect(stale.isExpired(), isTrue);

      expect(await (await notifStore.peekExpired()).toList(), ['stale']);
      expect(await (await notifStore.getExpiredKeys()).toList(), ['stale']);
    });

    test('null notificationDateTime is treated as already expired', () async {
      final malformed = (AtNotificationBuilder()
            ..id = 'malformed'
            ..fromAtSign = atSign
            ..toAtSign = '@bob'
            ..notificationDateTime = null)
          .build();
      await notifStore.put('malformed', malformed);
      expect(malformed.isExpired(), isTrue);

      expect(await (await notifStore.peekExpired()).toList(), ['malformed']);
      expect(await (await notifStore.getExpiredKeys()).toList(), ['malformed']);
    });

    test('peekExpired orders by effective expiry and honours limit', () async {
      await notifStore.put('n2', notif('n2', ttlMs: 200000));
      await notifStore.put('n1', notif('n1', ttlMs: 100000));
      await notifStore.put('n3', notif('n3', ttlMs: 300000));

      final tomorrow = DateTime.timestamp().add(Duration(days: 1));
      expect(await (await notifStore.peekExpired(asOf: tomorrow)).toList(),
          ['n1', 'n2', 'n3']);
      expect(
          await (await notifStore.peekExpired(asOf: tomorrow, limit: 1))
              .toList(),
          ['n1']);
    });

    test('index maintained across remove / removeMany / clear', () async {
      await notifStore.put('n1', notif('n1', ttlMs: 100000));
      await notifStore.put('n2', notif('n2', ttlMs: 200000));
      await notifStore.put('n3', notif('n3', ttlMs: 300000));

      await notifStore.remove('n1');
      expect(await notifStore.nextExpiresAt(),
          (await notifStore.get('n2'))!.expiresAt);

      await notifStore.removeMany(['n2']);
      expect(await notifStore.nextExpiresAt(),
          (await notifStore.get('n3'))!.expiresAt);

      await notifStore.clear();
      expect(await notifStore.nextExpiresAt(), isNull);
    });

    test('index maintained across compact', () async {
      final expired = (AtNotificationBuilder()
            ..id = 'dead'
            ..fromAtSign = atSign
            ..toAtSign = '@bob'
            ..notificationStatus = NotificationStatus.expired)
          .build();
      await notifStore.put('dead', expired);
      await notifStore.put('live', notif('live', ttlMs: 3600000));

      final compacted = await notifStore.compact(false).toList();
      expect(compacted, ['dead']);
      expect(await (await notifStore.getExpiredKeys()).toList(), isEmpty);
      expect(await notifStore.nextExpiresAt(),
          (await notifStore.get('live'))!.expiresAt);
    });

    test('initialize repopulates the index from the box', () async {
      await notifStore.put('persisted', notif('persisted', ttlMs: 300000));

      final reopened = HiveAtNotificationKeystore(atSign);
      await reopened.init(storageDir);
      expect(await reopened.nextExpiresAt(),
          (await reopened.get('persisted'))!.expiresAt);
    });
  });

  group('commit log: firstCommittedSequenceNumber / cache eviction guard', () {
    const atSign = '@minmax_commitlog';
    late String storageDir;
    late HiveCommitLogKeyStore commitLogKeyStore;
    late HiveAtCommitLog commitLog;

    setUp(() async {
      storageDir = '${Directory.current.path}/test/hive/${Uuid().v4()}';
      commitLogKeyStore = HiveCommitLogKeyStore(atSign);
      await commitLogKeyStore.init(storageDir, isLazy: false);
      commitLog = HiveAtCommitLog(commitLogKeyStore);
    });
    tearDown(() async {
      await commitLog.close();
      final dir = Directory(storageDir);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('floor is null on an empty log', () {
      expect(commitLog.firstCommittedSequenceNumber(), isNull);
    });

    test('floor tracks the oldest retained entry through update dedup',
        () async {
      final first = await commitLog.commit('one.wavi$atSign', CommitOp.UPDATE);
      final second = await commitLog.commit('two.wavi$atSign', CommitOp.UPDATE);
      expect(commitLog.firstCommittedSequenceNumber(), first);
      expect(commitLog.lastCommittedSequenceNumber(), second);

      // Re-committing key one deletes its old entry inline (dedup
      // invariant), so the floor advances to key two's entry.
      final third = await commitLog.commit('one.wavi$atSign', CommitOp.UPDATE);
      expect(commitLog.firstCommittedSequenceNumber(), second);
      expect(commitLog.lastCommittedSequenceNumber(), third);
    });

    test(
        'compacting a legacy duplicate raises the floor and leaves the '
        'cache serving the live entry (eviction guard)', () async {
      const key = 'dup.wavi$atSign';
      // Plant a legacy duplicate the way pre-dedup data looks on disk:
      // replay() writes straight to the box without touching the cache.
      final stale = CommitEntry(key, CommitOp.UPDATE, DateTime.timestamp())
        ..commitId = 5;
      await commitLog.replay(stale);

      // A normal commit for the same key. The inline dedup can't see
      // the replayed entry (cache miss), so the box now holds both.
      final live = (await commitLog.commit(key, CommitOp.UPDATE))!;
      expect(commitLog.firstCommittedSequenceNumber(), 5);
      expect(commitLog.entriesCount(), 2);

      final compacted = await commitLog.compact(false).toList();
      expect(compacted, [5]);

      // Floor advanced past the duplicate...
      expect(commitLog.firstCommittedSequenceNumber(), live);
      // ...and the cache still serves the live entry: deleting the
      // older duplicate must not evict the newer cache entry.
      expect(commitLog.getLatestCommitEntry(key)?.commitId, live);
    });

    test('removing the live entry evicts it from the cache', () async {
      const key = 'gone.wavi$atSign';
      final id = (await commitLog.commit(key, CommitOp.UPDATE))!;
      expect(commitLog.getLatestCommitEntry(key)?.commitId, id);

      await commitLogKeyStore.remove(id);
      expect(commitLog.getLatestCommitEntry(key), isNull);
      expect(commitLog.firstCommittedSequenceNumber(), isNull);
    });
  });
}
