import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/impl/sqlite/sqlite_at_commit_log.dart';
import 'package:at_persistence_secondary_server/src/impl/sqlite/sqlite_at_keyvalue_store.dart';
import 'package:at_persistence_secondary_server/src/impl/sqlite/sqlite_database.dart';
import 'package:test/test.dart';

void main() {
  const atSign = '@alice';
  final root = '${Directory.current.path}/test/sqlite/ks_tmp';
  late SqliteDatabase db;
  late SqliteAtCommitLog commitLog;
  late SqliteAtKeyValueStore ks;

  setUp(() {
    db = SqliteDatabase.open(atSign, '$root/$atSign/atsign.db');
    commitLog = SqliteAtCommitLog(db);
    ks = SqliteAtKeyValueStore(db, atSign)..commitLog = commitLog;
  });

  tearDown(() {
    db.close();
    final dir = Directory(root);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  AtData data(String v, [AtMetaData? m]) => AtData()
    ..data = v
    ..metaData = m;

  group('CRUD', () {
    test('create / get / exists', () async {
      final id = await ks.create('phone.wavi@alice', data('123'));
      expect(id, isNotNull);
      expect((await ks.get('phone.wavi@alice'))!.data, '123');
      expect(await ks.exists('phone.wavi@alice'), true);
      expect(await ks.exists('nope.wavi@alice'), false);
    });

    test('get on absent key throws KeyNotFoundException', () async {
      expect(() => ks.get('nope.wavi@alice'),
          throwsA(isA<KeyNotFoundException>()));
    });

    test('put creates then updates; builder bumps version + updatedAt',
        () async {
      await ks.put('loc.wavi@alice', data('india'));
      final v0 = await ks.get('loc.wavi@alice');
      expect(v0!.data, 'india');
      expect(v0.metaData!.version, 0);
      expect(v0.metaData!.createdBy, atSign);

      await ks.put('loc.wavi@alice', data('usa'));
      final v1 = await ks.get('loc.wavi@alice');
      expect(v1!.data, 'usa');
      expect(v1.metaData!.version, 1);
    });

    test('putMeta keeps value, bumps meta', () async {
      await ks.create('k.wavi@alice', data('val'));
      await ks.putMeta('k.wavi@alice', AtMetaData()..ttl = 60000);
      final got = await ks.get('k.wavi@alice');
      expect(got!.data, 'val');
      expect(got.metaData!.ttl, 60000);
    });

    test('getMany returns only present keys', () async {
      await ks.create('a.wavi@alice', data('1'));
      await ks.create('b.wavi@alice', data('2'));
      final many = await ks
          .getMany(['a.wavi@alice', 'b.wavi@alice', 'missing.wavi@alice']);
      expect(many.keys.toSet(), {'a.wavi@alice', 'b.wavi@alice'});
    });

    test('remove then removeMany', () async {
      await ks.create('a.wavi@alice', data('1'));
      await ks.create('b.wavi@alice', data('2'));
      await ks.create('c.wavi@alice', data('3'));
      await ks.remove('a.wavi@alice');
      expect(await ks.exists('a.wavi@alice'), false);
      final n =
          await ks.removeMany(['b.wavi@alice', 'c.wavi@alice', 'x@alice']);
      expect(n, 2);
    });
  });

  group('commit log semantics', () {
    test('commit ids are monotonic and dense', () async {
      await ks.create('a.wavi@alice', data('1'));
      await ks.create('b.wavi@alice', data('2'));
      expect(commitLog.firstCommittedSequenceNumber(), 1);
      expect(commitLog.lastCommittedSequenceNumber(), 2);
    });

    test('one entry per atKey, newest-wins', () async {
      await ks.put('a.wavi@alice', data('1'));
      await ks.put('a.wavi@alice', data('2'));
      expect(commitLog.entriesCount(), 1);
      expect(commitLog.getLatestCommitEntry('a.wavi@alice')!.operation,
          CommitOp.UPDATE_ALL);
    });

    test('delete records a - operation', () async {
      await ks.create('a.wavi@alice', data('1'));
      await ks.remove('a.wavi@alice');
      final e = commitLog.getLatestCommitEntry('a.wavi@alice');
      expect(e!.operation, CommitOp.DELETE);
    });

    test('elided keys (private/privatekey/public:_/local) get no commit id',
        () async {
      expect(
          await commitLog.commit('private:testkey@alice', CommitOp.UPDATE), -1);
      expect(
          await commitLog.commit('privatekey:testkey@alice', CommitOp.UPDATE),
          -1);
      expect(await commitLog.commit('public:_loc@alice', CommitOp.UPDATE), -1);
      expect(await commitLog.commit('local:foo@alice', CommitOp.UPDATE), -1);
      // public:__ (double underscore) IS synced.
      expect(await commitLog.commit('public:__loc@alice', CommitOp.UPDATE),
          isNot(-1));
    });

    test('skipCommit purges the stale commit entry', () async {
      await ks.create('a.wavi@alice', data('1'));
      expect(commitLog.getLatestCommitEntry('a.wavi@alice'), isNotNull);
      await ks.remove('a.wavi@alice', skipCommit: true);
      expect(commitLog.getLatestCommitEntry('a.wavi@alice'), isNull);
    });
  });

  group('restore is verbatim', () {
    test('preserves version/createdAt, no commit appended', () async {
      final meta = AtMetaData()
        ..createdBy = '@other'
        ..createdAt = DateTime.utc(2020, 1, 1, 0, 0, 0, 5)
        ..updatedAt = DateTime.utc(2020, 1, 2, 0, 0, 0, 7)
        ..version = 42
        ..ttr = -1;
      await ks.restore('cached:public:publickey@bob', data('KEY', meta));
      final got = await ks.get('cached:public:publickey@bob');
      expect(got!.data, 'KEY');
      expect(got.metaData!.version, 42);
      expect(got.metaData!.createdBy, '@other');
      expect(got.metaData!.createdAt, DateTime.utc(2020, 1, 1, 0, 0, 0, 5));
      expect(commitLog.lastCommittedSequenceNumber(), isNull);
    });
  });

  group('TTL / TTB', () {
    test('expiry: getExpiredKeys / nextExpiresAt / deleteExpiredKeys',
        () async {
      // ttl already elapsed → expires_at in the past.
      final past = AtMetaData()
        ..ttl = 1
        ..expiresAt = DateTime.now().toUtc().subtract(Duration(minutes: 1));
      await ks.restore('exp.wavi@alice', data('x', past));
      await ks.create('live.wavi@alice', data('y'));

      final expired = await (await ks.getExpiredKeys()).toList();
      expect(expired, contains('exp.wavi@alice'));
      expect(await ks.deleteExpiredKeys(), true);
      expect(await ks.exists('exp.wavi@alice'), false);
      expect(await ks.exists('live.wavi@alice'), true);
    });

    test('not-yet-born keys are hidden from getKeys, surfaced by peek',
        () async {
      final future = DateTime.now().toUtc().add(Duration(hours: 1));
      final meta = AtMetaData()
        ..ttb = 3600000
        ..availableAt = future;
      await ks.restore('born.wavi@alice', data('z', meta));

      final keys = await (await ks.getKeys()).toList();
      expect(keys, isNot(contains('born.wavi@alice')));
      final na = await ks.nextAvailableAt();
      expect(na, isNotNull);
    });
  });

  group('scanKeys / queryByPath', () {
    test('scanKeys filters by KeyPattern', () async {
      await ks.create('phone.wavi@alice', data('1'));
      await ks.create('email.buzz@alice', data('2'));
      final wavi =
          await (await ks.scanKeys(KeyPattern(namespace: 'wavi'))).toList();
      expect(wavi, ['phone.wavi@alice']);
    });

    test('queryByPath matches a JSON value field', () async {
      await ks.create('a.wavi@alice', data('{"city":"paris"}'));
      await ks.create('b.wavi@alice', data('{"city":"london"}'));
      final hits = await ks
          .queryByPath(
            keyPattern: KeyPattern(),
            predicate: PathEquals(['city'], 'paris'),
          )
          .toList();
      expect(hits.map((e) => e.key), ['a.wavi@alice']);
    });
  });

  group('snapshot isolation', () {
    test('best-effort: writes after snapshot ARE visible through the handle', () async {
      await ks.create('a.wavi@alice', data('before'));
      final snap = await ks.snapshot();
      await ks.put('a.wavi@alice', data('after'));
      expect((await snap.get('a.wavi@alice'))!.data, 'after');
      await snap.release();
      expect((await ks.get('a.wavi@alice'))!.data, 'after');
    });
  });

  group('transaction', () {
    test('all-or-nothing: a throw rolls back every buffered write', () async {
      await expectLater(ks.transaction((txn) async {
        await txn.put('a.wavi@alice', data('1'), null);
        await txn.put('b.wavi@alice', data('2'), null);
        throw StateError('boom');
      }), throwsA(isA<StateError>()));
      expect(await ks.exists('a.wavi@alice'), false);
      expect(await ks.exists('b.wavi@alice'), false);
    });

    test('commits buffered writes on success', () async {
      await ks.transaction((txn) async {
        await txn.put('a.wavi@alice', data('1'), null);
        expect((await txn.get('a.wavi@alice'))!.data, '1'); // reads own write
      });
      expect((await ks.get('a.wavi@alice'))!.data, '1');
    });
  });

  test('changes stream emits add/update/remove', () async {
    final events = <String>[];
    final sub = ks.changes.listen((c) => events.add(c.runtimeType.toString()));
    await ks.create('a.wavi@alice', data('1'));
    await ks.put('a.wavi@alice', data('2'));
    await ks.remove('a.wavi@alice');
    await Future.delayed(Duration(milliseconds: 10));
    await sub.cancel();
    expect(events, ['KeyAdded', 'KeyUpdated', 'KeyRemoved']);
  });
}
