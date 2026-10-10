import 'dart:async';
import 'dart:io' show HttpStatus;

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/server/http_request_handler.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'enrollment_test_utils.dart';
import 'http_request_test.dart' show FakeHttpRequest;
import 'test_utils.dart';

/// Scenarios: features/enrollment/expired_enrollment_data.feature
void main() {
  verbTestsSetUpLogging();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  final etu = ETU();
  setUp(() async {
    await verbTestsSetUp();
    await etu.init();
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  String at(String key, String location) => key.replaceFirst(
      '${EnrollmentConstants.perEnrollmentApproved}@', '$location@');

  Future<void> expectMovedTo(
      String location, List<String> keys, List<String> values) async {
    for (int i = 0; i < keys.length; i++) {
      expect(await keyValueStore.exists(keys[i]), false, reason: keys[i]);
      expect((await keyValueStore.get(at(keys[i], location)))?.data, values[i],
          reason: at(keys[i], location));
    }
  }

  /// An EnrollmentManager over a store that parks the first removal of
  /// [key] just after it is removed, until [_ParkAfterRemove.release]. Its
  /// hooks replace the shared manager's on the shared store, so the
  /// expired-keys pass removes through it too.
  (EnrollmentManager, _ParkAfterRemove) parkedAfterRemoving(String key) {
    final _ParkAfterRemove store = _ParkAfterRemove(keyValueStore, key);
    final EnrollmentManager manager = EnrollmentManager(store, alice);
    keyValueStore.preRemoveHooks
      ..clear()
      ..add(manager.preRemoveHook);
    keyValueStore.postRemoveHooks
      ..clear()
      ..add(manager.postRemoveHook);
    return (manager, store);
  }

  group('removing an enrollment', () {
    test('moves its data to d.__e and commits nothing for it', () async {
      const int ttl = 150;
      final String enId =
          (await etu.createEnrollments(n: 1, m: 1, ttl: ttl)).$1.first;
      final (keys, values) = await etu.createSomePerEnrollmentData(enId);
      await Future.delayed(const Duration(milliseconds: ttl + 1));

      await keyValueStore.deleteExpiredKeys();

      await expectMovedTo(EnrollmentConstants.perEnrollmentDeleted, keys, values);
      for (final String key in keys) {
        expect(atCommitLog.getLatestCommitEntry(key), isNull, reason: key);
        expect(
            atCommitLog.getLatestCommitEntry(
                at(key, EnrollmentConstants.perEnrollmentDeleted)),
            isNull,
            reason: 'no client of a removed enrollment syncs again');
      }
    });

    test('by a delete and by the sweep at once moves its data once', () async {
      const int ttl = 150;
      final String enId =
          (await etu.createEnrollments(n: 1, m: 1, ttl: ttl)).$1.first;
      final (keys, values) = await etu.createSomePerEnrollmentData(enId);
      await Future.delayed(const Duration(milliseconds: ttl + 1));
      final (manager, store) = parkedAfterRemoving(keys.first);

      final Future<void> delete =
          manager.serialiseMutation(() => manager.remove(enId: enId));
      await store.parked.future;
      final Future<void> sweep = keyValueStore.deleteExpiredKeys();
      await Future.delayed(const Duration(milliseconds: 100));
      store.release();
      await Future.wait([delete, sweep]);

      await expectMovedTo(EnrollmentConstants.perEnrollmentDeleted, keys, values);
      expect(await keyValueStore.exists(enMgr.buildEnrollmentKey(enId)), false);
    });
  });

  test('revoking an enrollment still commits the move to r.__e', () async {
    final String enId = (await etu.createEnrollments(n: 1)).$1.first;
    final (keys, values) = await etu.createSomePerEnrollmentData(enId);

    await etu.revokeEnrollment(etu.primaryEnId, enId);

    await expectMovedTo(EnrollmentConstants.perEnrollmentRevoked, keys, values);
    for (final String key in keys) {
      expect(atCommitLog.getLatestCommitEntry(key)?.operation, CommitOp.DELETE,
          reason: key);
      expect(
          atCommitLog.getLatestCommitEntry(
              at(key, EnrollmentConstants.perEnrollmentRevoked)),
          isNotNull,
          reason: 'an unrevoked enrollment syncs its data again');
    }
  });

  /// The first public key [createSomePerEnrollmentData] wrote, as a lookup
  /// names it: no `public:` prefix.
  String bare(String key) => key.substring(key.lastIndexOf(':') + 1);

  DummyInboundConnection cram() => DummyInboundConnection()
    ..metadata.isAuthenticated = true
    ..metadata.authType = AuthType.cram;

  Future<String?> run(String command, DummyInboundConnection c) async {
    final AbstractVerbHandler handler =
        command.startsWith('llookup:') ? etu.llvh : etu.lvh;
    final Response response = Response();
    await handler.processVerb(response, handler.parse(command), c);
    return response.data;
  }

  Future<(String, List<String>, List<String>)> expiredEnrollment() async {
    const int ttl = 150;
    final String enId =
        (await etu.createEnrollments(n: 1, m: 1, ttl: ttl)).$1.first;
    final (keys, values) = await etu.createSomePerEnrollmentData(enId);
    await Future.delayed(const Duration(milliseconds: ttl + 1));
    expect(await keyValueStore.exists(enMgr.buildEnrollmentKey(enId)), true,
        reason: 'the expired-keys pass has not run');
    return (enId, keys, values);
  }

  Future<void> expectRemovedAsBySweep(
      String enId, List<String> keys, List<String> values) async {
    await expectMovedTo(EnrollmentConstants.perEnrollmentDeleted, keys, values);
    expect(await keyValueStore.exists(enMgr.buildEnrollmentKey(enId)), false,
        reason: 'E\'s record is gone, exactly as after the sweep');
    for (final String key in [
      enMgr.buildEnrollmentKey(enId),
      ...keys,
      ...keys.map((k) => at(k, EnrollmentConstants.perEnrollmentDeleted)),
    ]) {
      expect(atCommitLog.getLatestCommitEntry(key), isNull, reason: key);
    }
  }

  group('The first lookup after an enrollment expires moves its data', () {
    test('another atSign\'s atServer sends lookup', () async {
      final (enId, keys, values) = await expiredEnrollment();

      await expectLater(run('lookup:${bare(keys.first)}', DummyInboundConnection()),
          throwsA(isA<KeyNotFoundException>()));

      await expectRemovedAsBySweep(enId, keys, values);
      expect(
          await run(
              'lookup:${bare(at(keys.first, EnrollmentConstants.perEnrollmentDeleted))}',
              DummyInboundConnection()),
          values.first,
          reason: 'a lookup of the d.__e key straight after finds it');
    });

    test('one of the owner\'s clients sends llookup', () async {
      final (enId, keys, values) = await expiredEnrollment();

      await expectLater(run('llookup:${keys.first}', cram()),
          throwsA(isA<KeyNotFoundException>()));

      await expectRemovedAsBySweep(enId, keys, values);
    });

    test('anyone sends an HTTP GET', () async {
      final (enId, keys, values) = await expiredEnrollment();
      final FakeHttpRequest request = FakeHttpRequest(
          'GET',
          Uri.parse('https://alice.atservers.swarm/'
              '${keys.first.replaceFirst('public:', '').replaceFirst(alice, '')}'));

      await AtServerHttpRequestHandler(alice, keyValueStore, enMgr)
          .handle(request);

      expect(request.response.statusCode, HttpStatus.notFound);
      await expectRemovedAsBySweep(enId, keys, values);
    });
  });

  test('A lookup of a live enrollment\'s data moves nothing', () async {
    final String enId = (await etu.createEnrollments(n: 1)).$1.first;
    final (keys, values) = await etu.createSomePerEnrollmentData(enId);

    expect(await run('lookup:${bare(keys.first)}', DummyInboundConnection()),
        values.first);

    expect(await keyValueStore.exists(enMgr.buildEnrollmentKey(enId)), true);
    for (int i = 0; i < keys.length; i++) {
      expect((await keyValueStore.get(keys[i]))?.data, values[i]);
    }
  });

  test('a lookup moves nothing for a record not yet available', () async {
    final String enId = (await etu.createEnrollments(n: 1)).$1.first;
    final String ek = enMgr.buildEnrollmentKey(enId);
    await keyValueStore.putMeta(ek, AtMetaData()..ttb = 60000);
    expect((await enMgr.getEnrollmentById(enId)).approval?.state,
        EnrollmentStatus.expired.name,
        reason: 'the read labels a record that is not yet available expired');

    await enMgr.moveExpiredEnrollmentData('x.$enId.a.__e$alice');

    expect(await keyValueStore.exists(ek), true,
        reason: 'only a record whose expiry has passed is removed, as the '
            'expired-keys pass removes it');
  });

  test('A lookup and the expiry sweep reach an expired enrollment at once',
      () async {
    final (enId, keys, values) = await expiredEnrollment();
    final (manager, store) = parkedAfterRemoving(keys.first);

    final Future<void> lookup = manager.moveExpiredEnrollmentData(keys.first);
    await store.parked.future;
    final Future<void> sweep = keyValueStore.deleteExpiredKeys();
    await Future.delayed(const Duration(milliseconds: 100));
    store.release();
    await Future.wait([lookup, sweep]);

    await expectRemovedAsBySweep(enId, keys, values);
  });

  test('Two lookups reach an expired enrollment at once', () async {
    final (enId, keys, values) = await expiredEnrollment();
    final (manager, store) = parkedAfterRemoving(keys.first);

    final Future<void> first = manager.moveExpiredEnrollmentData(keys.first);
    await store.parked.future;
    final Future<void> second = manager.moveExpiredEnrollmentData(keys.first);
    await Future.delayed(const Duration(milliseconds: 100));
    store.release();
    await Future.wait([first, second]);

    await expectRemovedAsBySweep(enId, keys, values);
    await expectLater(
        manager.refuseLapsedApprovedData(keys.first),
        throwsA(isA<KeyNotFoundException>()),
        reason: 'both lookups are told the a.__e key does not exist');
  });
}

/// Delegates to [inner], except that the first removal of [parkKey] parks
/// once it has removed the key, until [release].
class _ParkAfterRemove extends Mock
    implements AtKeyValueStore<String, AtData, AtMetaData?> {
  _ParkAfterRemove(this.inner, this.parkKey);

  final AtKeyValueStore<String, AtData, AtMetaData?> inner;
  final String parkKey;
  final Completer<void> parked = Completer<void>();
  final Completer<void> _released = Completer<void>();

  void release() {
    if (!_released.isCompleted) _released.complete();
  }

  @override
  Future<int?> remove(String key,
      {bool skipCommit = false, DateTime? deletedAt}) async {
    final int? result =
        await inner.remove(key, skipCommit: skipCommit, deletedAt: deletedAt);
    if (key == parkKey && !parked.isCompleted) {
      parked.complete();
      await _released.future;
    }
    return result;
  }

  @override
  Future<AtData?> get(String key) => inner.get(key);

  @override
  Future<AtMetaData?> getMeta(String key) => inner.getMeta(key);

  @override
  Future<int?> put(String key, AtData value,
          {bool skipCommit = false,
          AtAssertedTimestamps? assertedTimestamps}) =>
      inner.put(key, value,
          skipCommit: skipCommit, assertedTimestamps: assertedTimestamps);

  @override
  Future<bool> exists(String key) => inner.exists(key);

  @override
  Future<Stream<String>> getKeys({String? regex}) =>
      inner.getKeys(regex: regex);

  @override
  List<Future<void> Function(String key, {required bool skipCommit})>
      get preRemoveHooks => inner.preRemoveHooks;

  @override
  List<Future<void> Function(String key, {required bool skipCommit})>
      get postRemoveHooks => inner.postRemoveHooks;
}
