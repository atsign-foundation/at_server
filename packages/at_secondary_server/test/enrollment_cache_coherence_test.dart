import 'dart:async';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

/// The enrollment record [enMgr] serves is cached per enrollment key and the
/// cache outlives any single verb, so these pin what must happen to it when
/// the record underneath moves or goes: any removal of the key drops the
/// entry, and a read whose store fetch was overtaken by a write declines to
/// fill the cache at all.

/// Writes an approved enrollment holding `wavi:rw` straight to the keystore.
/// Returns its id.
Future<String> _putApprovedEnrollment() async {
  final String enrollmentId = Uuid().v4();
  await keyValueStore.put(
      enMgr.buildEnrollmentKey(enrollmentId),
      AtData()
        ..data = jsonEncode({
          'sessionId': '123',
          'appName': 'wavi',
          'deviceName': 'pixel',
          'namespaces': {'wavi': 'rw'},
          'apkamPublicKey': 'testPublicKeyValue',
          'requestType': 'newEnrollment',
          'approval': {'state': EnrollmentStatus.approved.name}
        }),
      skipCommit: true);
  return enrollmentId;
}

/// The real keystore, with one difference: a `get` of [gatedKey] reads the
/// store immediately and then parks until [releaseGate], so it hands back a
/// value read before whatever happened while it was parked. That is the shape
/// of the window in `getEnrollmentByFullKey`, which is a few microtasks wide
/// unforced and so does not reproduce by racing. Anything not overridden here
/// falls through to mocktail's `noSuchMethod` and fails loudly, so an
/// unmodelled path cannot pass through quietly.
class GatedKeyStore extends Mock
    implements AtKeyValueStore<String, AtData, AtMetaData?> {
  GatedKeyStore(this.inner);

  final AtKeyValueStore<String, AtData, AtMetaData?> inner;

  /// The one key whose `get` parks. Null gates nothing.
  String? gatedKey;

  /// Completes when the gated `get` has read the store and parked.
  final Completer<void> reachedGate = Completer<void>();

  final Completer<void> _gate = Completer<void>();

  void releaseGate() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<AtData?> get(String key) async {
    if (key != gatedKey) return inner.get(key);
    final AtData? value = await inner.get(key);
    if (!reachedGate.isCompleted) reachedGate.complete();
    await _gate.future;
    return value;
  }

  @override
  Future<int?> put(String key, AtData value,
          {bool skipCommit = false,
          AtAssertedTimestamps? assertedTimestamps}) =>
      inner.put(key, value,
          skipCommit: skipCommit, assertedTimestamps: assertedTimestamps);

  @override
  Future<int?> remove(String key,
          {bool skipCommit = false, DateTime? deletedAt}) =>
      inner.remove(key, skipCommit: skipCommit, deletedAt: deletedAt);

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

void main() {
  group('a record removed under the cache is not served from it', () {
    setUp(() async => await verbTestsSetUp());
    tearDown(() async => await verbTestsTearDown());

    test('a keystore-level removal drops the cached enrollment', () async {
      final String enrollmentId = await _putApprovedEnrollment();
      final String ek = enMgr.buildEnrollmentKey(enrollmentId);

      expect((await enMgr.getEnrollmentById(enrollmentId)).approval?.state,
          EnrollmentStatus.approved.name);
      expect(enMgr.atDataCache.containsKey(ek), isTrue,
          reason: 'precondition: the read cached it. Without this the '
              'assertion below would pass on a manager that caches nothing');

      // The path the `delete` verb and the expired-keys sweep take. Going
      // through EnrollmentManager.remove would prove nothing about the other
      // ways an enrollment key leaves the keystore.
      await keyValueStore.remove(ek, skipCommit: true);

      expect(await keyValueStore.exists(ek), isFalse,
          reason: 'control: the record really did leave the store, so a '
              'passing assertion below is not a removal that did nothing');
      expect(() async => await enMgr.getEnrollmentById(enrollmentId),
          throwsA(isA<KeyNotFoundException>()),
          reason: 'a record gone from disk must not go on being served as '
              'approved for the life of the process');
    });

    test('and the authorisation it granted stops with it', () async {
      final String enrollmentId = await _putApprovedEnrollment();
      final String ek = enMgr.buildEnrollmentKey(enrollmentId);
      final metadata = DummyInboundConnection().metadata
        ..isAuthenticated = true
        ..enrollmentId = enrollmentId;
      final handler = LocalLookupVerbHandler(keyValueStore, enMgr);

      expect(await handler.isAuthorized(metadata, atKey: 'phone.wavi$alice'),
          isTrue,
          reason: 'precondition: the grant is live while the record is');
      expect(enMgr.atDataCache.containsKey(ek), isTrue,
          reason: 'precondition: and the check cached it');

      await keyValueStore.remove(ek, skipCommit: true);

      expect(await handler.isAuthorized(metadata, atKey: 'phone.wavi$alice'),
          isFalse,
          reason: 'authorisation is decided against the cached record, so a '
              'stale entry keeps a deleted enrollment able to read');
    });

    test('remove refuses to run at all without the hook that invalidates',
        () async {
      final String enrollmentId = await _putApprovedEnrollment();
      keyValueStore.postRemoveHooks.remove(enMgr.postRemoveHook);

      expect(() async => await enMgr.remove(enId: enrollmentId),
          throwsA(isA<StateError>()),
          reason: 'the invalidation moved out of this method and into the '
              'hook, so an unregistered hook is now a silently stale cache '
              'rather than a missing tidy-up — the guard is what stops that '
              'being discoverable only in production');

      // The control: it is the missing hook that refuses, not the removal.
      keyValueStore.postRemoveHooks.add(enMgr.postRemoveHook);
      await enMgr.remove(enId: enrollmentId);
      expect(
          await keyValueStore.exists(enMgr.buildEnrollmentKey(enrollmentId)),
          isFalse);
    });

    test('CONTROL: removing one enrollment does not drop another', () async {
      final String kept = await _putApprovedEnrollment();
      final String removed = await _putApprovedEnrollment();
      await enMgr.getEnrollmentById(kept);
      await enMgr.getEnrollmentById(removed);

      final int hitsBefore = EnrollmentManager.cacheHits;
      await keyValueStore.remove(enMgr.buildEnrollmentKey(removed),
          skipCommit: true);

      expect((await enMgr.getEnrollmentById(kept)).approval?.state,
          EnrollmentStatus.approved.name);
      expect(EnrollmentManager.cacheHits, hitsBefore + 1,
          reason: 'the invalidation is keyed on the record that went; '
              'emptying the whole cache on every removal would satisfy every '
              'assertion above while throwing away the thing the cache is for');
    });
  });

  group('a read in flight across a write does not repopulate the cache', () {
    setUp(() async => await verbTestsSetUp());
    tearDown(() async => await verbTestsTearDown());

    /// Runs a read whose `keyStore.get` is parked mid-flight, lets
    /// [duringRead] happen while it is parked, then releases it, and returns
    /// the manager whose cache is the subject. The parked `get` has already
    /// read the store, so the value it hands back afterwards is the
    /// pre-[duringRead] one, which is the ordering under test rather than an
    /// artefact of the gate.
    Future<EnrollmentManager> readAcross(String enrollmentId,
        {required Future<void> Function(EnrollmentManager) duringRead}) async {
      final GatedKeyStore gated = GatedKeyStore(keyValueStore);
      final EnrollmentManager manager = EnrollmentManager(gated, alice)
        ..logger.level = 'shout';
      gated.gatedKey = manager.buildEnrollmentKey(enrollmentId);

      final Future<EnrollDataStoreValue> readInFlight =
          manager.getEnrollmentById(enrollmentId);
      await gated.reachedGate.future;
      await duringRead(manager);
      gated.releaseGate();
      await readInFlight;
      return manager;
    }

    test('a read that overlaps a revoke does not reinstate the old value',
        () async {
      final String enrollmentId = await _putApprovedEnrollment();

      final EnrollmentManager manager =
          await readAcross(enrollmentId, duringRead: (manager) async {
        final AtData stored =
            (await keyValueStore.get(manager.buildEnrollmentKey(enrollmentId)))!;
        final Map<String, dynamic> json = jsonDecode(stored.data!);
        json['approval'] = {'state': EnrollmentStatus.revoked.name};
        await manager.put(enrollmentId, AtData()..data = jsonEncode(json),
            EnrollmentStatus.revoked);
      });

      expect((await manager.getEnrollmentById(enrollmentId)).approval?.state,
          EnrollmentStatus.revoked.name,
          reason: 'the read resolved its value before the revoke and must not '
              'put it back after it — the next caller would authenticate an '
              'enrollment the store says is revoked, and nothing in the '
              'process would ever correct it');
    });

    test('CONTROL: a read that overlaps nothing still caches', () async {
      final String enrollmentId = await _putApprovedEnrollment();

      final EnrollmentManager manager =
          await readAcross(enrollmentId, duringRead: (_) async {});

      expect(
          manager.atDataCache
              .containsKey(manager.buildEnrollmentKey(enrollmentId)),
          isTrue,
          reason: 'the drop is keyed on the record having been written under '
              'the read; dropping every entry unconditionally would satisfy '
              'the assertion above while making the cache do nothing');
    });

    test('a write to ANOTHER enrollment costs this read its cache fill, and '
        'only that', () async {
      final String enrollmentId = await _putApprovedEnrollment();

      final EnrollmentManager manager =
          await readAcross(enrollmentId, duringRead: (manager) async {
        final String other = await _putApprovedEnrollment();
        await manager.put(
            other,
            (await keyValueStore.get(manager.buildEnrollmentKey(other)))!,
            EnrollmentStatus.approved);
      });
      final String ek = manager.buildEnrollmentKey(enrollmentId);

      expect(manager.atDataCache.containsKey(ek), isFalse,
          reason: 'the generation counter says that SOME enrollment changed, '
              'not which, and that coarseness is the price of holding the '
              'invariant with no new state — the alternative is a per-key '
              'generation map that grows for the life of the process');
      expect((await manager.getEnrollmentById(enrollmentId)).approval?.state,
          EnrollmentStatus.approved.name,
          reason: 'and the read that follows pays a store read and refills '
              'it: a dropped fill costs latency, never a wrong answer');
      expect(manager.atDataCache.containsKey(ek), isTrue);
    });
  });
}
