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
    /// [id] names it explicitly, which is what lets a case assert that no
    /// particular id is special.
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
    /// a legacy `pkam:` authenticates as. The literal is what pins that this
    /// id carries no right to write the flat credential; a random uuid would
    /// not catch an id-keyed exception.
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
      // The stored value, not merely that the call threw.
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
      // The one key in the root-only set that MINTS AN IDENTITY rather than
      // serving one: legacy PKAM authenticates against it carrying no
      // enrollment id, so a root that plants a key it holds gains an
      // identity its own revocation cannot reach.
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
      // An id-keyed permission on this key is the shape to avoid: whoever
      // holds an enrollment spelled that way would inherit the atSign's
      // unrevokable credential. One gate decides the key for every
      // connection, ahead of any per-enrollment reading, so the ban's own
      // message is what comes back whatever id the connection carries.
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
      // The one admitted write, and it is admitted in EVERY mode: a fresh
      // atSign is given its first keypair over CRAM with a plain unsigned
      // update, against a server running the shipped configuration. The flag
      // is forced off rather than left to the environment so the arm pins
      // what its name says.
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
      // Pairs with the arm above, differing in testingMode and in nothing
      // else: a gate that read the flag would redden one arm, not both.
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
        // The negative control for the two CRAM arms, differing from them in
        // the auth type and in nothing else: same command, same stored
        // value, same flag. A legacy-PKAM connection carries no enrollment
        // id either, so it is what the null-id short circuit would wave
        // through if the gate sat behind it, and this arm pins the gate's
        // position. CRAM says the caller holds the secret the atSign was
        // created with; legacy says only that it holds the credential this
        // write would replace.
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
      // The scope control: `_rootOnlyWritableKeyRegex` covers the whole
      // `privatekey:` prefix and only at_pkam_publickey is refused outright,
      // so without this arm the refusal above is indistinguishable from
      // locking root enrollments out of the entire prefix. The json form
      // because the plain grammar cannot express a namespace-less
      // `privatekey:` key with an arbitrary suffix, and it is the form the
      // non-root refusals use, so the arms differ only in the enrollment.
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
      // A ROOT enrollment is the only fixture that can pin this. The refusal
      // compares the FOLDED key against `privatekey:at_pkam_publickey`, and
      // a miss falls through to `isRootEnrollment`, which refuses a scoped
      // enrollment anyway with the same exception. Only a caller the
      // fallback would ADMIT can tell a folded comparison from an unfolded
      // one, and an unfolded one lets a root reach this record by holding
      // down shift.
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
      // The same fold invariant as the case above, asked of the write ban
      // rather than of the root branch. It has to be a connection carrying
      // no enrollment id and not CRAM: an enrolled connection is refused
      // under either spelling and so pins nothing, and CRAM is admitted
      // under either spelling (the arm below pins what the fold does
      // there). For a legacy null-id caller an unfolded comparison would
      // miss the ban, fall through to the null-id short circuit and admit
      // the write.
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
      // CRAM is admitted, so the fold's job moves to the redirect: a
      // spelling the keystore folds onto the flat key must land in `primary`
      // like the canonical one, and never at the flat key.
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
      // The scope control for the fold: identical spelling and command under
      // an ordinary id and ordinary grants. Without it the arms above are
      // satisfied by the key being unreachable only to null-id connections,
      // leaving every enrollment able to write it under a shifted spelling.
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

    // ---- every route that could name the legacy PKAM credential ----
    //
    // The ban sits at one seam, so these pin the claim that every route
    // reaches it. Three routes are wire grammars this package does not own,
    // so a loosening elsewhere opens one with nothing here changing, which
    // is why the commands are raw literals rather than built from constants.

    test('update:json reaches the ban', () async {
      // update:json can NAME this key without the plain grammar's charset
      // having a say, so the ban rather than the grammar has to refuse it.
      // The value is non-empty deliberately: a zero-length document is
      // refused as a syntax error BEFORE the ban is consulted, which would
      // green this case without exercising the ban, and is asserted
      // separately below. Legacy null-id, because CRAM is admitted on every
      // update route; the arm after this one is its CRAM half.
      bindLegacyNoId();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');

      // Metadata.toJson is the shape a real client emits, so this is a
      // request a client can actually send, not a hand-rolled document.
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
      // Pairs with the arm above, differing in the auth type alone. The
      // exception is keyed on the verb and update:json re-dispatches into
      // it, so the json route is admitted and redirected as the plain one
      // is; a redirect covering only the plain form would let the json form
      // plant the flat key.
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
      // A zero-length credential is not harmless: it is what stops the flat
      // key counting as a root the atSign can fall back on. The value check
      // refuses it, not the ban, so the two are asserted separately.
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
      // Drawn from a key the ban does not touch, so it stays green under any
      // mutation of the ban. Without it the case above is equally satisfied
      // by update:json being broken or unroutable on this connection.
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
      // batch: writes nothing itself, it re-dispatches each element through
      // that element's own handler, so the ban is reached only if the
      // element lands back at the update seam. Legacy null-id, the caller
      // the ban refuses; an unchanged flat key alone would not prove the
      // refusal, because the CRAM arm below leaves it unchanged too by
      // redirecting, so this arm also asks that nothing was installed.
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
      // batch: reports an element's refusal as its error CODE with the
      // generic UnAuthorized text, not the ban's own message; the message is
      // pinned on the plain and json routes above.
      expect(response.data, contains('AT0009'),
          reason: 'refused as unauthorised, in the element\'s own response');
    });

    test('a batch-wrapped update over CRAM is redirected into primary',
        () async {
      // Pairs with the arm above, differing in the auth type alone: the
      // element lands at the same seam, so CRAM is admitted and redirected
      // through batch: as it is on the plain route.
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
      // A NEGATIVE pin on a grammar this package does not own: update:meta's
      // atKey class is colon-free, so `privatekey:...` cannot be expressed in
      // it and the key is unreachable rather than refused. Widening that
      // class opens the route with nothing here changing, and this goes red.
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
      // The other half of "nothing can take it back", and why the write is
      // banned rather than audited: once installed no verb removes it. The
      // delete grammar whitelists one privatekey: key, and not this one.
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

    // WHITESPACE ONLY. HiveKeyStoreHelper.prepareKey normalises with
    // trim().toLowerCase().replaceAll(' ',''), and only the trim and the
    // strip are load-bearing for THIS key: `_ownKeyMaterialRegex` is
    // anchored, so a stray space or tab defeats it and nothing but the fold
    // puts the key back. Case cannot be isolated, being decided twice over:
    // the regex is caseSensitive:false, and the fold has already lowercased
    // the key before the regex sees it, so an uppercase variant is green
    // whichever of the two is removed.
    for (final variant in [
      'public:publickey@alice ',
      ' public:publickey@alice',
      'public:publickey@alice\t',
    ]) {
      test('a non-root enrollment is denied ${jsonEncode(variant)}', () async {
        // A '*:rw' enrollment is not a root enrollment, and every variant
        // addresses the record it must not reach.
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

    test('NO enrollment may WRITE the CRAM secret, root included', () async {
      // The CRAM secret mints an identity exactly as the PKAM key does: a
      // caller that installs a secret it knows can authenticate as the owner
      // carrying NO enrollment id, so revoking the enrollment that planted it
      // takes nothing back. The json form, because the plain grammar cannot
      // express this key at all.
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
      // Planting this marker permanently disables CRAM replanting, the
      // atSign's last recovery route once its roots are revoked. Only
      // update:json can name the key; the plain and delete grammars cannot.
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
