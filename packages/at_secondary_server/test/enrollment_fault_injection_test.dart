import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

/// Pins what the enrollment guards owe when the KEYSTORE misbehaves: a
/// throw on a key the enumeration just returned, or an outright failure
/// mid-walk, injected through a mocktail double.
class _FaultyKeyStore extends Mock
    implements AtKeyValueStore<String, AtData, AtMetaData?> {}

/// A keystore that reaps nominated keys under a real one, standing in for
/// the expiry sweep landing between a read and the read that follows it.
///
/// Enumerations serve the reaped keys first, so a walk reaches them before
/// it reaches anything else.
class _ReapingKeyStore extends Mock
    implements AtKeyValueStore<String, AtData, AtMetaData?> {
  _ReapingKeyStore(this._delegate);

  final AtKeyValueStore<String, AtData, AtMetaData?> _delegate;

  /// Keys removed as the enumeration that names them returns.
  final Set<String> reapOnEnumeration = {};

  /// Keys removed the moment they have been read once.
  final Set<String> reapOnFirstGet = {};

  Future<List<String>> _reapEnumerated(List<String> keys) async {
    final List<String> due =
        keys.where(reapOnEnumeration.contains).toList();
    for (final String key in due) {
      reapOnEnumeration.remove(key);
      await _delegate.remove(key, skipCommit: true);
    }
    final Set<String> first = {...due, ...reapOnFirstGet};
    return [
      ...keys.where(first.contains),
      ...keys.where((k) => !first.contains(k)),
    ];
  }

  @override
  Future<AtData?> get(String key) async {
    final AtData? value = await _delegate.get(key);
    if (reapOnFirstGet.remove(key)) {
      await _delegate.remove(key, skipCommit: true);
    }
    return value;
  }

  @override
  Future<Stream<String>> getKeys({String? regex}) async => Stream.fromIterable(
      await _reapEnumerated(
          await (await _delegate.getKeys(regex: regex)).toList()));

  @override
  Future<Stream<String>> scanKeys(KeyPattern pattern,
          {bool includeExpired = false,
          OrderByKey? orderBy,
          int? limit,
          int? skip}) async =>
      Stream.fromIterable(await _reapEnumerated(await (await _delegate
              .scanKeys(pattern,
                  includeExpired: includeExpired,
                  orderBy: orderBy,
                  limit: limit,
                  skip: skip))
          .toList()));

  @override
  Future<int?> put(String key, AtData value,
          {bool skipCommit = false,
          AtAssertedTimestamps? assertedTimestamps}) =>
      _delegate.put(key, value,
          skipCommit: skipCommit, assertedTimestamps: assertedTimestamps);

  @override
  Future<int?> remove(String key,
          {bool skipCommit = false, DateTime? deletedAt}) =>
      _delegate.remove(key, skipCommit: skipCommit, deletedAt: deletedAt);

  @override
  Future<bool> exists(String key) => _delegate.exists(key);
}

class _MockInboundConnection extends Mock implements InboundConnection {}

class _StubPool extends Mock implements InboundConnectionPool {
  _StubPool(this._connections);
  final List<InboundConnection> _connections;

  @override
  UnmodifiableListView<InboundConnection> getConnections() =>
      UnmodifiableListView<InboundConnection>(_connections);
}

void main() {
  setUpAll(() async {
    registerFallbackValue(AtData());
    registerFallbackValue(const KeyPattern());
  });

  /// Makes [store] answer BOTH key enumerations with [keys]: a double that
  /// answers only one returns null through `noSuchMethod` for the other.
  void stubRoster(_FaultyKeyStore store, List<String> keys) {
    when(() => store.getKeys(regex: any(named: 'regex')))
        .thenAnswer((_) async => Stream.fromIterable(keys));
    when(() => store.scanKeys(any(),
            includeExpired: any(named: 'includeExpired')))
        .thenAnswer((_) async => Stream.fromIterable(keys));
  }

  setUp(() async => await verbTestsSetUp());
  tearDown(() async => await verbTestsTearDown());

  String recordFor(String id,
      {Map<String, String> namespaces = const {'wavi': 'rw'},
      EnrollmentStatus status = EnrollmentStatus.approved,
      String? approvedBy,
      String? replacing}) {
    final v = EnrollDataStoreValue('sid', 'app-$id', 'device-$id', 'pk-$id')
      ..namespaces = Map<String, String>.from(namespaces)
      ..approval = EnrollApproval(status.name)
      ..parentEnrollmentId = approvedBy
      ..retrofitPredecessorEnrollmentId = replacing;
    return jsonEncode(v.toJson());
  }

  /// Writes [id]'s record straight to the real store, unexpiring.
  Future<void> persist(String id, String record) => keyValueStore
      .put(enMgr.buildEnrollmentKey(id), AtData()..data = record,
          skipCommit: true);

  group('a keystore fault mid-walk', () {
    /// `_approverIdOf` treats a missing or undecodable record as "no
    /// predecessor" and catches nothing else.
    test('propagates out of descendantsOf rather than under-cascading',
        () async {
      final store = _FaultyKeyStore();
      final enMgr = EnrollmentManager(store, alice);
      final rootId = Uuid().v4();
      final childId = Uuid().v4();
      final rootKey = enMgr.buildEnrollmentKey(rootId);
      final childKey = enMgr.buildEnrollmentKey(childId);

      stubRoster(store, [rootKey, childKey]);
      when(() => store.get(rootKey))
          .thenAnswer((_) async => AtData()..data = recordFor(rootId));
      when(() => store.get(childKey))
          .thenThrow(DataStoreException('hive box is closed'));

      await expectLater(() => enMgr.descendantsOf(rootId),
          throwsA(isA<DataStoreException>()),
          reason: 'a store that FAILED did not answer "no approver", and '
              'treating the two alike makes a revoke report success while '
              'leaving a successor approved');
    });

    test('the control: the same walk with a healthy store finds the child',
        () async {
      // The control: the walk reaches the child and fails for no other reason.
      final store = _FaultyKeyStore();
      final enMgr = EnrollmentManager(store, alice);
      final rootId = Uuid().v4();
      final childId = Uuid().v4();
      final rootKey = enMgr.buildEnrollmentKey(rootId);
      final childKey = enMgr.buildEnrollmentKey(childId);

      stubRoster(store, [rootKey, childKey]);
      when(() => store.get(rootKey))
          .thenAnswer((_) async => AtData()..data = recordFor(rootId));
      when(() => store.get(childKey)).thenAnswer(
          (_) async => AtData()..data = recordFor(childId, approvedBy: rootId));

      expect(await enMgr.descendantsOf(rootId), {childId});
    });
  });

  group('a record reaped between the enumeration and the read', () {
    /// `getKeys` and `get` are two calls with a gap in which an enrollment
    /// can be deleted or expire.
    test('is skipped, and the rest of the roster is still served', () async {
      final store = _FaultyKeyStore();
      final enMgr = EnrollmentManager(store, alice);
      final goneId = Uuid().v4();
      final liveId = Uuid().v4();
      final goneKey = enMgr.buildEnrollmentKey(goneId);
      final liveKey = enMgr.buildEnrollmentKey(liveId);

      stubRoster(store, [goneKey, liveKey]);
      when(() => store.get(goneKey))
          .thenThrow(KeyNotFoundException('$goneKey does not exist'));
      when(() => store.get(liveKey))
          .thenAnswer((_) async => AtData()..data = recordFor(liveId));

      final roster = await enMgr.getEnrollmentsAsJson(redactSecrets: false);

      expect(roster.keys, [liveKey],
          reason: 'the survivor is served; the reaped one is skipped rather '
              'than failing the whole listing');
    });

    test('the control: both records present, both served', () async {
      final store = _FaultyKeyStore();
      final enMgr = EnrollmentManager(store, alice);
      final aId = Uuid().v4();
      final bId = Uuid().v4();
      final aKey = enMgr.buildEnrollmentKey(aId);
      final bKey = enMgr.buildEnrollmentKey(bId);

      stubRoster(store, [aKey, bKey]);
      when(() => store.get(aKey))
          .thenAnswer((_) async => AtData()..data = recordFor(aId));
      when(() => store.get(bKey))
          .thenAnswer((_) async => AtData()..data = recordFor(bId));

      expect((await enMgr.getEnrollmentsAsJson(redactSecrets: false)).keys.toSet(), {aKey, bKey});
    });
  });

  group('a record reaped between one read and the next', () {
    /// The expiry sweep does not take the enrollment-mutation section, so it
    /// can land between two reads of the same key.
    const Map<String, String> root = {'*': 'rw', '__manage': 'rw'};

    test('is left out of the listing, and the rest is still served',
        () async {
      final store = _ReapingKeyStore(keyValueStore);
      final mgr = EnrollmentManager(store, alice);
      final goneId = Uuid().v4();
      final liveId = Uuid().v4();
      await persist(goneId, recordFor(goneId));
      await persist(liveId, recordFor(liveId));
      store.reapOnFirstGet.add(mgr.buildEnrollmentKey(goneId));

      final roster = await mgr.getEnrollmentsAsJson(redactSecrets: false);

      expect(roster.keys, [mgr.buildEnrollmentKey(liveId)],
          reason: 'the expiry read comes after the record read, so a reap '
              'between them must skip that entry rather than fail the whole '
              'listing');
    });

    test('does not stop the walk for an unexpiring root', () async {
      final store = _ReapingKeyStore(keyValueStore);
      final mgr = EnrollmentManager(store, alice);
      final goneId = Uuid().v4();
      final liveId = Uuid().v4();
      await persist(goneId, recordFor(goneId, namespaces: root));
      await persist(liveId, recordFor(liveId, namespaces: root));
      store.reapOnFirstGet.add(mgr.buildEnrollmentKey(goneId));

      expect(await mgr.hasUnexpiringRootEnrollment({}), isTrue,
          reason: 'the reaped root is skipped and the live one is still '
              'counted; a throw here refuses every revoke while an '
              'unexpiring root stands');
    });

    test('does not stop the adoption pass part way through', () async {
      final store = _ReapingKeyStore(keyValueStore);
      final mgr = EnrollmentManager(store, alice);
      final predecessorId = Uuid().v4();
      final successorId = Uuid().v4();
      final goneChildId = Uuid().v4();
      final liveChildId = Uuid().v4();
      await persist(predecessorId, recordFor(predecessorId, namespaces: root));
      await persist(
          successorId,
          recordFor(successorId,
              namespaces: root, replacing: predecessorId));
      await persist(goneChildId,
          recordFor(goneChildId, approvedBy: predecessorId));
      await persist(liveChildId,
          recordFor(liveChildId, approvedBy: predecessorId));
      store.reapOnEnumeration.add(mgr.buildEnrollmentKey(goneChildId));

      await mgr.armRetrofitCapOnFirstAuth(successorId);

      expect((await mgr.getEnrollmentById(liveChildId)).parentEnrollmentId,
          successorId,
          reason: 'the pass runs once and never runs again, so a reaped '
              'child must not carry off the children behind it');
    });
  });

  group('the connections a revoke drops', () {
    /// The drop set is what the revoke INTENDED to revoke, not the subset
    /// this call flipped.
    test('is the intended cascade, not the subset this call flipped',
        () async {
      final predecessorId = Uuid().v4();
      final successorId = Uuid().v4();
      final bystanderId = Uuid().v4();

      await keyValueStore.put(
          enMgr.buildEnrollmentKey(predecessorId),
          AtData()..data = recordFor(predecessorId),
          skipCommit: true);
      await keyValueStore.put(
          enMgr.buildEnrollmentKey(successorId),
          AtData()
            ..data = recordFor(successorId,
                status: EnrollmentStatus.revoked, approvedBy: predecessorId),
          skipCommit: true);

      final revoked = _MockInboundConnection();
      final bystander = _MockInboundConnection();
      for (final (conn, id) in [(revoked, successorId), (bystander, bystanderId)]) {
        final md = InboundConnectionMetadata()..enrollmentId = id;
        when(() => conn.metaData).thenReturn(md);
        when(() => conn.isInValid()).thenReturn(false);
        when(() => conn.close()).thenAnswer((_) async {});
      }
      atServer.inboundConnectionManager.pool =
          _StubPool([revoked, bystander]);

      final callerId = await createAndPersistAnEnrollment(
          'root', 'device', {'*': 'rw', '__manage': 'rw'});
      inboundConnection.metaData
        ..isAuthenticated = true
        ..authType = AuthType.apkam;
      inboundConnection.metadata.enrollmentId = callerId;

      final Response response = Response();
      final h = EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await h.processVerb(
          response,
          h.parse('enroll:revoke:{"enrollmentId":"$predecessorId"}'),
          inboundConnection);

      final decoded = jsonDecode(response.data!) as Map;
      expect(decoded['status'], 'revoked', reason: 'the revoke landed');
      expect(decoded.containsKey('cascadedEnrollmentIds'), isFalse,
          reason: 'precondition: this call FLIPPED nothing — the successor '
              'was already revoked. If the drop set were the flipped set it '
              'would be empty here');

      verify(() => revoked.close()).called(1);
      verifyNever(() => bystander.close());
    });
  });
}
