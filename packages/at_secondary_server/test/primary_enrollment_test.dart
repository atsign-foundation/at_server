import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// Pins the migration of the flat legacy credential
/// `privatekey:at_pkam_publickey`, which no enrollment record named, into the
/// `primary` enrollment: primary is minted from the flat key's value and the
/// flat key is deleted in the same act, so one credential has one record and
/// nothing holds a copy.
void main() {
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

  const String primary = EnrollmentManager.primaryEnrollmentId;

  Future<void> installFlatKey(String value) => keyValueStore
      .put(AtConstants.atPkamPublicKey, AtData()..data = value, skipCommit: true);

  Future<bool> flatKeyExists() =>
      keyValueStore.exists(AtConstants.atPkamPublicKey);

  /// A root written straight to the store, in [status], holding [key].
  Future<void> storeRoot(String id, String key,
      {EnrollmentStatus status = EnrollmentStatus.approved,
      Duration? ttl,
      String? signingAlgo}) async {
    final v = EnrollDataStoreValue('s', 'app-$id', 'device-$id', key)
      ..namespaces = {'*': 'rw', '__manage': 'rw'}
      ..approval = EnrollApproval(status.name)
      ..signingAlgo = signingAlgo;
    await enMgr.put(
        id,
        AtData()
          ..data = jsonEncode(v.toJson())
          ..metaData = (AtMetaData()..ttl = ttl?.inMilliseconds ?? 0),
        status);
  }

  /// A scoped enrollment written straight to the store, holding [key].
  Future<void> storeScoped(String id, String key) async {
    final v = EnrollDataStoreValue('s', 'app-$id', 'device-$id', key)
      ..namespaces = {'wavi': 'rw'}
      ..approval = EnrollApproval(EnrollmentStatus.approved.name);
    await enMgr.put(id, AtData()..data = jsonEncode(v.toJson()),
        EnrollmentStatus.approved);
  }

  group('the shape of primary', () {
    test('mintPrimary writes the record a legacy owner is', () async {
      await enMgr.serialiseMutation(
          () => enMgr.mintPrimary('THE_FLAT_KEY', signingAlgo: 'rsa2048'));

      final EnrollDataStoreValue v = await enMgr.getEnrollmentById(primary);
      expect(v.apkamPublicKey, 'THE_FLAT_KEY');
      expect(v.signingAlgo, 'rsa2048');
      expect(v.approval?.state, EnrollmentStatus.approved.name);
      expect(v.namespaces, {'*': 'rw', '__manage': 'rw'},
          reason: 'a legacy owner holds the atSign itself');
      expect(v.appName, 'legacy');
      expect(v.deviceName, 'legacy');
      expect(v.parentEnrollmentId, isNull,
          reason: 'nothing approved it: it IS the owner');
      expect(v.retrofitPredecessorEnrollmentId, isNull);
      expect(v.encryptedAPKAMSymmetricKey, isNull);
      expect(v.isRootEnrollment, isTrue);
      expect(
          (await keyValueStore.get(enMgr.buildEnrollmentKey(primary)))
              ?.metaData
              ?.expiresAt,
          isNull,
          reason: 'no expiry: the owner\'s own credential is not on a clock');
    });

    test('the at-rest key is the literal primary, folded like any id',
        () async {
      // ⚠️ At-rest pin: a client sending `pkam:enrollmentId:primary:` and one
      // sending no id must land on this one record, so the id is folded like
      // any other. Changing the literal orphans every stored primary.
      await enMgr.serialiseMutation(() => enMgr.mintPrimary('k'));
      expect(await keyValueStore.exists('primary.new.enrollments.__manage$alice'),
          isTrue);
    });
  });

  group('absorbing the flat key on the wire', () {
    test('mints primary from the flat key and deletes the flat key', () async {
      await installFlatKey('THE_FLAT_KEY');

      expect(await enMgr.absorbFlatKeyIntoPrimary(signingAlgo: 'mldsa65'),
          isTrue);

      expect(await flatKeyExists(), isFalse,
          reason: 'one credential and one record from this moment on');
      final EnrollDataStoreValue v = await enMgr.getEnrollmentById(primary);
      expect(v.apkamPublicKey, 'THE_FLAT_KEY');
      expect(v.signingAlgo, 'mldsa65',
          reason: 'recorded as what the wire proved the key to be');
    });

    test('rotates an existing primary onto the flat key', () async {
      await enMgr.serialiseMutation(() => enMgr.mintPrimary('OLD_KEY'));
      await installFlatKey('NEW_FLAT_KEY');

      expect(await enMgr.absorbFlatKeyIntoPrimary(), isTrue);

      expect(await flatKeyExists(), isFalse);
      expect((await enMgr.getEnrollmentById(primary)).apkamPublicKey,
          'NEW_FLAT_KEY');
    });

    test('a flat key primary already holds is simply deleted', () async {
      // The residue of a crash between the mint and the delete.
      await enMgr.serialiseMutation(() => enMgr.mintPrimary('SAME_KEY'));
      await installFlatKey('SAME_KEY');
      final int writes = EnrollmentManager.cacheInvalidations;

      expect(await enMgr.absorbFlatKeyIntoPrimary(), isTrue);

      expect(await flatKeyExists(), isFalse);
      expect(EnrollmentManager.cacheInvalidations, writes,
          reason: 'nothing to rotate, so primary is not written');
    });

    test('rotating leaves a revoked primary revoked', () async {
      // The status is not the absorb's to change: the status check that
      // follows refuses the login, as it would one naming a revoked id.
      await storeRoot(primary, 'OLD_KEY', status: EnrollmentStatus.revoked);
      await installFlatKey('NEW_FLAT_KEY');

      await enMgr.absorbFlatKeyIntoPrimary();

      final EnrollDataStoreValue v = await enMgr.getEnrollmentById(primary);
      expect(v.apkamPublicKey, 'NEW_FLAT_KEY');
      expect(v.approval?.state, EnrollmentStatus.revoked.name);
    });

    test('with no flat key there is nothing to absorb', () async {
      expect(await enMgr.absorbFlatKeyIntoPrimary(), isFalse);
      expect(await enMgr.primaryEnrollment(), isNull);
    });

    test('is exempt from key uniqueness: another holder does not block it',
        () async {
      // The migration mints from a key the connection just proved, whatever
      // else holds it; the duplicate is on the roster and revocable by name.
      await storeScoped('holder', 'SHARED_KEY');
      await installFlatKey('SHARED_KEY');

      expect(await enMgr.absorbFlatKeyIntoPrimary(), isTrue);

      expect((await enMgr.getEnrollmentById(primary)).apkamPublicKey,
          'SHARED_KEY');
      expect(await flatKeyExists(), isFalse);
    });
  });

  group('the flat key at startup', () {
    test('a copy of an approved root\'s key is deleted, and primary is not '
        'minted', () async {
      // The shape a CRAM auto-approve leaves: a copy beside the first root.
      await storeRoot('first-root', 'ROOT_KEY');
      await installFlatKey('ROOT_KEY');

      expect(await enMgr.migrateFlatKeyAtStartup(),
          StartupFlatKeyOutcome.deletedAsCopyOfRoot);

      expect(await flatKeyExists(), isFalse);
      expect(await enMgr.primaryEnrollment(), isNull,
          reason: 'the root is what a client should authenticate as');
    });

    test('a copy of a revoked root\'s key is deleted when another root '
        'survives', () async {
      // The dual-identity case: the app's revocation never reached its copy.
      await storeRoot('revoked-root', 'ROOT_KEY',
          status: EnrollmentStatus.revoked);
      await storeRoot('other-root', 'OTHER_KEY');
      await installFlatKey('ROOT_KEY');

      expect(await enMgr.migrateFlatKeyAtStartup(),
          StartupFlatKeyOutcome.deletedAsCopyOfRoot);

      expect(await flatKeyExists(), isFalse);
      expect(await enMgr.primaryEnrollment(), isNull);
    });

    test('a copy of a revoked root\'s key is REINSTATED as primary when '
        'nothing else survives', () async {
      // Reachable only where the root's own keypair revoked itself. Deleting
      // the key would strand the atSign, while minting primary from it hands
      // nobody anything they did not already hold.
      await storeRoot('revoked-root', 'ROOT_KEY',
          status: EnrollmentStatus.revoked);
      await installFlatKey('ROOT_KEY');

      expect(await enMgr.migrateFlatKeyAtStartup(),
          StartupFlatKeyOutcome.migratedIntoPrimary);

      expect(await flatKeyExists(), isFalse);
      expect((await enMgr.getEnrollmentById(primary)).apkamPublicKey,
          'ROOT_KEY');
      expect(await enMgr.hasUnexpiringRootEnrollment({}), isTrue,
          reason: 'the atSign is left with a root it can restore itself from');
    });

    test('a zero-length flat value is not a credential: nothing is minted '
        'from it, and it is cleared', () async {
      // The shape a store written by an older server can hold.
      await installFlatKey('');

      expect(await enMgr.migrateFlatKeyAtStartup(),
          StartupFlatKeyOutcome.none);

      expect(await enMgr.primaryEnrollment(), isNull,
          reason: 'a primary holding an empty key would be a phantom root');
      expect(await flatKeyExists(), isFalse,
          reason: 'and nothing exists at the key on a running server');
    });

    test('a scoped enrollment is not a survivor, so a revoked root\'s copy '
        'is reinstated', () async {
      // The stranding question is not "are there any enrollments" but "is
      // there one that could approve a replacement root", which a
      // wavi-scoped enrollment cannot.
      await storeRoot('revoked-root', 'ROOT_KEY',
          status: EnrollmentStatus.revoked);
      await storeScoped('an-app', 'APP_KEY');
      await installFlatKey('ROOT_KEY');

      expect(await enMgr.migrateFlatKeyAtStartup(),
          StartupFlatKeyOutcome.migratedIntoPrimary);
    });

    test('a root with an EMPTY public key is not a survivor either', () async {
      // A phantom root: approved and fully privileged, but holding a
      // credential no signature can be checked against, so counting it
      // answers the stranding question with an identity nobody holds.
      await storeRoot('revoked-root', 'ROOT_KEY',
          status: EnrollmentStatus.revoked);
      await storeRoot('phantom-root', '');
      await installFlatKey('ROOT_KEY');

      expect(await enMgr.migrateFlatKeyAtStartup(),
          StartupFlatKeyOutcome.migratedIntoPrimary);
    });

    test('the flat key is not counted as its own survivor', () async {
      // The stranding question is asked of the roster alone, or it would be
      // vacuous: a store holding only the flat key has no root to fall back
      // on, so the key migrates rather than being deleted.
      await installFlatKey('LEGACY_KEY');
      expect(await enMgr.hasUnexpiringRootEnrollment({}), isFalse,
          reason: 'the flat key is not a record, and is not counted');

      expect(await enMgr.migrateFlatKeyAtStartup(),
          StartupFlatKeyOutcome.migratedIntoPrimary);
      expect(await enMgr.hasUnexpiringRootEnrollment({}), isTrue,
          reason: 'and primary is');
    });

    test('a copy of an expiring root\'s key is not licensed by that root',
        () async {
      // A survivor has to be permanent: a root with a finite life defers the
      // stranding rather than answering it.
      await storeRoot('expiring-root', 'ROOT_KEY', ttl: Duration(hours: 1));
      await installFlatKey('ROOT_KEY');

      expect(await enMgr.migrateFlatKeyAtStartup(),
          StartupFlatKeyOutcome.migratedIntoPrimary);

      expect((await enMgr.getEnrollmentById(primary)).apkamPublicKey,
          'ROOT_KEY');
    });

    test('a scoped holder of the key is not a root, so the key migrates and '
        'the holder is only logged', () async {
      await storeScoped('scoped-holder', 'SHARED_KEY');
      await installFlatKey('SHARED_KEY');

      expect(await enMgr.migrateFlatKeyAtStartup(),
          StartupFlatKeyOutcome.migratedIntoPrimary);

      expect((await enMgr.getEnrollmentById(primary)).apkamPublicKey,
          'SHARED_KEY');
      expect(await flatKeyExists(), isFalse);
    });

    test('a pending root-granted request holding the key does not count',
        () async {
      // An OTP request carries a client-chosen key and can name root grants
      // while unapproved, so a subordinate could otherwise force the delete.
      final v = EnrollDataStoreValue('s', 'app', 'device', 'CHOSEN_KEY')
        ..namespaces = {'*': 'rw', '__manage': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.pending.name);
      await enMgr.put('pending-root', AtData()..data = jsonEncode(v.toJson()),
          EnrollmentStatus.pending);
      await storeRoot('other-root', 'OTHER_KEY');
      await installFlatKey('CHOSEN_KEY');

      expect(await enMgr.migrateFlatKeyAtStartup(),
          StartupFlatKeyOutcome.migratedIntoPrimary,
          reason: 'a subordinate must not be able to trigger the deletion');
    });

    test('with no root holding it, the flat key migrates into primary',
        () async {
      await installFlatKey('LEGACY_KEY');

      expect(await enMgr.migrateFlatKeyAtStartup(),
          StartupFlatKeyOutcome.migratedIntoPrimary);

      expect(await flatKeyExists(), isFalse);
      final EnrollDataStoreValue v = await enMgr.getEnrollmentById(primary);
      expect(v.apkamPublicKey, 'LEGACY_KEY');
      expect(v.signingAlgo, isNull,
          reason: 'a key found in the store made no claim about its '
              'algorithm; the wire\'s claim decides a login, as it always did');
    });

    test('the residue of a crash between mint and delete is deleted', () async {
      await enMgr.serialiseMutation(() => enMgr.mintPrimary('LEGACY_KEY'));
      await installFlatKey('LEGACY_KEY');

      expect(await enMgr.migrateFlatKeyAtStartup(),
          StartupFlatKeyOutcome.deletedAsResidue);

      expect(await flatKeyExists(), isFalse);
      expect((await enMgr.getEnrollmentById(primary)).apkamPublicKey,
          'LEGACY_KEY');
    });

    test('a stray flat key beside a primary holding a different key is '
        'deleted, and primary is untouched', () async {
      // A key lying in the store at startup is not an owner's act on the
      // wire, so it is never absorbed into a primary that holds another.
      await enMgr.serialiseMutation(() => enMgr.mintPrimary('PRIMARY_KEY'));
      await installFlatKey('STRAY_KEY');

      expect(await enMgr.migrateFlatKeyAtStartup(),
          StartupFlatKeyOutcome.deletedAsStray);

      expect(await flatKeyExists(), isFalse);
      expect((await enMgr.getEnrollmentById(primary)).apkamPublicKey,
          'PRIMARY_KEY');
    });

    test('a root holding the key under another spelling is still its holder',
        () async {
      // Keys are compared as material, so a re-cased ECC key is the same key.
      await storeRoot('ecc-root', 'deadbeef', signingAlgo: 'ecc_secp256r1');
      await installFlatKey('DEADBEEF');

      expect(await enMgr.migrateFlatKeyAtStartup(),
          StartupFlatKeyOutcome.deletedAsCopyOfRoot);
    });

    test('nothing stored, nothing done', () async {
      expect(await enMgr.migrateFlatKeyAtStartup(), StartupFlatKeyOutcome.none);
      expect(await enMgr.primaryEnrollment(), isNull);
    });
  });

  group('the CRAM key install', () {
    test('mints primary from the value, and writes no flat key', () async {
      await enMgr.installLegacyKeyIntoPrimary('INSTALLED_KEY');

      expect(await flatKeyExists(), isFalse);
      final EnrollDataStoreValue v = await enMgr.getEnrollmentById(primary);
      expect(v.apkamPublicKey, 'INSTALLED_KEY');
      expect(v.isRootEnrollment, isTrue);
    });

    test('rotates an existing primary onto the value', () async {
      await enMgr.serialiseMutation(() => enMgr.mintPrimary('FIRST'));

      await enMgr.installLegacyKeyIntoPrimary('SECOND');

      expect((await enMgr.getEnrollmentById(primary)).apkamPublicKey, 'SECOND');
      expect(await flatKeyExists(), isFalse);
    });

    test('is subject to key uniqueness: a key another enrollment holds is '
        'refused, with nothing written', () async {
      await storeScoped('holder', 'HELD_KEY');

      await expectLater(
          () => enMgr.installLegacyKeyIntoPrimary('HELD_KEY'),
          throwsA(isA<IllegalStateException>().having((e) => e.message,
              'message', contains('already held by another enrollment'))),
          reason: 'no exemption for a fixture: the fixtures mint a key '
              'per enrollment');
      expect(await enMgr.primaryEnrollment(), isNull);
    });

    test('re-installing the key primary already holds writes nothing',
        () async {
      await enMgr.serialiseMutation(() => enMgr.mintPrimary('SAME'));
      final int writes = EnrollmentManager.cacheInvalidations;

      await enMgr.installLegacyKeyIntoPrimary('SAME');

      expect(EnrollmentManager.cacheInvalidations, writes);
    });
  });

  group('the startup path runs the migration', () {
    test('prepareStoreForFirstConnection migrates the flat key', () async {
      await installFlatKey('LEGACY_KEY');
      await storeScoped('an-app', 'APP_KEY');

      await AtSecondaryServerImpl.getInstance().prepareStoreForFirstConnection();

      expect(await flatKeyExists(), isFalse,
          reason: 'no flat key exists on a running server');
      expect((await enMgr.getEnrollmentById(primary)).apkamPublicKey,
          'LEGACY_KEY');
    });

    test('and deletes a copy of a root\'s key rather than minting from it',
        () async {
      await storeRoot('first-root', 'ROOT_KEY');
      await installFlatKey('ROOT_KEY');

      await AtSecondaryServerImpl.getInstance().prepareStoreForFirstConnection();

      expect(await flatKeyExists(), isFalse);
      expect(await enMgr.primaryEnrollment(), isNull);
    });
  });
}
