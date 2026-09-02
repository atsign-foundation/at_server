import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/verb/handler/config_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_utils/at_logger.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

/// Covers authorization of namespace-less keys — keys carrying no namespace
/// an enrollment can be granted, so the namespace check cannot decide them.
void main() {
  AtSignLogger.root_level = 'WARNING';

  group('root key authorization', () {
    late UpdateVerbHandler updateVerbHandler;
    late LocalLookupVerbHandler localLookupVerbHandler;
    late DeleteVerbHandler deleteVerbHandler;
    late ConfigVerbHandler configVerbHandler;

    setUpAll(() async {
      await verbTestsSetUpAll();
    });

    setUp(() async {
      await verbTestsSetUp();
      updateVerbHandler = UpdateVerbHandler(
          keyValueStore, statsNotificationService, notificationManager, alice);
      localLookupVerbHandler = LocalLookupVerbHandler(keyValueStore, enMgr);
      deleteVerbHandler = DeleteVerbHandler(
          keyValueStore, statsNotificationService, notificationManager);
      configVerbHandler =
          ConfigVerbHandler(keyValueStore, commitLog: atCommitLog);
    });

    tearDown(() async {
      await verbTestsTearDown();
    });

    /// Binds an approved enrollment with [namespaces] and returns its id.
    ///
    /// [id] names the enrollment explicitly. Only one key is decided by WHICH
    /// enrollment is asking rather than by what it holds, and pinning that
    /// needs a connection carrying the housekeeping id.
    Future<String> bindEnrollment(Map<String, String> namespaces,
        {String? id}) async {
      inboundConnection.metadata.isAuthenticated = true;
      final enrollId = id ?? Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': namespaces,
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      await keyValueStore.put('$enrollId.new.enrollments.__manage$alice',
          AtData()..data = jsonEncode(enrollJson));
      return enrollId;
    }

    Future<String> bindScoped() => bindEnrollment({'wavi': 'rw'});
    Future<String> bindWildcard() => bindEnrollment({'*': 'rw'});
    Future<String> bindRoot({String? id}) =>
        bindEnrollment({'*': 'rw', '__manage': 'rw'}, id: id);

    /// The connection a LEGACY PKAM authentication leaves behind: the
    /// housekeeping enrollment's id, fully privileged and approved.
    Future<String> bindLegacy() =>
        bindRoot(id: EnrollmentManager.housekeepingEnrollmentId);

    // ---- the legacy PKAM public key ----

    test('scoped enrollment cannot overwrite the legacy PKAM public key',
        () async {
      await bindScoped();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');

      await expectLater(
          updateVerbHandler.process(
              'update:${AtConstants.atPkamPublicKey} REPLACEMENT_KEY',
              inboundConnection),
          throwsA(isA<UnAuthorizedException>()));
      // Assert the stored value, not merely that the call threw.
      final stored = await keyValueStore.get(AtConstants.atPkamPublicKey);
      expect(stored?.data, 'ORIGINAL_KEY');
    });

    test('a *:rw enrollment without __manage cannot overwrite the PKAM key',
        () async {
      await bindWildcard();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');

      await expectLater(
          updateVerbHandler.process(
              'update:${AtConstants.atPkamPublicKey} REPLACEMENT_KEY',
              inboundConnection),
          throwsA(isA<UnAuthorizedException>()));
      final stored = await keyValueStore.get(AtConstants.atPkamPublicKey);
      expect(stored?.data, 'ORIGINAL_KEY');
    });

    test('a root enrollment CANNOT write the PKAM public key', () async {
      // BEHAVIOUR CHANGED — a root enrollment used to be allowed this, on the
      // same footing as every other key in the root-only set.
      //
      // It is the one key an enrollment can write that MINTS AN IDENTITY
      // rather than serving one. `at_pkam_publickey` is what LEGACY PKAM
      // authenticates against, and legacy PKAM carries no enrollment id — so
      // an app root that plants a key it holds gains a second identity that
      // its own revocation cannot reach. A compromised app root would survive
      // being revoked, permanently, with nothing on the roster to show it.
      await bindRoot();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');

      await expectLater(
          updateVerbHandler.process(
              'update:${AtConstants.atPkamPublicKey} REPLACEMENT_KEY',
              inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason: 'root privilege is not enough for THIS key: an APKAM root '
              'that plants a key it holds gains a legacy identity, and legacy '
              'PKAM carries no enrollment id — so revoking that root leaves '
              'the planted key authenticating');
      final stored = await keyValueStore.get(AtConstants.atPkamPublicKey);
      expect(stored?.data, 'ORIGINAL_KEY',
          reason: 'and the refusal happened before the write');
    });

    test('the legacy enrollment gets PAST the authorization gate', () async {
      // The carve-out, and the control for the refusal above: without it that
      // refusal would be satisfied by nobody being able to write this key at
      // all, which would leave the legacy credential unrotatable.
      //
      // A legacy connection carries the housekeeping id, and it got there by
      // authenticating with the key it is replacing — so it has already
      // proved possession of the OLD credential. That is a credential
      // rotating ITSELF, which is what every other enrollment does through
      // enroll:update; the housekeeping record cannot use that verb because
      // it holds no key to update.
      //
      // It is stopped here by a DIFFERENT rule, and the exception type is the
      // discriminator: possession of the NEW key is demanded separately, and
      // this plain-form request carries no proof. An UnAuthorizedException
      // would mean the carve-out had stopped admitting a legacy connection at
      // all. The rotation itself, signature and all, is pinned end to end in
      // legacy_pkam_retrofit_test.dart, which has real keypairs to hand.
      await bindLegacy();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');

      await expectLater(
          updateVerbHandler.process(
              'update:${AtConstants.atPkamPublicKey} NEW_KEY',
              inboundConnection),
          throwsA(isA<IllegalArgumentException>().having((e) => e.message,
              'message', contains('requires proof'))),
          reason: 'past authorization, stopped by proof of possession — an '
              'UnAuthorizedException here would mean the carve-out itself had '
              'stopped working');

      final stored = await keyValueStore.get(AtConstants.atPkamPublicKey);
      expect(stored?.data, 'ORIGINAL_KEY',
          reason: 'and the refusal happened before the write');
    });

    test('a root enrollment can still write ANOTHER privatekey: key',
        () async {
      // The scope control. `_rootOnlyWritableKeyRegex` covers the whole
      // `privatekey:` prefix, and only the at_pkam_publickey case is narrowed
      // — everything else in that set is still decided by root privilege
      // alone. Without this the refusal above would be indistinguishable from
      // having locked root enrollments out of the entire prefix.
      //
      // The JSON form because the plain `update:` grammar does not accept a
      // namespace-less `privatekey:` key with an arbitrary suffix — the same
      // form the non-root refusals for these keys already use, so the two
      // arms differ in the enrollment and in nothing else.
      await bindRoot();
      final params = UpdateParams()
        ..atKey = 'privatekey:self_encryption_key'
        ..value = 'NEW_VALUE'
        ..metadata = Metadata();
      await updateVerbHandler.process(
          'update:json:${jsonEncode(params.toJson())}', inboundConnection);
      expect((await keyValueStore.get('privatekey:self_encryption_key'))?.data,
          'NEW_VALUE');
    });

    test('the PKAM key guard is not case-sensitive', () async {
      // Verb regexes are built caseSensitive:false and the keystore lowercases
      // on put, so an uppercase spelling addresses the same record.
      await bindScoped();
      await expectLater(
          updateVerbHandler.process(
              'update:PRIVATEKEY:AT_PKAM_PUBLICKEY REPLACEMENT_KEY',
              inboundConnection),
          throwsA(isA<UnAuthorizedException>()));
    });

    test('...and neither is it for a ROOT enrollment', () async {
      // The arm that matters now that the refusal turns on an exact key
      // comparison rather than on a case-insensitive regex alone. Comparing
      // the key AS RECEIVED rather than as the keystore folds it would let a
      // root enrollment reach the very record the test above protects, by
      // holding down shift.
      await bindRoot();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');
      await expectLater(
          updateVerbHandler.process(
              'update:PRIVATEKEY:AT_PKAM_PUBLICKEY REPLACEMENT_KEY',
              inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason: 'the same record under another spelling is the same record');
      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          'ORIGINAL_KEY');
    });

    test('...and the legacy carve-out is not case-sensitive either', () async {
      // The carve-out compares against the key AFTER the same normalisation
      // the keystore applies. Comparing against the spelling as received
      // would refuse the legacy connection its own rotation for a shift key,
      // and the refusal would read as an authorisation bug.
      //
      // Same discriminator as above: an IllegalArgumentException means this
      // spelling reached the possession check, so authorization admitted it.
      await bindLegacy();
      await expectLater(
          updateVerbHandler.process(
              'update:PRIVATEKEY:AT_PKAM_PUBLICKEY NEW_KEY',
              inboundConnection),
          throwsA(isA<IllegalArgumentException>().having((e) => e.message,
              'message', contains('requires proof'))));
    });

    // ---- the atSign's own key material ----

    for (final key in [
      'public:publickey@alice',
      'public:signing_publickey@alice',
      '@alice:signing_privatekey@alice',
    ]) {
      test('scoped enrollment cannot overwrite $key', () async {
        await bindScoped();
        await keyValueStore.put(key, AtData()..data = 'GENUINE');

        await expectLater(
            updateVerbHandler.process(
                'update:$key REPLACEMENT', inboundConnection),
            throwsA(isA<UnAuthorizedException>()));
        final stored = await keyValueStore.get(key);
        expect(stored?.data, 'GENUINE');
      });

      test('scoped enrollment CAN still read $key', () async {
        // Reads stay open: sync force-includes these keys and then ANDs the
        // result with this authorization check.
        await bindScoped();
        await keyValueStore.put(key, AtData()..data = 'GENUINE');
        await localLookupVerbHandler.process('llookup:$key', inboundConnection);
        expect(inboundConnection.lastWrittenData, contains('GENUINE'));
      });

      test('a root enrollment CAN overwrite $key', () async {
        await bindRoot();
        await keyValueStore.put(key, AtData()..data = 'GENUINE');
        await updateVerbHandler.process(
            'update:$key ROTATED', inboundConnection);
        final stored = await keyValueStore.get(key);
        expect(stored?.data, 'ROTATED');
      });
    }

    // ---- the two shared_key forms stay reachable ----

    for (final key in [
      'shared_key.bob@alice',
      '@bob:shared_key@alice',
    ]) {
      test('scoped enrollment CAN create $key', () async {
        await bindScoped();
        await updateVerbHandler.process(
            'update:$key encryptedvalue', inboundConnection);
        final stored = await keyValueStore.get(key);
        expect(stored?.data, 'encryptedvalue');
      });

      test('scoped enrollment CAN read and delete $key', () async {
        await bindScoped();
        await keyValueStore.put(key, AtData()..data = 'encryptedvalue');
        await localLookupVerbHandler.process('llookup:$key', inboundConnection);
        expect(inboundConnection.lastWrittenData, contains('encryptedvalue'));
        await deleteVerbHandler.process('delete:$key', inboundConnection);
      });
    }

    // ---- keys that merely contain an allow-listed form ----

    for (final key in [
      'x.shared_key.bob@alice',
      'evilshared_key.zz@alice',
      '@charlie:secret.shared_key.evil@alice',
    ]) {
      test('scoped enrollment is denied "$key"', () async {
        // Not shared keys: they contain an allow-listed form as a substring.
        await bindScoped();
        await expectLater(
            updateVerbHandler.process('update:$key v', inboundConnection),
            throwsA(isA<UnAuthorizedException>()));
      });
    }

    test('the root-key allowlist is anchored, not a substring match', () async {
      // Asserted against the predicate rather than a verb handler: some of
      // these are rejected by verb grammar before authorization is reached.
      final enrollId = await bindScoped();
      final enroll = await enMgr.getEnrollmentById(enrollId);
      for (final key in [
        'x.shared_key.bob@alice',
        'evilshared_key.zz@alice',
        '@charlie:secret.shared_key.evil@alice',
        'notpublic:publickey@alice',
        'public:publickeyy@alice',
        'shared_key.bob@alice.evil@alice',
        'prefix:privatekey:at_pkam_publickey',
      ]) {
        expect(updateVerbHandler.isAuthorizedSync(enroll, enrollId, atKey: key),
            isFalse,
            reason: '"$key" only contains an exempt form, it is not one');
      }
    });

    test('a genuinely namespaced shared_key is still namespace-governed',
        () async {
      // @bob:shared_key.wavi@alice has namespace 'wavi', so it is decided by
      // the grant rather than by the namespace-less rule.
      await bindScoped();
      await updateVerbHandler.process(
          'update:@bob:shared_key.wavi$alice v', inboundConnection);
      expect(inboundConnection.lastWrittenData, contains('data:'));

      await bindEnrollment({'other': 'rw'});
      await expectLater(
          updateVerbHandler.process(
              'update:@bob:shared_key.wavi$alice v', inboundConnection),
          throwsA(isA<UnAuthorizedException>()));
    });

    test("an enrollment granted the namespace 'null' gets no root access",
        () async {
      // A key with no namespace must not match a grant named 'null'.
      await bindEnrollment({'null': 'rw'});
      for (final key in ['foo$alice', 'public:foo$alice', '@bob:foo$alice']) {
        await expectLater(
            updateVerbHandler.process('update:$key v', inboundConnection),
            throwsA(isA<UnAuthorizedException>()),
            reason: '$key has no namespace and must not match a "null" grant');
      }
    });

    test("a key whose namespace really is 'null' still resolves", () async {
      await bindEnrollment({'null': 'rw'});
      await updateVerbHandler.process(
          'update:foo.null$alice v', inboundConnection);
      expect(inboundConnection.lastWrittenData, contains('data:'));
    });

    // ---- matching the key the keystore writes ----

    for (final variant in [
      'public:publickey@alice ',
      ' public:publickey@alice',
      'public:publickey@alice\t',
      'PUBLIC:PUBLICKEY@ALICE'
    ]) {
      test('a non-root enrollment is denied ${jsonEncode(variant)}', () async {
        // HiveKeyStoreHelper.prepareKey normalises with
        // trim().toLowerCase().replaceAll(' ',''), so these variants all
        // address the same record. A '*:rw' enrollment is not a root
        // enrollment.
        await bindWildcard();
        await keyValueStore.put(
            'public:publickey$alice', AtData()..data = 'GENUINE');
        final params = UpdateParams()
          ..atKey = variant
          ..value = 'REPLACEMENT'
          ..metadata = Metadata();
        await expectLater(
            updateVerbHandler.process(
                'update:json:${jsonEncode(params.toJson())}',
                inboundConnection),
            throwsA(isA<UnAuthorizedException>()));
        final stored = await keyValueStore.get('public:publickey$alice');
        expect(stored?.data, 'GENUINE');
      });
    }

    // ---- the privatekey: prefix ----

    for (final key in [
      'privatekey:at_secret',
      'privatekey:at_pkam_privatekey',
      'privatekey:self_encryption_key',
    ]) {
      test('a non-root *:rw enrollment cannot write $key', () async {
        // These hold the server's own credentials and internal state.
        await bindWildcard();
        final params = UpdateParams()
          ..atKey = key
          ..value = 'REPLACEMENT'
          ..metadata = Metadata();
        await expectLater(
            updateVerbHandler.process(
                'update:json:${jsonEncode(params.toJson())}',
                inboundConnection),
            throwsA(isA<UnAuthorizedException>()));
      });
    }

    test('a root enrollment can still delete the CRAM secret', () async {
      // Onboarding removes privatekey:at_secret once PKAM is established.
      await bindRoot();
      await keyValueStore.put(
          'privatekey:at_secret', AtData()..data = 'SECRET');
      await deleteVerbHandler.process(
          'delete:privatekey:at_secret', inboundConnection);
    });

    // ---- cached copies of another atSign's public keys ----

    test('a *:rw enrollment can still evict a cached foreign public key',
        () async {
      // A cached copy of data that is public at its origin.
      await bindWildcard();
      await keyValueStore.put(
          'cached:public:publickey@bob', AtData()..data = 'BOBKEY');
      await deleteVerbHandler.process(
          'delete:cached:public:publickey@bob', inboundConnection);
    });

    test('a scoped enrollment cannot evict a cached foreign public key',
        () async {
      await bindScoped();
      await keyValueStore.put(
          'cached:public:publickey@bob', AtData()..data = 'BOBKEY');
      await expectLater(
          deleteVerbHandler.process(
              'delete:cached:public:publickey@bob', inboundConnection),
          throwsA(isA<UnAuthorizedException>()));
    });

    // ---- config:block ----

    test('scoped enrollment cannot read or modify the blocklist', () async {
      await bindScoped();
      for (final command in [
        'config:block:show',
        'config:block:add:@evil',
        'config:block:remove:@evil',
      ]) {
        await expectLater(configVerbHandler.process(command, inboundConnection),
            throwsA(isA<UnAuthorizedException>()),
            reason: '$command is an atSign-level privilege');
      }
    });

    test('a *:rw enrollment without __manage cannot modify the blocklist',
        () async {
      await bindWildcard();
      await expectLater(
          configVerbHandler.process(
              'config:block:add:@evil', inboundConnection),
          throwsA(isA<UnAuthorizedException>()));
    });

    test('a root enrollment CAN modify the blocklist', () async {
      await bindRoot();
      await configVerbHandler.process(
          'config:block:add:@evil', inboundConnection);
      expect(inboundConnection.lastWrittenData, contains('data:'));
    });

    test('an unparseable atKey returns rather than throwing', () async {
      // AtKey.fromString raises Errors as well as Exceptions on these, and the
      // check runs inside sync's synchronous where: predicate.
      final enrollId = await bindScoped();
      final enroll = await enMgr.getEnrollmentById(enrollId);
      for (final key in [
        'privatekey:at_secret',
        'privatekey:privatekey',
        'configkey',
        '_latestNotificationIdv2',
        'cached:shared_key.bob@alice',
      ]) {
        expect(
            () => updateVerbHandler.isAuthorizedSync(enroll, enrollId,
                atKey: key),
            returnsNormally,
            reason: '$key must not throw out of the authorization check');
      }
    });
  });
}
