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
/// mid-walk. A Hive-backed fixture cannot produce either on demand, so
/// this file injects them through a mocktail double. Only `get` and the
/// two key enumerations are stubbed, so any other call the code under
/// test makes shows up rather than being answered silently.
///
/// [stubRoster] stubs BOTH enumerations together. `Mock implements`
/// erases every body, so an unstubbed enumeration is answered by
/// `noSuchMethod` with null and fails at runtime inside the code under
/// test, looking like a product bug; which one a walk takes is a
/// per-caller decision (see [EnrollmentManager.getAllEnrollmentKeys]).
class _FaultyKeyStore extends Mock
    implements AtKeyValueStore<String, AtData, AtMetaData?> {}

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

  /// Makes [store] answer BOTH key enumerations with [keys]: `getKeys` is
  /// the visible roster and `scanKeys` the stored one, and a double that
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
      String? approvedBy}) {
    final v = EnrollDataStoreValue('sid', 'app-$id', 'device-$id', 'pk-$id')
      ..namespaces = Map<String, String>.from(namespaces)
      ..approval = EnrollApproval(status.name)
      ..parentEnrollmentId = approvedBy;
    return jsonEncode(v.toJson());
  }

  group('a keystore fault mid-walk', () {
    /// `_approverIdOf` treats a missing or undecodable record as "no
    /// predecessor" and catches nothing else: a store that FAILED did not
    /// answer "no", and swallowing the difference makes a revoke report
    /// success while a successor stays approved and usable.
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
      // Without this arm the throw above is satisfied by a walk that fails
      // for some other reason, or that never reaches the child at all.
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
    /// can be deleted or expire, and `get` throws rather than returning
    /// null, so without the guard one vanished record fails the whole
    /// listing.
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

  group('the connections a revoke drops', () {
    /// The drop set is what the revoke INTENDED to revoke, not the subset
    /// this call flipped. They differ exactly when a descendant is already
    /// revoked, the state a part-way failure leaves for a retry, so using
    /// the flipped set would drop no connection for the enrollments whose
    /// connections are still open.
    test('is the intended cascade, not the subset this call flipped',
        () async {
      final predecessorId = Uuid().v4();
      final successorId = Uuid().v4();
      final bystanderId = Uuid().v4();

      await keyValueStore.put(
          enMgr.buildEnrollmentKey(predecessorId),
          AtData()..data = recordFor(predecessorId),
          skipCommit: true);
      // Already revoked, so revokeAll flips nothing for exactly the
      // enrollment whose connection is still open.
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
