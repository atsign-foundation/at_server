import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_meta_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_utils/at_logger.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;

import 'test_utils.dart';

/// Pins the limits of an enrollment's authorization, all of which a `*:rw`
/// grant must not escape. An enrollment cannot reach another enrollment's
/// per-enrollment reserved namespace (`<otherId>.a|r|d.__e`); a `*:rw`
/// enrollment not holding `__manage` explicitly cannot reach `__manage`
/// keys (enrollment records, PEK, SEK) through a generic data verb; and a
/// `public:` key in a foreign reserved namespace is world-readable but not
/// world-writable, because the published `public:_apsk.<id>.a.__e@` signing
/// key is what a verifier resolves, so writing it forges the key ids the
/// victim is trusted under. Access to an enrollment's OWN per-enrollment
/// namespace, public or not, is untouched.
void main() {
  AtSignLogger.root_level = 'WARNING';

  group('APKAM authorization tightening', () {
    late UpdateVerbHandler updateVerbHandler;
    late LocalLookupVerbHandler localLookupVerbHandler;
    late DeleteVerbHandler deleteVerbHandler;

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
    });

    tearDown(() async {
      await verbTestsTearDown();
    });

    /// Binds an approved `*:rw` enrollment (NO `__manage`) to the connection
    /// and returns its enrollmentId.
    Future<String> bindWildcardEnrollment() async {
      inboundConnection.metadata.isAuthenticated = true;
      final enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      inboundConnection.metadata.authType = AuthType.apkam;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'*': 'rw'}, // wildcard, but NO __manage
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      await keyValueStore.put('$enrollId.new.enrollments.__manage$alice',
          AtData()..data = jsonEncode(enrollJson));
      return enrollId;
    }

    // ---- cross-enrollment per-enrollment (a.__e) data ----

    test('*:rw enrollment cannot UPDATE another enrollment\'s a.__e key',
        () async {
      await bindWildcardEnrollment();
      final foreignEnId = Uuid().v4();
      final foreignKey = '$alice:secret.$foreignEnId.a.__e$alice';

      await expectLater(
          updateVerbHandler.process(
              'update:$foreignKey topsecret', inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason:
              'a *:rw enrollment must not write another enrollment\'s a.__e');
    });

    test('*:rw enrollment cannot LLOOKUP another enrollment\'s a.__e key',
        () async {
      await bindWildcardEnrollment();
      final foreignEnId = Uuid().v4();
      final foreignKey = '$alice:secret.$foreignEnId.a.__e$alice';
      await keyValueStore.put(foreignKey, AtData()..data = 'topsecret');

      await expectLater(
          localLookupVerbHandler.process(
              'llookup:$foreignKey', inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason:
              'a *:rw enrollment must not read another enrollment\'s a.__e');
      expect(inboundConnection.lastWrittenData ?? '',
          isNot(contains('topsecret')));
    });

    // ---- update:meta is a WRITE, gated per namespace ----

    /// Binds an approved enrollment holding exactly [namespaces].
    Future<String> bindEnrollment(Map<String, String> namespaces) async {
      inboundConnection.metadata.isAuthenticated = true;
      final enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      inboundConnection.metadata.authType = AuthType.apkam;
      await keyValueStore.put(
          '$enrollId.new.enrollments.__manage$alice',
          AtData()
            ..data = jsonEncode({
              'sessionId': '123',
              'appName': 'wavi',
              'deviceName': 'pixel',
              'namespaces': namespaces,
              'apkamPublicKey': 'testPublicKeyValue',
              'requestType': 'newEnrollment',
              'approval': {'state': 'approved'}
            }));
      return enrollId;
    }

    /// Writes the key as the OWNER, so the update:meta below is the only act
    /// under test.
    Future<void> seedAsOwner(String key) async {
      inboundConnection.metadata.isAuthenticated = true;
      inboundConnection.metadata.authType = AuthType.cram;
      inboundConnection.metadata.enrollmentId = null;
      await updateVerbHandler.process('update:$key hello', inboundConnection);
    }

    test('an enrollment holding rw on the namespace CAN update:meta',
        () async {
      // `UpdateMeta` extends `Verb` rather than `Update`, so it has to be
      // in the write allow-list explicitly or the namespace check refuses
      // it at every access level. A connection carrying no enrollment id
      // skips the check, so only enrollments notice.
      final key = '@bob:phone.wavi$alice';
      await seedAsOwner(key);
      await bindEnrollment({'wavi': 'rw'});

      final h = UpdateMetaVerbHandler(
          keyValueStore, statsNotificationService, notificationManager, alice);
      await h.process('update:meta:$key:ttl:60000', inboundConnection);

      expect((await keyValueStore.getMeta(key))?.ttl, 60000,
          reason: 'a metadata write is a write, and this enrollment holds rw '
              'on the namespace — it may already `update` the same key');
    });

    test('...and one holding only r on it may NOT', () async {
      // The control: without it the test above is satisfied by
      // "update:meta is allowed to everyone", the opposite defect.
      final key = '@bob:phone.wavi$alice';
      await seedAsOwner(key);
      await bindEnrollment({'wavi': 'r'});

      final h = UpdateMetaVerbHandler(
          keyValueStore, statsNotificationService, notificationManager, alice);
      await expectLater(
          h.process('update:meta:$key:ttl:60000', inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason: 'read access must not carry a metadata write');
      expect((await keyValueStore.getMeta(key))?.ttl, isNot(60000),
          reason: 'and nothing was written');
    });

    test('...nor one holding rw on a DIFFERENT namespace', () async {
      final key = '@bob:phone.wavi$alice';
      await seedAsOwner(key);
      await bindEnrollment({'buzz': 'rw'});

      final h = UpdateMetaVerbHandler(
          keyValueStore, statsNotificationService, notificationManager, alice);
      await expectLater(
          h.process('update:meta:$key:ttl:60000', inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason: 'the gate is per-namespace, exactly as it is for `update`');
    });

    test('*:rw enrollment CAN update its OWN a.__e key', () async {
      final enrollId = await bindWildcardEnrollment();
      final ownKey = '$alice:mine.$enrollId.a.__e$alice';

      await updateVerbHandler.process(
          'update:$ownKey myvalue', inboundConnection);
      expect(inboundConnection.lastWrittenData, contains('data:'),
          reason: 'own per-enrollment namespace access must be unaffected');
    });

    // ---- a PUBLIC key in a foreign per-enrollment namespace ----
    //
    // One predicate gates reads, writes and deletes, so the `public:`
    // exemption has to distinguish them: readable, not writable.

    test('*:rw enrollment cannot UPDATE another enrollment\'s PUBLIC a.__e key',
        () async {
      await bindWildcardEnrollment();
      final foreignEnId = Uuid().v4();
      final foreignKey = 'public:_apsk.$foreignEnId.a.__e$alice';

      await expectLater(
          updateVerbHandler.process(
              'update:$foreignKey forged', inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason: 'world-readable is not world-writable: whoever writes a '
              'published _apsk chooses the key ids a verifier trusts for that '
              'enrollment');
    });

    test('*:rw enrollment cannot DELETE another enrollment\'s PUBLIC a.__e key',
        () async {
      await bindWildcardEnrollment();
      final foreignEnId = Uuid().v4();
      final foreignKey = 'public:_apsk.$foreignEnId.a.__e$alice';
      await keyValueStore.put(foreignKey, AtData()..data = 'thevictimskey');

      await expectLater(
          deleteVerbHandler.process('delete:$foreignKey', inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason: 'withdrawing a signing key unverifies everything it signed, '
              'and needs no key material at all to attempt');
      expect(await keyValueStore.get(foreignKey), isNotNull,
          reason: 'and the record is still there');
    });

    test('*:rw enrollment CAN still LLOOKUP a foreign PUBLIC a.__e key',
        () async {
      // The control, and the half that must not change: the atServer
      // publishes the signing key for anyone to resolve, and sync reads it
      // too, so dropping the exemption outright would break reading.
      await bindWildcardEnrollment();
      final foreignEnId = Uuid().v4();
      final foreignKey = 'public:_apsk.$foreignEnId.a.__e$alice';
      await keyValueStore.put(foreignKey, AtData()..data = 'thevictimskey');

      await localLookupVerbHandler.process(
          'llookup:$foreignKey', inboundConnection);
      expect(inboundConnection.lastWrittenData ?? '',
          contains('thevictimskey'),
          reason: 'a published signing key stays world-readable');
    });

    test('an enrollment CAN still update its OWN public a.__e key', () async {
      // The other control: the denial is about FOREIGN keys, so an
      // enrollment publishing its own signing key must be unaffected.
      final enrollId = await bindWildcardEnrollment();
      final ownKey = 'public:_apsk.$enrollId.a.__e$alice';

      await updateVerbHandler.process(
          'update:$ownKey mine', inboundConnection);
      expect(inboundConnection.lastWrittenData, contains('data:'));
    });

    // ---- direct __manage access (enrollment record / PEK / SEK) ----

    test('*:rw-without-__manage enrollment cannot UPDATE a __manage key',
        () async {
      await bindWildcardEnrollment();
      final foreignEnId = Uuid().v4();
      // Another enrollment's encrypted default encryption private key.
      final pekKey = '$foreignEnId.default_enc_private_key.__manage$alice';

      await expectLater(
          updateVerbHandler.process(
              'update:$pekKey tampered', inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason: '*:rw without __manage must not write __manage key material');
    });

    test('*:rw-without-__manage enrollment cannot DELETE a __manage key',
        () async {
      await bindWildcardEnrollment();
      final foreignEnId = Uuid().v4();
      final pekKey = '$foreignEnId.default_enc_private_key.__manage$alice';
      await keyValueStore.put(pekKey, AtData()..data = 'ciphertext');

      await expectLater(
          deleteVerbHandler.process('delete:$pekKey', inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason:
              '*:rw without __manage must not delete __manage key material');
      expect(await keyValueStore.exists(pekKey), isTrue);
    });

    test('*:rw-without-__manage enrollment cannot LLOOKUP a __manage key',
        () async {
      await bindWildcardEnrollment();
      final foreignEnId = Uuid().v4();
      final recordKey = '$foreignEnId.new.enrollments.__manage$alice';
      await keyValueStore.put(
          recordKey, AtData()..data = jsonEncode({'appName': 'other'}));

      await expectLater(
          localLookupVerbHandler.process(
              'llookup:$recordKey', inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason: '*:rw without __manage must not read __manage keys');
    });
  });
}
