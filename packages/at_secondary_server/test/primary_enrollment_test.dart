import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// Pins the migration of the flat legacy credential
/// `privatekey:at_pkam_publickey` into the `primary` enrollment: primary is
/// minted from the flat key's value and the flat key is deleted in the same
/// act.
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
      // ⚠️ AT-REST PIN: frozen; changing the literal orphans every stored
      // primary.
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
      await enMgr.serialiseMutation(() => enMgr.mintPrimary('SAME_KEY'));
      await installFlatKey('SAME_KEY');
      final int writes = EnrollmentManager.cacheInvalidations;

      expect(await enMgr.absorbFlatKeyIntoPrimary(), isTrue);

      expect(await flatKeyExists(), isFalse);
      expect(EnrollmentManager.cacheInvalidations, writes,
          reason: 'nothing to rotate, so primary is not written');
    });

    test('rotating leaves a revoked primary revoked', () async {
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
      await storeRoot('revoked-root', 'ROOT_KEY',
          status: EnrollmentStatus.revoked);
      await storeScoped('an-app', 'APP_KEY');
      await installFlatKey('ROOT_KEY');

      expect(await enMgr.migrateFlatKeyAtStartup(),
          StartupFlatKeyOutcome.migratedIntoPrimary);
    });

    test('a root with an EMPTY public key is not a survivor either', () async {
      await storeRoot('revoked-root', 'ROOT_KEY',
          status: EnrollmentStatus.revoked);
      await storeRoot('phantom-root', '');
      await installFlatKey('ROOT_KEY');

      expect(await enMgr.migrateFlatKeyAtStartup(),
          StartupFlatKeyOutcome.migratedIntoPrimary);
    });

    test('the flat key is not counted as its own survivor', () async {
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
      await enMgr.serialiseMutation(() => enMgr.mintPrimary('PRIMARY_KEY'));
      await installFlatKey('STRAY_KEY');

      expect(await enMgr.migrateFlatKeyAtStartup(),
          StartupFlatKeyOutcome.deletedAsStray);

      expect(await flatKeyExists(), isFalse);
      expect((await enMgr.getEnrollmentById(primary)).apkamPublicKey,
          'PRIMARY_KEY');
    });

    test('a stray flat key that a revoked root also holds is deleted without '
        'the log claiming a reinstatement', () async {
      // primary expires, so it is not the unexpiring root that would make
      // the flat key a deletable copy.
      await storeRoot(primary, 'PRIMARY_KEY', ttl: Duration(days: 1));
      await storeRoot('revoked-root', 'STRAY_KEY',
          status: EnrollmentStatus.revoked);
      await installFlatKey('STRAY_KEY');

      final List<String> shouts = [];
      final sub = enMgr.logger.logger.onRecord
          .listen((record) => shouts.add('${record.message}'));

      expect(await enMgr.migrateFlatKeyAtStartup(),
          StartupFlatKeyOutcome.deletedAsStray);
      await sub.cancel();

      expect((await enMgr.getEnrollmentById(primary)).apkamPublicKey,
          'PRIMARY_KEY',
          reason: 'primary stands, so nothing was reinstated as it');
      expect(shouts.where((m) => m.contains('is reinstated as')), isEmpty,
          reason: 'the flat key was deleted and primary left alone; a log '
              'saying the revoked root was reinstated names an act that did '
              'not happen');
    });

    test('a root holding the key under another spelling is still its holder',
        () async {
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
      await enMgr.installLegacyKeyIntoPrimary('INSTALLEDKEY');

      expect(await flatKeyExists(), isFalse);
      final EnrollDataStoreValue v = await enMgr.getEnrollmentById(primary);
      expect(v.apkamPublicKey, 'INSTALLEDKEY');
      expect(v.isRootEnrollment, isTrue);
    });

    test('rotates an existing primary onto the value', () async {
      await enMgr.serialiseMutation(() => enMgr.mintPrimary('FIRST'));

      await enMgr.installLegacyKeyIntoPrimary('SECONDKEYAAA');

      expect((await enMgr.getEnrollmentById(primary)).apkamPublicKey,
          'SECONDKEYAAA');
      expect(await flatKeyExists(), isFalse);
    });

    test('a CRAM install re-approves a revoked primary', () async {
      await storeRoot(primary, 'FIRSTKEYAAAA',
          status: EnrollmentStatus.revoked);

      await enMgr.installLegacyKeyIntoPrimary('SECONDKEYAAA');

      final EnrollDataStoreValue v = await enMgr.getEnrollmentById(primary);
      expect(v.apkamPublicKey, 'SECONDKEYAAA');
      expect(v.approval?.state, EnrollmentStatus.approved.name,
          reason: 'the caller holds the atSign\'s creation secret, so the '
              'install reinstates primary as well as rotating its key');
    });

    test('a CRAM install re-approves a revoked primary that already holds '
        'the key', () async {
      await storeRoot(primary, 'KEYAAAAA', status: EnrollmentStatus.revoked);

      await enMgr.installLegacyKeyIntoPrimary('KEYAAAAA');

      final EnrollDataStoreValue v = await enMgr.getEnrollmentById(primary);
      expect(v.approval?.state, EnrollmentStatus.approved.name,
          reason: 'the caller holds the atSign\'s creation secret, so the '
              'install reinstates primary even though there is no key to '
              'rotate onto');
      expect(v.apkamPublicKey, 'KEYAAAAA',
          reason: 'primary already holds the installed key');
      expect(await enMgr.getAllEnrollmentKeys(includeExpired: true),
          hasLength(1),
          reason: 'the install reinstates primary rather than minting a '
              'second enrollment');
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

    test('an ECC public key, which is hex rather than base64, is accepted',
        () async {
      final String eccHex = '04' + 'ab' * 64;
      await enMgr.installLegacyKeyIntoPrimary(eccHex);
      expect((await enMgr.getEnrollmentById(primary)).apkamPublicKey, eccHex,
          reason: 'an ecc_secp256r1 key is spelled in hex, and the install '
              'carries no algorithm, so both spellings must be accepted');
    });

    test('a value that is not key material is refused, with nothing written',
        () async {
      await expectLater(
          () => enMgr.installLegacyKeyIntoPrimary('not base64 at all!'),
          throwsA(isA<IllegalArgumentException>().having((e) => e.message,
              'message', contains('not an APKAM public key'))),
          reason: 'junk minted as primary is an approved, unexpiring root '
              'that the last-root guard counts, so the last real root could '
              'then be revoked');
      expect(await enMgr.primaryEnrollment(), isNull,
          reason: 'the refusal is total: no record is written');
      expect(await flatKeyExists(), isFalse);
    });

    test('a value of nothing but a space is refused too', () async {
      await expectLater(
          () => enMgr.installLegacyKeyIntoPrimary(' '),
          throwsA(isA<IllegalArgumentException>()),
          reason: 'an empty credential is one nobody can authenticate with');
      expect(await enMgr.primaryEnrollment(), isNull);
    });

    test('an ECC key another enrollment holds is refused however it is '
        'cased', () async {
      await storeRoot('ecc-root', 'deadbeef', signingAlgo: 'ecc_secp256r1');

      await expectLater(
          () => enMgr.installLegacyKeyIntoPrimary('DEADBEEF'),
          throwsA(isA<IllegalStateException>().having((e) => e.message,
              'message', contains('already held by another enrollment'))),
          reason: 'hex is case-insensitive, so this is the key that root '
              'holds; installing it would put one keypair under two names');
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
