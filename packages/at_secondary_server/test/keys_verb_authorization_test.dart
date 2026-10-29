import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/verb/handler/keys_verb_handler.dart';
import 'package:at_utils/at_logger.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

/// An enrollment scoped only to the `wavi` namespace (no `__manage`) can
/// neither read nor delete through `keys:` any key but its own two
/// encryption keys: not the raw CRAM secret, not a key in a namespace it was
/// never granted, and not a key whose value names its enrollmentId or
/// another's.
void main() {
  AtSignLogger.root_level = 'WARNING';

  group('keys verb authorization', () {
    late KeysVerbHandler keysVerbHandler;

    setUpAll(() async {
      await verbTestsSetUpAll();
    });

    setUp(() async {
      await verbTestsSetUp();
      keysVerbHandler = KeysVerbHandler(keyValueStore, enMgr, alice);
    });

    tearDown(() async {
      await verbTestsTearDown();
    });

    /// Registers an approved enrollment scoped ONLY to the `wavi` namespace
    /// (no `__manage`) and binds it to the connection.
    Future<void> setUpNarrowlyScopedApprovedEnrollment() async {
      inboundConnection.metadata.isAuthenticated = true;
      final enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'}, // narrow scope, NO __manage, NO '*'
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      await keyValueStore.put('$enrollId.new.enrollments.__manage$alice',
          AtData()..data = jsonEncode(enrollJson));
    }

    test('wavi-scoped app cannot read the CRAM secret', () async {
      await setUpNarrowlyScopedApprovedEnrollment();

      // The CRAM secret as planted at onboarding.
      const cramSecret = 'super-secret-cram-value';
      await keyValueStore.put(
          'privatekey:at_secret', AtData()..data = cramSecret);

      await expectLater(
          keysVerbHandler.process(
              'keys:get:keyName:privatekey:at_secret', inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason: 'wavi-scoped enrollment must not read the raw CRAM secret');
      expect(
          inboundConnection.lastWrittenData ?? '', isNot(contains(cramSecret)));
    });

    test('wavi-scoped app cannot read a foreign-namespace key', () async {
      await setUpNarrowlyScopedApprovedEnrollment();

      const foreignKey = '@alice:secret.buzz@alice';
      const foreignValue = 'buzz-namespace-private-data';
      await keyValueStore.put(foreignKey, AtData()..data = foreignValue);

      await expectLater(
          keysVerbHandler.process(
              'keys:get:keyName:$foreignKey', inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason: 'must not read a key outside the granted wavi namespace');
      expect(inboundConnection.lastWrittenData ?? '',
          isNot(contains(foreignValue)));
    });

    test('wavi-scoped app cannot delete an arbitrary key', () async {
      await setUpNarrowlyScopedApprovedEnrollment();

      const victimKey = '@alice:important.buzz@alice';
      await keyValueStore.put(victimKey, AtData()..data = 'do-not-delete');

      await expectLater(
          keysVerbHandler.process(
              'keys:delete:keyName:$victimKey', inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason: 'must not delete a key outside the granted namespace');
      expect(await keyValueStore.exists(victimKey), isTrue);
    });

    test('cannot read a key whose value names its own enrollmentId',
        () async {
      await setUpNarrowlyScopedApprovedEnrollment();
      final enId = inboundConnection.metadata.enrollmentId!;

      const ownKey = 'public:encryption_self.__public_keys.__global@alice';
      final ownValue = jsonEncode({
        'value': 'my-own-public-key',
        'keyType': 'rsa2048',
        AtConstants.enrollmentId: enId,
      });
      await keyValueStore.put(ownKey, AtData()..data = ownValue);

      await expectLater(
          keysVerbHandler.process(
              'keys:get:keyName:$ownKey', inboundConnection),
          throwsA(isA<UnAuthorizedException>()));
      expect(inboundConnection.lastWrittenData ?? '',
          isNot(contains('my-own-public-key')));
    });

    test('cannot READ a keys-verb key tagged with another enrollmentId',
        () async {
      await setUpNarrowlyScopedApprovedEnrollment();

      final foreignEnId = Uuid().v4();
      const foreignKey = 'public:encryption_self.__public_keys.__global@alice';
      final foreignValue = jsonEncode({
        'value': 'another-enrollments-key-material',
        'keyType': 'rsa2048',
        AtConstants.enrollmentId: foreignEnId,
      });
      await keyValueStore.put(foreignKey, AtData()..data = foreignValue);

      await expectLater(
          keysVerbHandler.process(
              'keys:get:keyName:$foreignKey', inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason: 'must not read a keys-verb key owned by another enrollment');
      expect(inboundConnection.lastWrittenData ?? '',
          isNot(contains('another-enrollments-key-material')));
    });

    test('cannot DELETE a keys-verb key tagged with another enrollmentId',
        () async {
      await setUpNarrowlyScopedApprovedEnrollment();

      final foreignEnId = Uuid().v4();
      const foreignKey = 'public:encryption_self.__public_keys.__global@alice';
      await keyValueStore.put(
          foreignKey,
          AtData()
            ..data = jsonEncode({
              'value': 'do-not-delete',
              AtConstants.enrollmentId: foreignEnId,
            }));

      await expectLater(
          keysVerbHandler.process(
              'keys:delete:keyName:$foreignKey', inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason:
              'must not delete a keys-verb key owned by another enrollment');
      expect(await keyValueStore.exists(foreignKey), isTrue);
    });
  });
}
