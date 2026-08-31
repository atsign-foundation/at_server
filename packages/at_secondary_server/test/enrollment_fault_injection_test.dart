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

/// Faults the store can hand back, and what each guard owes.
///
/// Three fixes on this branch had no test, all for the same reason: each
/// guards against something only the KEYSTORE can do — throw on a key the
/// enumeration just returned, or fail outright mid-walk. A Hive-backed
/// fixture cannot produce either on demand, so the guards shipped reasoned
/// about rather than exercised. This file injects the faults.
///
/// A mocktail double is used rather than a delegating wrapper: only `get` and
/// `getKeys` are reached by the code under test, and stubbing exactly those
/// two keeps the double from silently answering a call nobody meant it to
/// take.
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
  });

  setUp(() async => await verbTestsSetUp());
  tearDown(() async => await verbTestsTearDown());

  String recordFor(String id,
      {Map<String, String> namespaces = const {'wavi': 'rw'},
      EnrollmentStatus status = EnrollmentStatus.approved,
      String? predecessor}) {
    final v = EnrollDataStoreValue('sid', 'app-$id', 'device-$id', 'pk-$id')
      ..namespaces = Map<String, String>.from(namespaces)
      ..approval = EnrollApproval(status.name)
      ..parentEnrollmentId = predecessor;
    return jsonEncode(v.toJson());
  }

  group('a keystore fault mid-walk', () {
    /// `_predecessorIdOf` catches [KeyNotFoundException] (the record is gone)
    /// and [FormatException] (it does not decode) and treats both as "no
    /// predecessor". It deliberately catches nothing else: a store that
    /// FAILS is not a store that answered "no", and swallowing the
    /// difference would make a revoke silently under-cascade — reporting
    /// success while leaving a successor of the revoked enrollment approved
    /// and usable.
    test('propagates out of descendantsOf rather than under-cascading',
        () async {
      final store = _FaultyKeyStore();
      final enMgr = EnrollmentManager(store, alice);
      final rootId = Uuid().v4();
      final childId = Uuid().v4();
      final rootKey = enMgr.buildEnrollmentKey(rootId);
      final childKey = enMgr.buildEnrollmentKey(childId);

      when(() => store.getKeys(regex: any(named: 'regex')))
          .thenAnswer((_) async => Stream.fromIterable([rootKey, childKey]));
      when(() => store.get(rootKey))
          .thenAnswer((_) async => AtData()..data = recordFor(rootId));
      when(() => store.get(childKey))
          .thenThrow(DataStoreException('hive box is closed'));

      await expectLater(() => enMgr.descendantsOf(rootId),
          throwsA(isA<DataStoreException>()),
          reason: 'a store that FAILED did not answer "no predecessor", and '
              'treating the two alike makes a revoke report success while '
              'leaving a successor approved');
    });

    test('the control: the same walk with a healthy store finds the child',
        () async {
      // Without this the assertion above is satisfied by a walk that throws
      // for some other reason, or by one that never reaches the child at all.
      final store = _FaultyKeyStore();
      final enMgr = EnrollmentManager(store, alice);
      final rootId = Uuid().v4();
      final childId = Uuid().v4();
      final rootKey = enMgr.buildEnrollmentKey(rootId);
      final childKey = enMgr.buildEnrollmentKey(childId);

      when(() => store.getKeys(regex: any(named: 'regex')))
          .thenAnswer((_) async => Stream.fromIterable([rootKey, childKey]));
      when(() => store.get(rootKey))
          .thenAnswer((_) async => AtData()..data = recordFor(rootId));
      when(() => store.get(childKey)).thenAnswer(
          (_) async => AtData()..data = recordFor(childId, predecessor: rootId));

      expect(await enMgr.descendantsOf(rootId), {childId});
    });
  });

  group('a record reaped between the enumeration and the read', () {
    /// `getKeys` and `get` are two calls with a gap between them, and an
    /// enrollment can be deleted or expire inside it. `get` THROWS rather
    /// than returning null, so without the guard one vanishing record takes
    /// the whole roster with it — `enroll:list` fails for every enrollment
    /// because one is gone.
    test('is skipped, and the rest of the roster is still served', () async {
      final store = _FaultyKeyStore();
      final enMgr = EnrollmentManager(store, alice);
      final goneId = Uuid().v4();
      final liveId = Uuid().v4();
      final goneKey = enMgr.buildEnrollmentKey(goneId);
      final liveKey = enMgr.buildEnrollmentKey(liveId);

      when(() => store.getKeys(regex: any(named: 'regex')))
          .thenAnswer((_) async => Stream.fromIterable([goneKey, liveKey]));
      when(() => store.get(goneKey))
          .thenThrow(KeyNotFoundException('$goneKey does not exist'));
      when(() => store.get(liveKey))
          .thenAnswer((_) async => AtData()..data = recordFor(liveId));

      final roster = await enMgr.getEnrollmentsAsJson();

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

      when(() => store.getKeys(regex: any(named: 'regex')))
          .thenAnswer((_) async => Stream.fromIterable([aKey, bKey]));
      when(() => store.get(aKey))
          .thenAnswer((_) async => AtData()..data = recordFor(aId));
      when(() => store.get(bKey))
          .thenAnswer((_) async => AtData()..data = recordFor(bId));

      expect((await enMgr.getEnrollmentsAsJson()).keys.toSet(), {aKey, bKey});
    });
  });

  group('the connections a revoke drops', () {
    /// The drop set is what the revoke INTENDED to revoke, not the subset
    /// this call actually flipped. The two differ exactly when a descendant
    /// is already revoked in the store — which is the state a part-way
    /// failure leaves behind, and therefore the state a retry runs against.
    /// Sending the flipped set means the retry drops nothing for precisely
    /// the enrollments whose connections are still open.
    test('is the intended cascade, not the subset this call flipped',
        () async {
      final predecessorId = Uuid().v4();
      final successorId = Uuid().v4();
      final bystanderId = Uuid().v4();

      await keyValueStore.put(
          enMgr.buildEnrollmentKey(predecessorId),
          AtData()..data = recordFor(predecessorId),
          skipCommit: true);
      // ALREADY revoked, so revokeAll skips it and the flipped set is empty
      // for exactly the enrollment whose connection is still open.
      await keyValueStore.put(
          enMgr.buildEnrollmentKey(successorId),
          AtData()
            ..data = recordFor(successorId,
                status: EnrollmentStatus.revoked, predecessor: predecessorId),
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
