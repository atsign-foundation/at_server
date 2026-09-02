import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
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
    /// [id] names the enrollment explicitly, which is what lets a case assert
    /// that no id is special.
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

    /// A fully privileged enrollment under the id `primary`.
    ///
    /// The literal is deliberate. `primary` is the atSign-wide sentinel for
    /// "no enrollment id", and it once named a carve-out that let a connection
    /// carrying it write the PKAM key. Naming it here is what pins that no id
    /// is special any more — an id-keyed exception reintroduced under any
    /// other name would not be caught by a case that used a random uuid.
    Future<String> bindPreviouslyCarvedOutId() => bindRoot(id: 'primary');

    /// A connection carrying NO enrollment id, authenticated with the CRAM
    /// secret — the shape the virtual environment installs the first PKAM
    /// keypair over.
    void bindCram() {
      inboundConnection.metadata.isAuthenticated = true;
      inboundConnection.metadata.enrollmentId = null;
      inboundConnection.metadata.authType = AuthType.cram;
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

    test('the id that once had a carve-out is refused like any other',
        () async {
      // INVERTED. `primary` used to be admitted here: a legacy connection was
      // authenticated as that enrollment, so the id named the one principal
      // allowed to rotate the credential it had just authenticated with.
      //
      // Legacy PKAM carries no enrollment id again, so there is no principal
      // for such a carve-out to name — and an id-keyed permission on this key
      // is exactly the shape to avoid, because whoever holds an enrollment
      // spelled that way inherits the atSign's unrevokable credential.
      //
      // The MESSAGE is the discriminator, not the type: both refusals on this
      // path throw UnAuthorizedException, and the one that must fire here is
      // the per-enrollment authorization check. Restoring the carve-out would
      // carry this past it and into the write ban, whose message is different.
      await bindPreviouslyCarvedOutId();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');

      await expectLater(
          updateVerbHandler.process(
              'update:${AtConstants.atPkamPublicKey} NEW_KEY',
              inboundConnection),
          throwsA(isA<UnAuthorizedException>().having((e) => e.message,
              'message', contains('is not authorized to update key'))),
          reason: 'refused by the per-enrollment authorization check, like '
              'every other enrollment: no id carries a right to write this '
              'key');

      final stored = await keyValueStore.get(AtConstants.atPkamPublicKey);
      expect(stored?.data, 'ORIGINAL_KEY',
          reason: 'and the refusal happened before the write');
    });

    test('a connection carrying NO enrollment id is refused too', () async {
      // The whole point of the ban, and the case the per-enrollment check
      // cannot make: `isAuthorizedSync` returns true for a null enrollment id
      // before any key is examined, so an owner connection never reaches the
      // decision the cases above exercise. It is stopped by the second gate
      // instead, and the message says which.
      //
      // testingMode is false here — the shipped default, and what every
      // failure to read the setting answers.
      bindCram();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');

      await expectLater(
          updateVerbHandler.process(
              'update:${AtConstants.atPkamPublicKey} NEW_KEY',
              inboundConnection),
          throwsA(isA<UnAuthorizedException>().having(
              (e) => e.message, 'message', contains('may not be written'))),
          reason: 'a credential that carries no enrollment id and that no '
              'verb can withdraw is not installable on a production atSign, '
              'by an owner or by anybody');

      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          'ORIGINAL_KEY',
          reason: 'and the refusal happened before the write');
    });

    test('a CRAM connection under testingMode may write it', () async {
      // The positive control for the case above, and the reason the exception
      // exists: the virtual environment installs the first keypair this way
      // against a throwaway atSign, over CRAM, with a plain unsigned update.
      //
      // Its negative control is the case above, which differs from this one in
      // testingMode and in NOTHING else — same connection shape, same command,
      // same stored value beforehand.
      AtSecondaryConfig.testingModeOverride = true;
      addTearDown(() => AtSecondaryConfig.testingModeOverride = null);

      bindCram();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');

      await updateVerbHandler.process(
          'update:${AtConstants.atPkamPublicKey} NEW_KEY', inboundConnection);

      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          'NEW_KEY',
          reason: 'the virtual environment installs the atSign\'s first PKAM '
              'keypair over CRAM, and the packs have nothing to authenticate '
              'with if this is refused');
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

    test('the PKAM key guard is not case-sensitive, for a ROOT enrollment',
        () async {
      // A ROOT enrollment is the only fixture that can pin this, and the
      // reason is worth stating because the obvious scoped arm was here until
      // it was measured. The refusal turns on an exact comparison of the
      // FOLDED key against `privatekey:at_pkam_publickey`; when that
      // comparison misses, the branch falls through to `isRootEnrollment`. So
      // for a scoped enrollment the fold changes nothing — the fallback
      // refuses it too, with the same exception, and an uppercase scoped case
      // is green whether or not the key is folded. Only a caller the FALLBACK
      // would admit can tell the two apart.
      //
      // What it pins: comparing the key AS RECEIVED rather than as the
      // keystore folds it lets a root enrollment reach the record every other
      // case here protects, by holding down shift.
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
      // PORTED, not deleted. The invariant is the same one the case above
      // pins — the record is compared as the KEYSTORE would fold it, so a
      // spelling that lands on this record cannot slip past the guard — but
      // it has moved with the guard.
      //
      // It has to be asked over a connection carrying no enrollment id. An
      // ENROLLED connection can no longer ask it: with no carve-out left, an
      // unfolded comparison misses and the branch refuses that connection
      // anyway, so both spellings give the identical outcome and the case
      // pins nothing. A connection with no id is the one the write ban
      // decides on its own.
      bindCram();
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

    test('CONTROL: the same grants under an ordinary id are refused', () async {
      // The scope control for the fold. Identical spelling, identical
      // command; an ordinary enrollment id and ordinary grants. Without it
      // the case above would be satisfied by this key being unreachable only
      // to the connections that carry no id, leaving every enrollment able to
      // write it under a shifted spelling.
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
    // The ban sits at one seam, so what these pin is the CLAIM that every
    // route reaches that seam. Three of them are wire grammars this package
    // does not own, so a loosening in at_commons opens a route with nothing
    // in this repo changing — which is why the refused ones are pinned as
    // raw command literals rather than built from constants.

    test('update:json reaches the ban', () async {
      // The route the plain grammar's own value check does NOT cover:
      // `update:` demands a non-empty value, while update:json carries the
      // value inside the document and can therefore store a zero-length one.
      // A zero-length credential is not harmless — it is the state that makes
      // the atSign's flat key stop counting as a root it can fall back on —
      // so this route has to be refused by the ban and not merely by the
      // grammar.
      bindCram();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');

      // The metadata map is built through commons' own Metadata.toJson — the
      // shape every real client emits — so this is the request a client can
      // actually send rather than a hand-rolled document.
      final json = jsonEncode({
        'atKey': AtConstants.atPkamPublicKey,
        'value': '',
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

    test('CONTROL: update:json writes an ordinary key on this connection',
        () async {
      // Drawn from a route the ban does not touch, so it stays green under
      // any mutation of the ban. Without it the case above is equally
      // satisfied by update:json being broken, unroutable, or refused to a
      // CRAM connection for some reason having nothing to do with the key.
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
      // batch: writes nothing itself — it re-dispatches each element through
      // the element's own handler — so the ban is reached by the element
      // landing back at the update seam. Pinned because "the handler covers
      // it" is a claim about the dispatch, not about the handler.
      bindCram();
      await keyValueStore.put(
          AtConstants.atPkamPublicKey, AtData()..data = 'ORIGINAL_KEY');

      final batch = BatchVerbHandler(
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
      final response = await batch.processInternal(
          'batch:[{"id":1,"command":"update:privatekey:at_pkam_publickey '
          'NEW_KEY"}]',
          inboundConnection);

      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          'ORIGINAL_KEY',
          reason: 'wrapping the command in a batch must not get it past the '
              'refusal — batch re-dispatches to the same handler');
      expect(response.data, contains('"id":1'),
          reason: 'and the element is reported, not silently dropped');
    });

    test('update:meta cannot name the key at all', () async {
      // A NEGATIVE pin on a grammar this repo does not own. update:meta's
      // atKey class is colon-free, so `privatekey:...` cannot be expressed
      // in it — the key is unreachable by that verb rather than refused by
      // the ban. If at_commons ever widens that class the route opens with
      // nothing here changing, and this is what goes red.
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
      // The other half of "nothing can take it back", and the reason the
      // write is banned rather than merely audited: once installed there is
      // no verb that removes it. delete whitelists exactly one privatekey:
      // key, and it is not this one.
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

    // WHITESPACE ONLY, and the uppercase variant that used to sit here was
    // removed rather than kept. HiveKeyStoreHelper.prepareKey normalises with
    // trim().toLowerCase().replaceAll(' ',''), and only the trim and the strip
    // are load-bearing for THIS key: `_ownKeyMaterialRegex` is anchored, so a
    // stray space or tab defeats it and nothing but the fold puts the key
    // back. Case is decided twice over and so cannot be isolated — measured
    // both ways: with the fold removed the uppercase case stays green, because
    // the regex is built caseSensitive:false; with that flag set to true it
    // stays green as well, because the fold has already lowercased the key
    // before the regex sees it. A case that cannot fail for either of its
    // stated reasons is worse than none.
    for (final variant in [
      'public:publickey@alice ',
      ' public:publickey@alice',
      'public:publickey@alice\t',
    ]) {
      test('a non-root enrollment is denied ${jsonEncode(variant)}', () async {
        // A '*:rw' enrollment is not a root enrollment, and these variants all
        // address the record it must not reach.
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
