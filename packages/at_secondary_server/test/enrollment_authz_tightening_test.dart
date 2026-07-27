import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
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
/// Public keys remain reachable (they are world-readable), and an enrollment's
/// access to its OWN per-enrollment namespace is unchanged.
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
      expect(
          inboundConnection.lastWrittenData ?? '', isNot(contains('topsecret')));
    });

    test('*:rw enrollment CAN update its OWN a.__e key', () async {
      final enrollId = await bindWildcardEnrollment();
      final ownKey = '$alice:mine.$enrollId.a.__e$alice';

      await updateVerbHandler.process(
          'update:$ownKey myvalue', inboundConnection);
      expect(inboundConnection.lastWrittenData, contains('data:'),
          reason: 'own per-enrollment namespace access must be unaffected');
    });

    // ---- Q2: direct __manage access (enrollment record / PEK / SEK) ----

    test('*:rw-without-__manage enrollment cannot UPDATE a __manage key',
        () async {
      await bindWildcardEnrollment();
      final foreignEnId = Uuid().v4();
      // The encrypted default-encryption-private-key (PEK) of another enrollment.
      final pekKey =
          '$foreignEnId.default_enc_private_key.__manage$alice';

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
      final pekKey =
          '$foreignEnId.default_enc_private_key.__manage$alice';
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
