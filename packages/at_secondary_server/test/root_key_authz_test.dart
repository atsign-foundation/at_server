import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_secondary/src/verb/handler/batch_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/config_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_utils/at_logger.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

/// Covers authorization of namespace-less keys: keys carrying no namespace an
/// enrollment can be granted, so the namespace check cannot decide them.
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

    /// A fully privileged enrollment under the literal id `primary`, the id
    /// a legacy `pkam:` authenticates as.
    Future<String> bindPreviouslyCarvedOutId() => bindRoot(id: 'primary');

    /// A connection carrying NO enrollment id, authenticated with the CRAM
    /// secret: the shape a fresh atSign is given its first keypair over.
    void bindCram() {
      inboundConnection.metadata.isAuthenticated = true;
      inboundConnection.metadata.enrollmentId = null;
      inboundConnection.metadata.authType = AuthType.cram;
    }

    BatchVerbHandler batchHandler() => BatchVerbHandler(
        keyValueStore,
        DefaultVerbHandlerManager(
            keyValueStore,
            mockOutboundClientManager,
            cacheManager,
            statsNotificationService,
            notificationManager,
            enMgr,
            alice,
            commitLog: atCommitLog,
            accessLog: atAccessLog));

    /// A legacy-PKAM connection: authenticated, carrying no enrollment id,
    /// and NOT CRAM, the one null-id caller the write ban refuses.
    void bindLegacyNoId() {
      inboundConnection.metadata.isAuthenticated = true;
      inboundConnection.metadata.enrollmentId = null;
      inboundConnection.metadata.authType = AuthType.pkamLegacy;
    }


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
      await bindRoot();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');

      await expectLater(
          updateVerbHandler.process(
              'update:${AtConstants.atPkamPublicKey} REPLACEMENT_KEY',
              inboundConnection),
          throwsA(isA<UnAuthorizedException>().having(
              (e) => e.message, 'message', contains('may not be written'))),
          reason: 'root privilege is not enough for THIS key: an APKAM root '
              'that plants a key it holds gains a legacy identity, and legacy '
              'PKAM carries no enrollment id — so revoking that root leaves '
              'the planted key authenticating');
      final stored = await keyValueStore.get(AtConstants.atPkamPublicKey);
      expect(stored?.data, 'ORIGINAL_KEY',
          reason: 'and the refusal happened before the write');
    });

    test('the id that once had a carve-out is refused like any other',
        () async {
      await bindPreviouslyCarvedOutId();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');

      await expectLater(
          updateVerbHandler.process(
              'update:${AtConstants.atPkamPublicKey} NEW_KEY',
              inboundConnection),
          throwsA(isA<UnAuthorizedException>().having(
              (e) => e.message, 'message', contains('may not be written'))),
          reason: 'refused by the one gate, like every other connection: no '
              'id carries a right to write this key');

      final stored = await keyValueStore.get(AtConstants.atPkamPublicKey);
      expect(stored?.data, 'ORIGINAL_KEY',
          reason: 'and the refusal happened before the write');
    });

    test('a CRAM connection may write it, with testingMode off', () async {
      AtSecondaryConfig.testingModeOverride = false;
      addTearDown(() => AtSecondaryConfig.testingModeOverride = null);

      bindCram();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');

      await updateVerbHandler.process(
          'update:${AtConstants.atPkamPublicKey} NEW_KEY', inboundConnection);

      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          'ORIGINAL_KEY',
          reason: 'admitted, but the flat key itself is never written: the '
              'value is installed as the primary enrollment instead, so no '
              'flat key exists on a running server in any mode');
      expect(
          (await enMgr.getEnrollmentById(
                  EnrollmentManager.primaryEnrollmentId))
              .apkamPublicKey,
          'NEW_KEY',
          reason: 'a CRAM holder is auto-approved a *:rw + __manage:rw '
              'enrollment on request, which is what primary holds, so the '
              'install grants it nothing it could not already give itself; '
              'and the packs have nothing to authenticate with if this is '
              'refused — they authenticate as primary');
    });

    test('...and with testingMode on: the flag is not what admits it',
        () async {
      // Pairs with the arm above, differing in testingMode alone.
      AtSecondaryConfig.testingModeOverride = true;
      addTearDown(() => AtSecondaryConfig.testingModeOverride = null);

      bindCram();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');

      await updateVerbHandler.process(
          'update:${AtConstants.atPkamPublicKey} NEW_KEY', inboundConnection);

      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          'ORIGINAL_KEY');
      expect(
          (await enMgr.getEnrollmentById(
                  EnrollmentManager.primaryEnrollmentId))
              .apkamPublicKey,
          'NEW_KEY');
    });

    for (final bool flag in [false, true]) {
      test(
          'a legacy connection carrying no id is refused, with testingMode '
          '${flag ? 'on' : 'off'}', () async {
        // The negative control: differs from the CRAM arms in auth type alone.
        AtSecondaryConfig.testingModeOverride = flag;
        addTearDown(() => AtSecondaryConfig.testingModeOverride = null);

        inboundConnection.metadata.isAuthenticated = true;
        inboundConnection.metadata.enrollmentId = null;
        inboundConnection.metadata.authType = AuthType.pkamLegacy;
        await keyValueStore.put(
            AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');

        await expectLater(
            updateVerbHandler.process(
                'update:${AtConstants.atPkamPublicKey} NEW_KEY',
                inboundConnection),
            throwsA(isA<UnAuthorizedException>().having(
                (e) => e.message, 'message', contains('may not be written'))),
            reason: 'the carve-out is CRAM alone, and a legacy connection is '
                'not CRAM whatever the flag says');
        expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
            'ORIGINAL_KEY',
            reason: 'and the refusal happened before the write');
      });
    }

    test('a root enrollment can still write ANOTHER privatekey: key',
        () async {
      // The scope control: root enrollments are not locked out of the whole
      // `privatekey:` prefix.
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

    test('the PKAM key guard is not case-sensitive, for a ROOT enrollment',
        () async {
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

    test('...and neither is the write ban, for a connection with no id',
        () async {
      bindLegacyNoId();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');
      await expectLater(
          updateVerbHandler.process(
              'update:PRIVATEKEY:AT_PKAM_PUBLICKEY NEW_KEY',
              inboundConnection),
          throwsA(isA<UnAuthorizedException>().having(
              (e) => e.message, 'message', contains('may not be written'))),
          reason: 'the same record under another spelling is the same record: '
              'comparing the key as RECEIVED would let a shift key install an '
              'unrevokable credential');
      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          'ORIGINAL_KEY',
          reason: 'and the refusal happened before the write');
    });

    test('...and over CRAM a shifted spelling is redirected, not stored',
        () async {
      // Pairs with the legacy arm above, differing in the auth type alone.
      bindCram();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');

      await updateVerbHandler.process(
          'update:PRIVATEKEY:AT_PKAM_PUBLICKEY NEW_KEY', inboundConnection);

      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          'ORIGINAL_KEY',
          reason: 'the flat key is never written, under any spelling');
      expect(
          (await enMgr.getEnrollmentById(
                  EnrollmentManager.primaryEnrollmentId))
              .apkamPublicKey,
          'NEW_KEY',
          reason: 'the redirect compares the key as the keystore folds it');
    });

    test('CONTROL: the same grants under an ordinary id are refused', () async {
      // The scope control: an ordinary enrollment under the same spelling.
      await bindEnrollment({'wavi': 'rw'});
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');
      await expectLater(
          updateVerbHandler.process(
              'update:PRIVATEKEY:AT_PKAM_PUBLICKEY NEW_KEY',
              inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason: 'NO enrollment may write at_pkam_publickey, whatever it '
              'holds — an enrollment that plants a key it possesses gains a '
              'credential its own revocation cannot reach');
      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          'ORIGINAL_KEY');
    });


    test('update:json reaches the ban', () async {
      bindLegacyNoId();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');

      final json = jsonEncode({
        'atKey': AtConstants.atPkamPublicKey,
        'value': 'REPLACEMENT_KEY',
        'metadata': Metadata().toJson(),
      });
      await expectLater(
          updateVerbHandler.process('update:json:$json', inboundConnection),
          throwsA(isA<UnAuthorizedException>().having(
              (e) => e.message, 'message', contains('may not be written'))),
          reason: 'the json form is the one route that can store a value the '
              'plain grammar rejects, so a ban that covered only the plain '
              'form would leave the sharper write open');

      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          'ORIGINAL_KEY',
          reason: 'and the refusal happened before the write');
    });

    test('update:json over CRAM is redirected into primary too', () async {
      // Pairs with the arm above, differing in the auth type alone.
      bindCram();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');
      final json = jsonEncode({
        'atKey': AtConstants.atPkamPublicKey,
        'value': 'REPLACEMENT_KEY',
        'metadata': Metadata().toJson(),
      });

      await updateVerbHandler.process('update:json:$json', inboundConnection);

      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          'ORIGINAL_KEY',
          reason: 'no flat key is written on the json route either');
      expect(
          (await enMgr.getEnrollmentById(
                  EnrollmentManager.primaryEnrollmentId))
              .apkamPublicKey,
          'REPLACEMENT_KEY');
    });

    test('a zero-length update:json value is refused before it can be stored',
        () async {
      bindCram();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');

      final json = jsonEncode({
        'atKey': AtConstants.atPkamPublicKey,
        'value': '',
        'metadata': Metadata().toJson(),
      });
      await expectLater(
          updateVerbHandler.process('update:json:$json', inboundConnection),
          throwsA(isA<InvalidSyntaxException>()),
          reason: 'update:json carries the value inside the document, which '
              'is how a zero-length value used to reach the keystore at all');

      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          'ORIGINAL_KEY');
    });

    test('CONTROL: update:json writes an ordinary key on this connection',
        () async {
      // The control: drawn from a key the ban does not touch.
      bindCram();
      final json = jsonEncode({
        'atKey': 'privatekey:self_encryption_key',
        'value': 'ORDINARY',
        'metadata': Metadata().toJson(),
      });
      await updateVerbHandler.process(
          'update:json:$json', inboundConnection);
      expect(
          (await keyValueStore.get('privatekey:self_encryption_key'))?.data,
          'ORDINARY',
          reason: 'the json route itself works on this connection; only the '
              'one key is refused');
    });

    test('a batch-wrapped update reaches the ban', () async {
      bindLegacyNoId();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');

      final response = await batchHandler().processInternal(
          'batch:[{"id":1,"command":"update:privatekey:at_pkam_publickey '
          'NEW_KEY"}]',
          inboundConnection);

      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          'ORIGINAL_KEY',
          reason: 'wrapping the command in a batch must not get it past the '
              'refusal — batch re-dispatches to the same handler');
      expect(await enMgr.primaryEnrollment(), isNull,
          reason: 'refused, not redirected: nothing was installed anywhere');
      expect(response.data, contains('"id":1'),
          reason: 'and the element is reported, not silently dropped');
      expect(response.data, contains('AT0009'),
          reason: 'refused as unauthorised, in the element\'s own response');
    });

    test('a batch-wrapped update over CRAM is redirected into primary',
        () async {
      // Pairs with the arm above, differing in the auth type alone.
      bindCram();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');

      await batchHandler().processInternal(
          'batch:[{"id":1,"command":"update:privatekey:at_pkam_publickey '
          'NEW_KEY"}]',
          inboundConnection);

      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          'ORIGINAL_KEY',
          reason: 'no flat key is written on the batch route either');
      expect(
          (await enMgr.getEnrollmentById(
                  EnrollmentManager.primaryEnrollmentId))
              .apkamPublicKey,
          'NEW_KEY');
    });

    test('update:meta cannot name the key at all', () async {
      // NOTE update:meta's atKey class is colon-free, so this key is
      // unreachable rather than refused.
      expect(
          RegExp(VerbSyntax.update_meta).hasMatch(
              'update:meta:privatekey:at_pkam_publickey@alice:ttl:1000'),
          isFalse,
          reason: 'update:meta has no route to the legacy PKAM credential, so '
              'the ban has nothing to close there');
      expect(
          RegExp(VerbSyntax.update_meta)
              .hasMatch('update:meta:phone.wavi@alice:ttl:1000'),
          isTrue,
          reason: 'CONTROL: the same regex does match an ordinary atKey, so '
              'the miss above is about this key and not about the pattern');
    });

    test('delete cannot name the key at all', () async {
      expect(
          RegExp(VerbSyntax.delete)
              .hasMatch('delete:privatekey:at_pkam_publickey'),
          isFalse,
          reason: 'a credential installable and not removable is precisely '
              'what the write ban exists to prevent');
      expect(
          RegExp(VerbSyntax.delete).hasMatch('delete:privatekey:at_secret'),
          isTrue,
          reason: 'CONTROL: the delete grammar does whitelist a privatekey: '
              'key, so the miss above is about which one');
    });


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
        // NOTE reads stay open: sync force-includes these keys.
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
        expect(
            updateVerbHandler.isAuthorizedSync(enroll, enrollId,
                cram: false, atKey: key),
            isFalse,
            reason: '"$key" only contains an exempt form, it is not one');
      }
    });

    test('a genuinely namespaced shared_key is still namespace-governed',
        () async {
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


    // NOTE whitespace only: case cannot be isolated, being lowercased by the
    // fold before the caseSensitive:false regex sees it.
    for (final variant in [
      'public:publickey@alice ',
      ' public:publickey@alice',
      'public:publickey@alice\t',
    ]) {
      test('a non-root enrollment is denied ${jsonEncode(variant)}', () async {
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

    test('NO enrollment may WRITE the CRAM secret, root included', () async {
      await bindRoot();
      await keyValueStore.put(
          AtConstants.atCramSecret, AtData()..data = 'ORIGINAL_SECRET');

      final json = jsonEncode({
        'atKey': AtConstants.atCramSecret,
        'value': 'A_SECRET_THE_CALLER_KNOWS',
        'metadata': Metadata().toJson(),
      });
      await expectLater(
          updateVerbHandler.process('update:json:$json', inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason: 'root privilege decides every other key on this prefix; '
              'this one is refused outright');

      expect((await keyValueStore.get(AtConstants.atCramSecret))?.data,
          'ORIGINAL_SECRET',
          reason: 'and the refusal happened before the write');
    });

    test('NO enrollment may WRITE the CRAM tombstone, root included', () async {
      await bindRoot();

      final json = jsonEncode({
        'atKey': AtConstants.atCramSecretDeleted,
        'value': 'true',
        'metadata': Metadata().toJson(),
      });
      await expectLater(
          updateVerbHandler.process('update:json:$json', inboundConnection),
          throwsA(isA<UnAuthorizedException>()));

      expect(await keyValueStore.exists(AtConstants.atCramSecretDeleted),
          isFalse,
          reason: 'an atSign that never deleted its CRAM secret must not be '
              'left unable to replant one');
    });

    test('a root enrollment can still delete the CRAM secret', () async {
      await bindRoot();
      await keyValueStore.put(
          'privatekey:at_secret', AtData()..data = 'SECRET');
      await deleteVerbHandler.process(
          'delete:privatekey:at_secret', inboundConnection);
    });


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
      // NOTE AtKey.fromString raises Errors as well as Exceptions on these.
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
                cram: false, atKey: key),
            returnsNormally,
            reason: '$key must not throw out of the authorization check');
      }
    });
  });
}
