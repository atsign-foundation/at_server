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

import 'test_utils.dart';

/// Locks in the APKAM authorization tightening:
///   1. An enrollment (even one holding `*:rw`) must NOT reach another
///      enrollment's per-enrollment reserved namespace (`<otherId>.a|r|d.__e`),
///      which the `*` wildcard fallback previously granted.
///   2. A `*:rw` enrollment that does NOT hold `__manage` explicitly must NOT
///      reach `__manage` keys (enrollment records / PEK / SEK) via any generic
///      data verb — the `*` fallback previously laundered `__manage` into `*`
///      and bypassed the `__manage` guard.
///   3. A `public:` key in another enrollment's reserved namespace is
///      world-READABLE and is NOT world-writable. The published
///      `public:_apsk.<id>.a.__e@` signing key is what a verifier resolves, so
///      whoever can write it controls the algorithms and key ids the victim is
///      trusted under — forgery, not vandalism.
/// An enrollment's access to its OWN per-enrollment namespace is unchanged,
/// public or not.
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

    // ---- Q1: cross-enrollment per-enrollment (a.__e) data ----

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

    // ---- update:meta is a WRITE, and was refused to every enrollment ----

    /// Binds an approved enrollment holding exactly [namespaces].
    Future<String> bindEnrollment(Map<String, String> namespaces) async {
      inboundConnection.metadata.isAuthenticated = true;
      final enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
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
      inboundConnection.metadata.enrollmentId = null;
      await updateVerbHandler.process('update:$key hello', inboundConnection);
    }

    test('an enrollment holding rw on the namespace CAN update:meta',
        () async {
      // Issue #2691. `UpdateMeta` extends `Verb` rather than `Update` and was
      // in neither the read nor the write allow-list, so the namespace check
      // returned false for EVERY access level — `*:rw` included — and the
      // verb was refused to every enrollment. It went unnoticed because a
      // connection carrying no enrollment id skipped the check altogether,
      // which was every legacy and CRAM connection.
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
      // The control. Without it the test above would be satisfied by
      // "update:meta is allowed to everyone", which is the opposite defect
      // and just as wrong.
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

    // ---- Q1b: a PUBLIC key in a foreign per-enrollment namespace ----
    //
    // The only cross-enrollment denial short-circuited on the `public:` prefix
    // for EVERY verb, and its own comment justified that on read grounds. The
    // same predicate gated writes and deletes.

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
      // The control, and the half that must NOT change. The exemption exists
      // because the atServer publishes the signing key on the enrollee's
      // behalf for anyone to resolve; sync depends on it too. A fix that
      // simply removed the exemption would break reading.
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
      // The other control: the narrowing is about FOREIGN keys. An enrollment
      // publishing its own signing key must be unaffected, and a live
      // functional test depends on exactly this.
      final enrollId = await bindWildcardEnrollment();
      final ownKey = 'public:_apsk.$enrollId.a.__e$alice';

      await updateVerbHandler.process(
          'update:$ownKey mine', inboundConnection);
      expect(inboundConnection.lastWrittenData, contains('data:'));
    });

    // ---- Q2: direct __manage access (enrollment record / PEK / SEK) ----

    test('*:rw-without-__manage enrollment cannot UPDATE a __manage key',
        () async {
      await bindWildcardEnrollment();
      final foreignEnId = Uuid().v4();
      // The encrypted default-encryption-private-key (PEK) of another enrollment.
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
