import 'dart:collection';
import 'dart:convert';

import 'package:at_chops/at_chops.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/otp_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'enrollment_test_utils.dart';
import 'test_utils.dart';

InboundConnectionMetadata castMetadata(InboundConnection ic) {
  return inboundConnection.metaData;
}

/// Utility functions supporting the "Per-enrollment data" and "Enrollments
/// datastore consistency" groups are in enrollment_test_utils.dart; the
/// general full-stack verb test helpers are in test_utils.dart.
void main() {
  verbTestsSetUpLogging();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  group('Per-enrollment data', () {
    final etu = ETU();
    setUp(() async {
      await verbTestsSetUp();
      await etu.init();
    });

    tearDown(() async {
      await verbTestsTearDown();
    });

    test('Test that an enrollment can update its reserved namespace', () async {
      final String enrollmentId = (await etu.createEnrollments(n: 1)).$1.first;

      inboundConnection.metadata.isAuthenticated = true;
      inboundConnection.metadata.enrollmentId = enrollmentId;
      inboundConnection.metadata.authType = AuthType.apkam;

      final String key = 'some_key'
          '.${AbstractVerbHandler.enrollmentReservedNamespace(enrollmentId)}'
          '$alice';

      final Response updateResponse = Response();
      await etu.uvh.processVerb(
          updateResponse,
          getVerbParam(VerbSyntax.update, 'update:$alice:$key private value'),
          inboundConnection);
      expect(updateResponse.data, isNotNull);
      expect(updateResponse.isError, false);

      final selfLookupResponse = Response();
      await etu.lvh.processVerb(
        selfLookupResponse,
        getVerbParam(VerbSyntax.lookup, 'lookup:$key'),
        inboundConnection,
      );
      expect(selfLookupResponse.data, 'private value');

      await expectLater(
          etu.lvh.processVerb(
            Response(),
            getVerbParam(VerbSyntax.lookup, 'lookup:$key'),
            DummyInboundConnection(),
          ),
          throwsA(predicate((dynamic e) => e is KeyNotFoundException)));
      await expectLater(
          etu.lvh.processVerb(
            Response(),
            getVerbParam(VerbSyntax.lookup, 'lookup:$alice:$key'),
            DummyInboundConnection(),
          ),
          throwsA(predicate((dynamic e) => e is KeyNotFoundException)));
    });

    test(
        'Test that an enrollment may not update another enrollment reserved namespace',
        () async {
      final List<String> enIds = (await etu.createEnrollments(n: 2)).$1;
      final String enId1 = enIds[0];
      final String enId2 = enIds[1];

      inboundConnection.metadata.isAuthenticated = true;
      inboundConnection.metadata.enrollmentId = enId1;
      inboundConnection.metadata.authType = AuthType.apkam;

      final String key = 'public:some_public_key'
          '.${AbstractVerbHandler.enrollmentReservedNamespace(enId2)}'
          '$alice';
      await expectLater(
          etu.uvh.processVerb(
              Response(),
              getVerbParam(VerbSyntax.update, 'update:$key some value'),
              inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is UnAuthorizedException &&
              e.message == etu.uvh.apkamUnauthorizedMsg(enId1, key))));
    });

    test(
        'Test that anyone may look up a public key in an enrollment reserved namespace',
        () async {
      final String enrollmentId = (await etu.createEnrollments(n: 1)).$1.first;
      inboundConnection.metadata.isAuthenticated = true;
      inboundConnection.metadata.enrollmentId = enrollmentId;
      inboundConnection.metadata.authType = AuthType.apkam;

      String key = 'something_public'
          '.${AbstractVerbHandler.enrollmentReservedNamespace(enrollmentId)}'
          '$alice';
      final updateResponse = Response();
      await etu.uvh.processVerb(
          updateResponse,
          getVerbParam(
              VerbSyntax.update, 'update:public:$key some public value'),
          inboundConnection);
      expect(updateResponse.data, isNotNull);
      expect(updateResponse.isError, false);

      final lookupResponse = Response();
      await etu.lvh.processVerb(
        lookupResponse,
        getVerbParam(VerbSyntax.lookup, 'lookup:$key'),
        DummyInboundConnection(),
      );
      expect(lookupResponse.data, 'some public value');
    });

    test('Test per-enrollment data cleanup on enrollment expiry', () async {
      final int ttl = 250;
      String enId =
          (await etu.createEnrollments(n: 1, m: 1, ttl: ttl)).$1.first;
      var (keys, values) = await etu.createSomePerEnrollmentData(enId);
      for (final k in keys) {
        expect(await keyValueStore.exists(k), true);
      }
      await Future.delayed(Duration(milliseconds: ttl + 1));
      await keyValueStore.deleteExpiredKeys();

      for (final k in keys) {
        expect(await keyValueStore.exists(k), false);
      }

      for (final k in keys.map((k) => k.replaceAll(
          '${EnrollmentConstants.perEnrollmentApproved}@',
          '${EnrollmentConstants.perEnrollmentDeleted}@'))) {
        expect(await keyValueStore.exists(k), true);
      }
    }, timeout: Timeout(Duration(minutes: 5)));

    test('Test per-enrollment data cleanup on enrollment delete', () async {
      String enId = (await etu.createEnrollments(n: 1)).$1.first;
      var (keys, values) = await etu.createSomePerEnrollmentData(enId);
      for (final k in keys) {
        expect(await keyValueStore.exists(k), true);
      }
      await enMgr.remove(enId: enId);

      for (final k in keys) {
        expect(await keyValueStore.exists(k), false);
      }

      for (final k in keys.map((k) => k.replaceAll(
          '${EnrollmentConstants.perEnrollmentApproved}@',
          '${EnrollmentConstants.perEnrollmentDeleted}@'))) {
        expect(await keyValueStore.exists(k), true);
      }
    });

    test('Test per-enrollment data cleanup on enrollment revoke', () async {
      String enId = (await etu.createEnrollments(n: 1)).$1.first;
      var (keys, values) = await etu.createSomePerEnrollmentData(enId);
      for (final k in keys) {
        expect(await keyValueStore.exists(k), true);
      }
      await etu.revokeEnrollment(etu.primaryEnId, enId);

      for (final k in keys) {
        expect(await keyValueStore.exists(k), false);
      }

      for (final k in keys.map((k) => k.replaceAll(
          '${EnrollmentConstants.perEnrollmentApproved}@',
          '${EnrollmentConstants.perEnrollmentRevoked}@'))) {
        expect(await keyValueStore.exists(k), true);
      }
    });

    test('Test per-enrollment data cleanup on enrollment unrevoke', () async {
      String enId = (await etu.createEnrollments(n: 1)).$1.first;
      var (keys, values) = await etu.createSomePerEnrollmentData(enId);
      for (final k in keys) {
        expect(await keyValueStore.exists(k), true);
      }
      await etu.revokeEnrollment(etu.primaryEnId, enId);

      for (final k in keys.map((k) => k.replaceAll(
          '${EnrollmentConstants.perEnrollmentApproved}@',
          '${EnrollmentConstants.perEnrollmentRevoked}@'))) {
        expect(await keyValueStore.exists(k), true);
      }

      await etu.unrevokeEnrollment(etu.primaryEnId, enId);

      for (final k in keys) {
        expect(await keyValueStore.exists(k), true);
      }
    });

    test('Test per-enrollment data cleanup on delete of revoked', () async {
      String enId = (await etu.createEnrollments(n: 1)).$1.first;
      var (keys, values) = await etu.createSomePerEnrollmentData(enId);
      for (final k in keys) {
        expect(await keyValueStore.exists(k), true);
      }
      await etu.revokeEnrollment(etu.primaryEnId, enId);

      for (final k in keys.map((k) => k.replaceAll(
          '${EnrollmentConstants.perEnrollmentApproved}@',
          '${EnrollmentConstants.perEnrollmentRevoked}@'))) {
        expect(await keyValueStore.exists(k), true);
      }

      await etu.deleteEnrollment(etu.primaryEnId, enId);

      for (final k in keys.map((k) => k.replaceAll(
          '${EnrollmentConstants.perEnrollmentApproved}@',
          '${EnrollmentConstants.perEnrollmentDeleted}@'))) {
        expect(await keyValueStore.exists(k), true);
      }
    });

    test(
        'Test that a state change on one enrollment does not move another '
        'enrollment\'s per-enrollment data', () async {
      final List<String> enIds = (await etu.createEnrollments(n: 2)).$1;
      final String enId1 = enIds[0];
      final String enId2 = enIds[1];
      final (keys1, _) = await etu.createSomePerEnrollmentData(enId1);
      final (keys2, _) = await etu.createSomePerEnrollmentData(enId2);

      await etu.revokeEnrollment(etu.primaryEnId, enId1);

      for (final k in keys1) {
        expect(await keyValueStore.exists(k), false);
      }
      for (final k in keys1.map((k) => k.replaceAll(
          '${EnrollmentConstants.perEnrollmentApproved}@',
          '${EnrollmentConstants.perEnrollmentRevoked}@'))) {
        expect(await keyValueStore.exists(k), true);
      }

      for (final k in keys2) {
        expect(await keyValueStore.exists(k), true);
      }
      for (final k in keys2.map((k) => k.replaceAll(
          '${EnrollmentConstants.perEnrollmentApproved}@',
          '${EnrollmentConstants.perEnrollmentRevoked}@'))) {
        expect(await keyValueStore.exists(k), false);
      }
    });

    // Observe per-enrollment data directly in the keystore.
    Future<void> verifyKeysExist(List<String> keys, List<String> values) async {
      for (int i = 0; i < keys.length; i++) {
        final atData = await keyValueStore.get(keys[i]);
        expect(atData?.data, values[i]);
      }
    }

    Future<void> verifyKeysGone(List<String> keys) async {
      for (final k in keys) {
        expect(await keyValueStore.exists(k), false);
      }
    }

    test('Test lookup per-enrollment data of expired', () async {
      final int ttl = 150;
      String enId =
          (await etu.createEnrollments(n: 1, m: 1, ttl: ttl)).$1.first;

      var (keys, values) = await etu.createSomePerEnrollmentData(enId);

      await verifyKeysExist(keys, values);

      await Future.delayed(Duration(milliseconds: ttl + 1));
      await keyValueStore.deleteExpiredKeys();

      await verifyKeysGone(keys);

      await verifyKeysExist(
          keys
              .map((s) => s.replaceFirst(
                  '${EnrollmentConstants.perEnrollmentApproved}@',
                  '${EnrollmentConstants.perEnrollmentDeleted}@'))
              .toList(),
          values);
    });

    test('Test lookup per-enrollment data of revoked', () async {
      String enId = (await etu.createEnrollments(n: 1)).$1.first;

      var (keys, values) = await etu.createSomePerEnrollmentData(enId);

      await verifyKeysExist(keys, values);

      await etu.revokeEnrollment(etu.primaryEnId, enId);

      await verifyKeysGone(keys);

      await verifyKeysExist(
          keys
              .map((s) => s.replaceFirst(
                  '${EnrollmentConstants.perEnrollmentApproved}@',
                  '${EnrollmentConstants.perEnrollmentRevoked}@'))
              .toList(),
          values);
    });

    test('Test lookup per-enrollment data of deleted', () async {
      String enId = (await etu.createEnrollments(n: 1)).$1.first;

      var (keys, values) = await etu.createSomePerEnrollmentData(enId);

      await verifyKeysExist(keys, values);

      // Revoke first: only denied and revoked enrollments may be deleted.
      await etu.revokeEnrollment(etu.primaryEnId, enId);
      await etu.deleteEnrollment(etu.primaryEnId, enId);

      await verifyKeysGone(keys);

      await verifyKeysExist(
          keys
              .map((s) => s.replaceFirst(
                  '${EnrollmentConstants.perEnrollmentApproved}@',
                  '${EnrollmentConstants.perEnrollmentDeleted}@'))
              .toList(),
          values);
    });
  });

  group('Enrollments datastore consistency', () {
    final etu = ETU();
    setUp(() async {
      await verbTestsSetUp();
      await etu.init();
    });

    tearDown(() async {
      await verbTestsTearDown();
    });

    test('Verify that only orphaned enrollment related keys are cleaned up',
        () async {
      final int ttl = 60000;
      final List<String> allEnIds;
      final List<String> withTtlEnIds;
      final List<String> deletedEnIds = [];

      (allEnIds, withTtlEnIds) =
          await etu.createEnrollments(n: 20, m: 3, ttl: ttl);
      expect(withTtlEnIds.length, 6);

      await etu.verifyKeyStoreState(allEnIds, deletedEnIds, cleanedUp: false);

      keyValueStore.preRemoveHooks.remove(enMgr.preRemoveHook);
      int i = 0;
      for (final enId in allEnIds) {
        if (++i % 3 == 0) {
          await keyValueStore.remove(enMgr.buildEnrollmentKey(enId));
          deletedEnIds.add(enId);
        }
      }

      await etu.verifyKeyStoreState(allEnIds, deletedEnIds, cleanedUp: false);

      List<String> removedOrphans =
          await enMgr.removeOrphanedApkamEncryptionKeys();
      expect(removedOrphans.length, deletedEnIds.length * 2);
      for (final enId in deletedEnIds) {
        expect(removedOrphans.contains(enMgr.keyForPEK(enId)), true);
        expect(removedOrphans.contains(enMgr.keyForSEK(enId)), true);
      }

      await etu.verifyKeyStoreState(allEnIds, deletedEnIds, cleanedUp: true);
    });

    test(
        'Verify that all related keys are cleaned up by the normal expired keys job when enrollments expire',
        () async {
      int ttl = 100;
      List<String> allEnIds;
      List<String> withTtlEnIds;
      (allEnIds, withTtlEnIds) =
          await etu.createEnrollments(n: 20, m: 3, ttl: ttl);

      expect(allEnIds.length, 20);
      expect(withTtlEnIds.length, 6);

      await etu.verifyKeyStoreState(allEnIds, [], cleanedUp: false);

      await Future.delayed(Duration(milliseconds: ttl + 1));

      await etu.verifyKeyStoreState(allEnIds, [], cleanedUp: false);

      await keyValueStore.deleteExpiredKeys();

      await etu.verifyKeyStoreState(allEnIds, withTtlEnIds, cleanedUp: true);
    });

    test(
        'Fetching an expired enrollment REPORTS it expired and removes nothing',
        () async {
      int ttl = 100;
      List<String> allEnIds;
      List<String> withTtlEnIds;
      (allEnIds, withTtlEnIds) =
          await etu.createEnrollments(n: 5, m: 2, ttl: ttl);
      expect(allEnIds.length, 5);
      expect(withTtlEnIds.length, 2);

      await etu.verifyKeyStoreState(allEnIds, [], cleanedUp: false);

      Map m1 = await enMgr.getEnrollmentsAsJson(redactSecrets: false);
      expect(m1.length, allEnIds.length + 1);
      m1.remove(enMgr.buildEnrollmentKey(etu.primaryEnId));
      expect(m1.length, allEnIds.length);

      await Future.delayed(Duration(milliseconds: ttl + 1));

      final expiryCache =
          (keyValueStore as HiveAtKeyValueStore).getExpiryKeysCache();
      for (final enId in withTtlEnIds) {
        expect(expiryCache.containsKey(enMgr.buildEnrollmentKey(enId)), true);
      }
      for (final enId in allEnIds) {
        if (!withTtlEnIds.contains(enId)) {
          expect(
              expiryCache.containsKey(enMgr.buildEnrollmentKey(enId)), false);
        }
      }

      await etu.verifyKeyStoreState(allEnIds, [], cleanedUp: false);

      final int writesBefore = EnrollmentManager.cacheInvalidations;
      Map m = await enMgr.getEnrollmentsAsJson(
          redactSecrets: false,
          ekList:
              allEnIds.map((enId) => enMgr.buildEnrollmentKey(enId)).toList());
      expect(m.length, allEnIds.length);

      int expiredEncountered = 0;
      for (final entry in m.entries) {
        if (entry.value['status'] == EnrollmentStatus.expired.name) {
          expiredEncountered++;
          expect(withTtlEnIds, contains(enMgr.getIdFromKey(entry.key)));
        }
      }
      expect(expiredEncountered, withTtlEnIds.length,
          reason: 'the read still REPORTS the expiry — that is what callers '
              'decide on, and it is why not removing costs them nothing');

      expect(EnrollmentManager.cacheInvalidations, writesBefore,
          reason: 'every enrollment write bumps this counter, and a read of '
              'five enrollments — two of them expired — must not bump it at '
              'all');
      await etu.verifyKeyStoreState(allEnIds, [], cleanedUp: false);

      await keyValueStore.deleteExpiredKeys();
      await etu.verifyKeyStoreState(allEnIds, withTtlEnIds, cleanedUp: true);
    });
  });

  group('A group of tests to verify enroll request operation', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test('A test to verify enroll requests get different enrollment ids',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId_1 = jsonDecode(response.data!)['enrollmentId'];
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      enrollmentRequest =
          'enroll:request:{"appName":"wavi1","deviceName":"mydevice1"'
          ',"namespaces":{"buzz":"r"},"otp":"${response.data}"'
          ',"apkamPublicKey":"lorem_apkam"'
          ',"encryptedAPKAMSymmetricKey":"ipsum_apkam"}';
      enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId_2 = jsonDecode(response.data!)['enrollmentId'];

      expect(enrollmentId_1, isNotEmpty);
      expect(enrollmentId_2, isNotEmpty);
      expect(enrollmentId_1 == enrollmentId_2, false);
    });

    test('Should not reject CRAM-authenticated initial enrollment as duplicate',
        () async {
      HashMap<String, String?> verbParamsFor(String apkamPublicKey) =>
          getVerbParam(
              VerbSyntax.enroll,
              'enroll:request:{"appName":"firstApp","deviceName":"firstDevice"'
              ',"namespaces":{"*":"rw"}'
              ',"apkamPublicKey":"$apkamPublicKey"'
              ',"encryptedAPKAMSymmetricKey":"ipsum_apkam"}');
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);

      Response response;
      response = Response();
      await enrollVerbHandler.processVerb(
          response, verbParamsFor('lorem_apkam_first'), inboundConnection);
      String firstEnrollmentId = jsonDecode(response.data!)['enrollmentId'];

      response = Response();
      await enrollVerbHandler.processVerb(
          response, verbParamsFor('lorem_apkam_second'), inboundConnection);
      String secondEnrollmentId = jsonDecode(response.data!)['enrollmentId'];

      expect(secondEnrollmentId == firstEnrollmentId, false);
    });
    test(
        'A test to verify enrollment of CRAM auth connection have __manage and * namespaces added to enrollment value',
        () async {
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice"'
          ',"namespaces":{"wavi":"r"}'
          ',"apkamPublicKey":"lorem_apkam"'
          ',"encryptedAPKAMSymmetricKey":"ipsum_apkam"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      String enrollmentKey =
          '$enrollmentId.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice';
      var enrollmentValue = await EnrollmentManager(keyValueStore, alice)
          .getEnrollmentByFullKey(enrollmentKey);
      expect(enrollmentValue.namespaces.containsKey('__manage'), true);
      expect(enrollmentValue.namespaces.containsKey('*'), true);
    });

    test(
        'A test to verify OTP is deleted once it is used to submit an enrollment',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      String otp = response.data!;

      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice"'
          ',"namespaces":{"buzz":"r"},"otp":"$otp"'
          ',"apkamPublicKey":"lorem_apkam"'
          ',"encryptedAPKAMSymmetricKey": "ipsum_apkam"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      expect(enrollmentId, isNotNull);
      expect(await enrollVerbHandler.isPasscodeValid(otp), false);
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests to verify enroll list operation', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test('A test to verify enrollment list with cram auth', () async {
      String pk = 'dummy_apkam_public_key';
      String sk = 'dummy_encrypted_apkam_key';
      Map erPayload = {
        'appName': 'wavi',
        'deviceName': 'mydevice',
        'namespaces': {'wavi': 'r'},
        'apkamPublicKey': pk,
        'encryptedAPKAMSymmetricKey': sk,
      };
      String er = 'enroll:request:${jsonEncode(erPayload)}';
      HashMap<String, String?> verbParams = getVerbParam(VerbSyntax.enroll, er);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];

      String enrollmentList = 'enroll:list';
      verbParams = getVerbParam(VerbSyntax.enroll, enrollmentList);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      var responseMap = jsonDecode(response.data!);
      expect(response.data?.contains(enrollmentId), true);
      final enrollmentKey = enMgr.buildEnrollmentKey(enrollmentId);
      var e = responseMap[enrollmentKey];
      expect(e['appName'], 'wavi');
      expect(e['deviceName'], 'mydevice');
      expect(e['namespace']['wavi'], 'r');
      expect(e['status'], EnrollmentStatus.approved.name);
    });

    test('A test to verify enrollment list with enrollmentId is populated',
        () async {
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];

      String enrollmentList = 'enroll:list';
      castMetadata(inboundConnection).enrollmentId = enrollmentId;
      castMetadata(inboundConnection).authType = AuthType.apkam;
      verbParams = getVerbParam(VerbSyntax.enroll, enrollmentList);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      expect(response.data?.contains(enrollmentId), true);
    });

    test(
        'A test to verify enrollment list without __manage namespace returns enrollment info of given enrollmentId',
        () async {
      Response response = Response();
      inboundConnection.metaData.sessionID = 'dummy_session';
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentIdOne = jsonDecode(response.data!)['enrollmentId'];
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      enrollmentRequest =
          'enroll:request:{"appName":"buzz","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"${response.data}","apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}","encryptedAPKAMSymmetricKey":"default_apkam_symmetric_key"}';
      enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      String approveEnrollment =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey": "dummy_encrypted_default_encryption_private_key","encryptedDefaultSelfEncryptionKey":"dummy_encrypted_default_self_encryption_key"}';
      HashMap<String, String?> approveEnrollmentVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollment);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, approveEnrollmentVerbParams, inboundConnection);
      String enrollmentList = 'enroll:list';
      castMetadata(inboundConnection).enrollmentId = enrollmentId;
      castMetadata(inboundConnection).authType = AuthType.apkam;
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentList);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      Map<String, dynamic> enrollListResponse = jsonDecode(response.data!);
      var responseTest = enrollListResponse[
          '$enrollmentId.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice'];
      expect(responseTest['appName'], 'buzz');
      expect(responseTest['deviceName'], 'mydevice');
      expect(responseTest['namespace']['wavi'], 'r');
      expect(responseTest['encryptedAPKAMSymmetricKey'],
          'default_apkam_symmetric_key');
      expect(
          enrollListResponse.containsKey(
              '$enrollmentIdOne.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice'),
          false);
    });

    test('fetch filtered enrollment requests using approval status', () async {
      EnrollVerbHandler enrollVerb =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      inboundConnection.metadata.isAuthenticated = true;
      inboundConnection.metadata.authType = AuthType.cram;
      EnrollDataStoreValue enrollValue =
          EnrollDataStoreValue('abcd', 'unit_test_enroll', 'testDevice', 'aPK')
            ..namespaces = {"unit_tst": "rw"}
            ..encryptedAPKAMSymmetricKey = 'anSK';
      List<String> approvalStatuses = [
        EnrollmentStatus.approved.name,
        EnrollmentStatus.pending.name,
        EnrollmentStatus.pending.name,
        EnrollmentStatus.revoked.name,
        EnrollmentStatus.revoked.name,
        EnrollmentStatus.revoked.name,
        EnrollmentStatus.denied.name,
        EnrollmentStatus.denied.name,
        EnrollmentStatus.denied.name,
        EnrollmentStatus.denied.name,
      ];

      List<String> enrollmentKeys = [];
      Map<String, String> enrollmentStatuses = {};
      Map<String, EnrollDataStoreValue> enrollmentData = {};
      for (int i = 0; i < 10; i++) {
        String enrollmentId = Uuid().v4();
        String enrollmentKey =
            '$enrollmentId.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice';
        enrollValue.approval = EnrollApproval(approvalStatuses[i]);
        enrollmentData[enrollmentKey] = enrollValue;

        enrollmentKeys.add(enrollmentKey);
        enrollmentStatuses[enrollmentKey] = approvalStatuses[i];
        await keyValueStore.put(
            enrollmentKey, AtData()..data = jsonEncode(enrollValue));
      }

      String enrollmentStatus = 'approved';
      String command =
          'enroll:list:{"enrollmentStatusFilter":["$enrollmentStatus"]}';
      Response approvedResponse =
          await enrollVerb.processInternal(command, inboundConnection);
      Map<String, dynamic> fetchedEnrollments =
          jsonDecode(approvedResponse.data!);
      expect(fetchedEnrollments.length, 1);
      assert(approvedResponse.data!.contains(enrollmentKeys[0]));

      enrollmentStatus = 'pending';
      command = 'enroll:list:{"enrollmentStatusFilter":["$enrollmentStatus"]}';
      Response pendingResponse =
          await enrollVerb.processInternal(command, inboundConnection);
      fetchedEnrollments = jsonDecode(pendingResponse.data!);
      expect(fetchedEnrollments.length, 2);
      assert(pendingResponse.data!.contains(enrollmentKeys[1]));
      assert(pendingResponse.data!.contains(enrollmentKeys[2]));

      enrollmentStatus = 'revoked';
      command = 'enroll:list:{"enrollmentStatusFilter":["$enrollmentStatus"]}';
      Response revokedResponse =
          await enrollVerb.processInternal(command, inboundConnection);
      fetchedEnrollments = jsonDecode(revokedResponse.data!);
      expect(fetchedEnrollments.length, 3);
      assert(revokedResponse.data!.contains(enrollmentKeys[3]));
      assert(revokedResponse.data!.contains(enrollmentKeys[4]));
      assert(revokedResponse.data!.contains(enrollmentKeys[5]));

      enrollmentStatus = 'denied';
      command = 'enroll:list:{"enrollmentStatusFilter":["$enrollmentStatus"]}';
      Response deniedResponse =
          await enrollVerb.processInternal(command, inboundConnection);
      fetchedEnrollments = jsonDecode(deniedResponse.data!);
      expect(fetchedEnrollments.length, 4);
      assert(deniedResponse.data!.contains(enrollmentKeys[6]));
      assert(deniedResponse.data!.contains(enrollmentKeys[7]));
      assert(deniedResponse.data!.contains(enrollmentKeys[8]));
      assert(deniedResponse.data!.contains(enrollmentKeys[9]));

      command = 'enroll:list'; // run enroll list without filter
      Response listAllResponse =
          await enrollVerb.processInternal(command, inboundConnection);
      fetchedEnrollments = jsonDecode(listAllResponse.data!);
      expect(fetchedEnrollments.length, 10);
      for (final entry in fetchedEnrollments.entries) {
        final k = entry.key;
        final v = entry.value;
        expect(v['appName'], 'unit_test_enroll');
        expect(v['deviceName'], 'testDevice');
        expect(v['namespace'], {'unit_tst': 'rw'});
        expect(v['status'], enrollmentStatuses[k]);
        expect(v['apkamPublicKey'], 'aPK');
        expect(v['encryptedAPKAMSymmetricKey'], 'anSK');
      }
    });

    test('enroll list with an invalid approvalStateFilter', () async {
      EnrollVerbHandler enrollVerb =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      inboundConnection.metadata.isAuthenticated = true;
      inboundConnection.metadata.authType = AuthType.cram;

      String approvalStatus = 'invalid_status';
      String command =
          'enroll:list:{"enrollmentStatusFilter":["$approvalStatus"]}';
      expect(
          () async =>
              await enrollVerb.processInternal(command, inboundConnection),
          throwsA(predicate((e) => e is ArgumentError)));
    });

    test(
        'verify verb params being populated with correct enrollmentStatusFilter',
        () {
      inboundConnection.metadata.isAuthenticated = true;
      inboundConnection.metadata.authType = AuthType.cram;

      String approvalStatus = 'approved';
      String command =
          'enroll:list:{"enrollmentStatusFilter":["$approvalStatus"]}';
      Map<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, command);
      var enrollParams = jsonDecode(verbParams['enrollParams']!);
      expect(enrollParams['enrollmentStatusFilter'], [approvalStatus]);
    });

    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to enroll permissions', () {
    Response response = Response();
    late String enrollmentId;
    setUp(() async {
      await verbTestsSetUp();

      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
    });

    var enrollOperationMap = {
      'approve': 'approved',
      'deny': 'denied',
    };

    enrollOperationMap.forEach((operation, expectedStatus) {
      test('A test to verify pending enrollment is $operation', () async {
        String enrollmentRequest =
            'enroll:request:{"appName":"wavi","deviceName":"mydevice"'
            ',"namespaces":{"wavi":"r"},"otp":"${response.data}"'
            ',"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"'
            ',"encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
        HashMap<String, String?> enrollmentRequestVerbParams =
            getVerbParam(VerbSyntax.enroll, enrollmentRequest);
        inboundConnection.metaData.isAuthenticated = false;
        EnrollVerbHandler enrollVerbHandler =
            EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
        await enrollVerbHandler.processVerb(
            response, enrollmentRequestVerbParams, inboundConnection);
        enrollmentId = jsonDecode(response.data!)['enrollmentId'];
        expect(jsonDecode(response.data!)['status'], 'pending');
        String approveEnrollment =
            'enroll:$operation:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
        HashMap<String, String?> approveEnrollmentVerbParams =
            getVerbParam(VerbSyntax.enroll, approveEnrollment);
        inboundConnection.metaData.isAuthenticated = true;
        inboundConnection.metaData.authType = AuthType.cram;
        enrollVerbHandler =
            EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
        await enrollVerbHandler.processVerb(
            response, approveEnrollmentVerbParams, inboundConnection);
        expect(jsonDecode(response.data!)['status'], expectedStatus);
        expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      });
    });
    tearDown(() async => await verbTestsTearDown());
  });
  group(
      'A group of tests to assert enroll operations cannot performed on unauthenticated connection',
      () {
    setUp(() async {
      await verbTestsSetUp();
    });
    test(
        'A test to verify enrollment cannot be approved on an unauthenticated connection',
        () async {
      String enrollmentRequest = 'enroll:approve:enrollmentid:123';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session';
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, verbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is UnAuthenticatedException &&
              e.message ==
                  'Cannot approve enrollment without authentication')));
    });

    test(
        'A test to verify enrollment cannot be denied on an unauthenticated connection',
        () async {
      String enrollmentRequest = 'enroll:deny:enrollmentid:123';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session';
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, verbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is UnAuthenticatedException &&
              e.message == 'Cannot deny enrollment without authentication')));
    });

    test(
        'A test to verify enrollment cannot be revoked on an unauthenticated connection',
        () async {
      String enrollmentRequest = 'enroll:revoke:enrollmentid:123';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session';
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, verbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is UnAuthenticatedException &&
              e.message == 'Cannot revoke enrollment without authentication')));
    });

    test('A test to verify enrollment request without otp throws exception',
        () async {
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session';
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, verbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is IllegalArgumentException &&
              e.message == 'invalid otp. Cannot process enroll request')));
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to enroll revoke operations', () {
    setUp(() async {
      await verbTestsSetUp();
    });
    test(
        'A test to verify revoke operations thrown exception when given enrollmentId is not in keystore',
        () async {
      String enrollmentId = '123';
      String enrollmentRequest =
          'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      castMetadata(inboundConnection).enrollmentId =
          '456'; // a client cannot revoke its own enrollment. Set a different enrollmentId in inbound
      Response response = Response();
      castMetadata(inboundConnection).authType = AuthType.apkam;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      expect(response.isError, true);
      expect(response.errorMessage, isNotNull);
      assert(response.errorMessage!
          .contains('enrollment_id: $enrollmentId is expired'));
      expect(response.errorCode, 'AT0028');
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group(
      'A group of hive related test to ensure enrollment keys are not updated in commit log keystore',
      () {
    setUp(() async {
      await verbTestsSetUp();
    });
    test('A test to ensure new enrollment key is not added to commit log',
        () async {
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"myDevice","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key","apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      castMetadata(inboundConnection).enrollmentId = '123';
      Response responseObject = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          responseObject, verbParams, inboundConnection);
      Map<String, dynamic> enrollmentResponse =
          jsonDecode(responseObject.data!);
      expect(enrollmentResponse['enrollmentId'], isNotNull);
      expect(enrollmentResponse['status'], 'approved');
      expect(await (keyValueStore.commitLog as AtCommitLog).iterate().isEmpty,
          true);
    });

    test(
        'A test to ensure new enrollment key on CRAM authenticated connection is not added to commit log',
        () async {
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"myDevice","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key","apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      castMetadata(inboundConnection).enrollmentId = '123';
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      Map<String, dynamic> enrollmentResponse = jsonDecode(response.data!);
      expect(enrollmentResponse['enrollmentId'], isNotNull);
      expect(enrollmentResponse['status'], 'approved');
      expect(await (keyValueStore.commitLog as AtCommitLog).iterate().isEmpty,
          true);
    });

    test('A test to ensure enroll approval is not added to commit log',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"myDevice","namespaces":{"buzz":"rw"},"encryptedAPKAMSymmetricKey":"dummy_apkam_symmetric_key","apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}","otp":"${response.data}"}';
      HashMap<String, String?> enrollmentVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session';
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, enrollmentVerbParams, inboundConnection);
      Map<String, dynamic> enrollmentResponse = jsonDecode(response.data!);
      expect(enrollmentResponse['enrollmentId'], isNotNull);
      String enrollmentId = enrollmentResponse['enrollmentId'];
      String approveEnrollment =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encryption_key"}';
      enrollmentVerbParams = getVerbParam(VerbSyntax.enroll, approveEnrollment);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      await enrollVerbHandler.processVerb(
          response, enrollmentVerbParams, inboundConnection);
      var approveEnrollmentResponse = jsonDecode(response.data!);
      expect(approveEnrollmentResponse['enrollmentId'], enrollmentId);
      expect(approveEnrollmentResponse['status'], 'approved');
      final entries =
          await (keyValueStore.commitLog as AtCommitLog).iterate().toList();
      expect(
          entries.where((e) => e.atKey?.contains('__manage') ?? false).isEmpty,
          true);
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to enrollment request expiry', () {
    String? otp;
    setUp(() async {
      await verbTestsSetUp();
      String totpCommand = 'otp:get';
      HashMap<String, String?> totpVerbParams =
          getVerbParam(VerbSyntax.otp, totpCommand);
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      Response defaultResponse = Response();
      await otpVerbHandler.processVerb(
          defaultResponse, totpVerbParams, inboundConnection);
      otp = defaultResponse.data;
    });
    test('A test to verify expired enrollment cannot be approved', () async {
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      enrollVerbHandler.enrollmentExpiryInMills = 1;
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"$otp","apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}", "encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      String status = jsonDecode(response.data!)['status'];
      expect(status, 'pending');
      await Future.delayed(Duration(milliseconds: 3));
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(response.isError, true);
      expect(response.errorMessage, isNotNull);
      assert(response.errorMessage!
          .contains('enrollment_id: $enrollmentId is expired'));
      expect(response.errorCode, 'AT0028');
    });

    test('A test to verify expired enrollment cannot be denied', () async {
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      enrollVerbHandler.enrollmentExpiryInMills = 1;
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"$otp","apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session_id1';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      String status = jsonDecode(response.data!)['status'];
      expect(status, 'pending');
      await Future.delayed(Duration(milliseconds: 2));
      String denyEnrollmentCommand =
          'enroll:deny:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams = getVerbParam(VerbSyntax.enroll, denyEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(response.isError, true);
      expect(response.errorMessage, isNotNull);
      assert(response.errorMessage!
          .contains('enrollment_id: $enrollmentId is expired'));
      expect(response.errorCode, 'AT0028');
    });

    test('A test to verify TTL on approved enrollment is reset', () async {
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      enrollVerbHandler.enrollmentExpiryInMills = 600000;
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"$otp","apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      String status = jsonDecode(response.data!)['status'];
      expect(status, 'pending');
      String enrollmentKey =
          '$enrollmentId.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice';
      AtData? enrollmentData = await keyValueStore.get(enrollmentKey);
      expect(enrollmentData!.metaData!.expiresAt, isNotNull);
      expect(enrollmentData.metaData!.ttl, 600000);
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      enrollmentData = await keyValueStore.get(enrollmentKey);
      expect(enrollmentData!.metaData!.expiresAt, null);
      expect(enrollmentData.metaData!.ttl, 0);
    });

    test(
        'A test to verify TTL is not set for enrollment requested on an authenticated connection',
        () async {
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"$otp","apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      expect(enrollmentId, isNotNull);
      expect(jsonDecode(response.data!)['status'], 'approved');
      AtData? enrollmentData = await keyValueStore.get(
          '$enrollmentId.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice');
      expect(enrollmentData!.metaData!.expiresAt, null);
      expect(enrollmentData.metaData!.ttl, null);
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to approve enrollment', () {
    String enrollmentIdWithManageNamespace = Uuid().v4();
    String? otp;
    late String enrollmentId;
    late EnrollVerbHandler enrollVerbHandler;
    HashMap<String, String?> enrollVerbParams;
    Response defaultResponse = Response();
    setUp(() async {
      await verbTestsSetUp();
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'manage-session-id',
          'buzz',
          'my-phone',
          'manage-enrollment-public-key')
        ..namespaces = {'__manage': 'rw', 'wavi': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      await keyValueStore.put(
          '$enrollmentIdWithManageNamespace.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice',
          AtData()..data = jsonEncode(enrollDataStoreValue.toJson()));
      String totpCommand = 'otp:get';
      HashMap<String, String?> totpVerbParams =
          getVerbParam(VerbSyntax.otp, totpCommand);
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      await otpVerbHandler.processVerb(
          defaultResponse, totpVerbParams, inboundConnection);
      otp = defaultResponse.data;
      enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      enrollVerbHandler.enrollmentExpiryInMills = 60000;
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi-${Uuid().v4().hashCode}","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"$otp","apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          defaultResponse, enrollVerbParams, inboundConnection);
      enrollmentId = jsonDecode(defaultResponse.data!)['enrollmentId'];
      String status = jsonDecode(defaultResponse.data!)['status'];
      expect(status, 'pending');
    });

    test('A test to verify denied enrollment cannot be approved', () async {
      Response response = Response();
      String denyEnrollmentCommand =
          'enroll:deny:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams = getVerbParam(VerbSyntax.enroll, denyEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'denied');
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is IllegalStateException &&
              e.message ==
                  'Failed to approve enrollment id: $enrollmentId. Cannot approve a denied enrollment. Only pending enrollments can be approved')));
    });

    test('A test to verify revoke enrollment', () async {
      Response response = Response();
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      String revokeEnrollmentCommand =
          'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, revokeEnrollmentCommand);
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'revoked');
    });

    test('A test to verify revoke enrollment with force flag', () async {
      Response response = Response();
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      String revokeEnrollmentCommand =
          'enroll:revoke:force:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, revokeEnrollmentCommand);
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'revoked');
    });

    test(
        'A test to verify revoke enrollment throws exception when a client is trying to revoke own enrollment without force flag',
        () async {
      Response response = Response();
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      inboundConnection.metadata.enrollmentId = enrollmentIdWithManageNamespace;
      inboundConnection.metadata.authType = AuthType.apkam;

      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      String revokeEnrollmentCommand =
          'enroll:revoke:{"enrollmentId":"$enrollmentIdWithManageNamespace"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, revokeEnrollmentCommand);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is AtEnrollmentException &&
              e.message == 'Current client cannot revoke its own enrollment')));
    });

    test(
        'A test to verify enrollment is revoked when a client is trying to revoke own enrollment with force flag',
        () async {
      Response response = Response();
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      inboundConnection.metadata.enrollmentId = enrollmentIdWithManageNamespace;
      inboundConnection.metadata.authType = AuthType.apkam;

      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      String revokeEnrollmentCommand =
          'enroll:revoke:force:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, revokeEnrollmentCommand);
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'revoked');
    });

    test('A test to verify revoked enrollment cannot be approved', () async {
      Response response = Response();
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      String revokeEnrollmentCommand =
          'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, revokeEnrollmentCommand);
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'revoked');
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, approveEnrollVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is IllegalStateException &&
              e.message ==
                  'Failed to approve enrollment id: $enrollmentId. Cannot approve a revoked enrollment. Only pending enrollments can be approved')));
    });

    test('A test to verify that an approved enrollment cannot be denied',
        () async {
      Response response = Response();
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');

      expect(
          () async => await enrollVerbHandler.processVerb(
              response,
              getVerbParam(VerbSyntax.enroll,
                  'enroll:deny:{"enrollmentId":"$enrollmentId"}'),
              inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is IllegalStateException &&
              e.message ==
                  'Failed to deny enrollment id: $enrollmentId.'
                      ' Cannot deny a approved enrollment.'
                      ' Only pending enrollments can be denied')));
    });

    test('A test to verify pending enrollment cannot be revoked', () async {
      Response response = Response();
      String denyEnrollmentCommand =
          'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams = getVerbParam(VerbSyntax.enroll, denyEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is IllegalStateException &&
              e.message ==
                  'Failed to revoke enrollment id: $enrollmentId. Cannot revoke a pending enrollment. Only approved enrollments can be revoked')));
    });

    /// Stores an approved enrollment holding exactly [namespaces] and returns
    /// its id.
    Future<String> storeApprovedEnrollment(
        Map<String, String> namespaces) async {
      final String id = Uuid().v4();
      await keyValueStore.put(
          '$id.${EnrollmentConstants.enrollmentKeyPattern}'
          '.${EnrollmentConstants.enrollManageNamespace}$alice',
          AtData()
            ..data = jsonEncode(EnrollDataStoreValue(
                'approver-session', 'buzz', 'my-tablet', 'approver-public-key')
              ..namespaces = namespaces
              ..approval = EnrollApproval(EnrollmentStatus.approved.name)
              ..encryptedAPKAMSymmetricKey = 'dummy_encrypted_symm_key'));
      return id;
    }

    /// Stores a PENDING enrollment asking for exactly [namespaces] and
    /// returns its id.
    Future<String> storePendingEnrollment(
        Map<String, String> namespaces) async {
      final String id = Uuid().v4();
      await keyValueStore.put(
          '$id.${EnrollmentConstants.enrollmentKeyPattern}'
          '.${EnrollmentConstants.enrollManageNamespace}$alice',
          AtData()
            ..data = jsonEncode(EnrollDataStoreValue(
                'target-session', 'wavi', 'my-phone', 'target-public-key')
              ..namespaces = namespaces
              ..approval = EnrollApproval(EnrollmentStatus.pending.name)
              ..encryptedAPKAMSymmetricKey = 'dummy_encrypted_symm_key'));
      return id;
    }

    Future<String?> stateOf(String id) async => jsonDecode(
        (await keyValueStore.get('$id.${EnrollmentConstants.enrollmentKeyPattern}'
            '.${EnrollmentConstants.enrollManageNamespace}$alice'))!
            .data!)['approval']['state'];

    Future<void> approveAs(String approverId, String targetId) async {
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      inboundConnection.metadata.enrollmentId = approverId;
      inboundConnection.metadata.authType = AuthType.apkam;
      await enrollVerbHandler.processVerb(
          Response(),
          getVerbParam(
              VerbSyntax.enroll,
              'enroll:approve:{"enrollmentId":"$targetId",'
              '"encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key",'
              '"encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}'),
          inboundConnection);
    }

    test('an approver holding __manage:r may not approve a request for '
        '__manage:rw', () async {
      final String approverId = await storeApprovedEnrollment({'__manage': 'r'});
      final String targetId = await storePendingEnrollment({'__manage': 'rw'});

      await expectLater(
          () => approveAs(approverId, targetId),
          throwsA(predicate((dynamic e) =>
              e is UnAuthorizedException &&
              e.message ==
                  'Failed to approve enrollment id: $targetId. Client is not'
                      ' authorized for namespaces in the enrollment request')),
          reason: 'approving is checked per namespace against what the '
              'approver itself holds, and __manage is not exempt from that');
      expect(await stateOf(targetId), EnrollmentStatus.pending.name,
          reason: 'refused before anything is written');
    });

    test('…but it may approve a request for __manage:r', () async {
      // The control: a read-only administrator may still admit its own kind.
      final String approverId = await storeApprovedEnrollment({'__manage': 'r'});
      final String targetId = await storePendingEnrollment({'__manage': 'r'});

      await approveAs(approverId, targetId);
      expect(await stateOf(targetId), EnrollmentStatus.approved.name);
    });

    test('…and an approver holding __manage:rw may confer __manage:rw',
        () async {
      // The second control: only the approver's own access differs.
      final String approverId =
          await storeApprovedEnrollment({'__manage': 'rw'});
      final String targetId = await storePendingEnrollment({'__manage': 'rw'});

      await approveAs(approverId, targetId);
      expect(await stateOf(targetId), EnrollmentStatus.approved.name);
    });

    test(
        'an approver holding everything BUT __manage:rw may not approve a '
        'full root', () async {
      final String approverId =
          await storeApprovedEnrollment({'*': 'rw', '__manage': 'r'});
      final String targetId =
          await storePendingEnrollment({'*': 'rw', '__manage': 'rw'});

      await expectLater(
          () => approveAs(approverId, targetId),
          throwsA(predicate((dynamic e) =>
              e is UnAuthorizedException &&
              e.message ==
                  'Failed to approve enrollment id: $targetId. Client is not'
                      ' authorized for namespaces in the enrollment request')),
          reason: 'an approver that does not hold __manage:rw may not confer '
              'a full root, however much else it holds');
      expect(await stateOf(targetId), EnrollmentStatus.pending.name,
          reason: 'refused before anything is written');
    });

    test('…but that approver may still admit one at its own level', () async {
      // The control: the target's __manage access is the only difference.
      final String approverId =
          await storeApprovedEnrollment({'*': 'rw', '__manage': 'r'});
      final String targetId =
          await storePendingEnrollment({'*': 'rw', '__manage': 'r'});

      Object? refusal;
      try {
        await approveAs(approverId, targetId);
      } catch (e) {
        refusal = e;
      }
      expect(refusal, isNull,
          reason: 'an administrator that may approve NOTHING is a blanket '
              'refusal rather than the narrowing under test');
      expect(await stateOf(targetId), EnrollmentStatus.approved.name,
          reason: 'it confers exactly what it holds, on every namespace');
    });
  });

  group('A group of tests related enrollment unrevoke operation', () {
    String enrollmentIdWithManageNamespace = Uuid().v4();
    String? otp;
    late String enrollmentId;
    late EnrollVerbHandler enrollVerbHandler;
    HashMap<String, String?> enrollVerbParams;
    Response defaultResponse = Response();
    setUp(() async {
      await verbTestsSetUp();
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'manage-session-id',
          'buzz',
          'my-phone',
          'manage-enrollment-public-key')
        ..namespaces = {'__manage': 'rw', 'wavi': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      await keyValueStore.put(
          '$enrollmentIdWithManageNamespace.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice',
          AtData()..data = jsonEncode(enrollDataStoreValue.toJson()));
      String totpCommand = 'otp:get';
      HashMap<String, String?> totpVerbParams =
          getVerbParam(VerbSyntax.otp, totpCommand);
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      await otpVerbHandler.processVerb(
          defaultResponse, totpVerbParams, inboundConnection);
      otp = defaultResponse.data;
      enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      enrollVerbHandler.enrollmentExpiryInMills = 60000;
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi-${Uuid().v4().hashCode}","deviceName":"mydevice","namespaces":{"wavi":"r"},"otp":"$otp","apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      HashMap<String, String?> enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          defaultResponse, enrollVerbParams, inboundConnection);
      enrollmentId = jsonDecode(defaultResponse.data!)['enrollmentId'];
      String status = jsonDecode(defaultResponse.data!)['status'];
      expect(status, 'pending');
    });

    test(
        'A test to verify unrevoke enrollment sets the enrollment state to approved',
        () async {
      Response response = Response();
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      String revokeEnrollmentCommand =
          'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, revokeEnrollmentCommand);
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'revoked');
      String unrevokeEnrollmentCommand =
          'enroll:unrevoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, unrevokeEnrollmentCommand);
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
    });

    test(
        'A test to verify unrevoke enrollment throws exception when enrollment state is not revoked',
        () async {
      Response response = Response();
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      String unrevokeEnrollmentCommand =
          'enroll:unrevoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, unrevokeEnrollmentCommand);

      await expectLater(
          () => enrollVerbHandler.processVerb(
              response, enrollVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is IllegalStateException &&
              e.message ==
                  'Failed to unrevoke enrollment id: $enrollmentId. Cannot un-revoke a approved enrollment. Only revoked enrollments can be un-revoked')));
    });

    test(
        'A test to verify unrevoke enrollment throws exception when enrollmentId is not supplied',
        () async {
      Response response = Response();
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      String revokeEnrollmentCommand =
          'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, revokeEnrollmentCommand);
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'revoked');
      String unrevokeEnrollmentCommand = 'enroll:unrevoke:{"enrollmentId":""}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, unrevokeEnrollmentCommand);
      expect(
          () => enrollVerbHandler.processVerb(
              response, enrollVerbParams, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is IllegalArgumentException &&
              e.message == 'enrollmentId is mandatory for enroll:unrevoke')));
    });

    test('A test to verify apkam expiry is set for approved enrollment',
        () async {
      Response response = Response();

      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);

      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice"'
          ',"namespaces":{"wavi":"r"},"otp":"${response.data}"'
          ',"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"'
          ',"encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key",'
          '"apkamKeysExpiryInMillis":1000}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      enrollmentId = jsonDecode(response.data!)['enrollmentId'];
      expect(jsonDecode(response.data!)['status'], 'pending');
      AtData? enrollmentAtData = await keyValueStore.get(
          '$enrollmentId.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice');
      expect(
          enrollmentAtData?.metaData?.ttl,
          Duration(hours: AtSecondaryConfig.enrollmentExpiryInHours)
              .inMilliseconds);

      String approveEnrollment =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollmentVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollment);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, approveEnrollmentVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['status'], 'approved');
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);

      enrollmentAtData = await keyValueStore.get(
          '$enrollmentId.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice');
      expect(enrollmentAtData?.metaData?.ttl, 1000);
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of test to verify getDelayIntervalInSeconds method', () {
    setUp(() async {
      await verbTestsSetUp();
    });
    test(
        'A test to verify getDelayIntervalInSeconds return delay in increment order',
        () {
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);

      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 1000);
      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 2000);
      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 3000);
      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 5000);
      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 8000);
      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 13000);
      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 21000);
      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 34000);
      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 55000);
      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 55000);
      expect(enrollVerbHandler.getDelayIntervalInMilliseconds(), 55000);
    });

    test(
        'A test to verify getDelayIntervalInSeconds is reset only after threshold is met',
        () async {
      Future<void> swallow(Future Function() f) async {
        try {
          await f();
        } on IllegalArgumentException catch (_) {}
      }

      String makeEnrollRequest(String otp) => 'enroll:request:'
          '{"appName":"wavi","deviceName":"mydevice"'
          ',"namespaces":{"wavi":"r"},"otp":"$otp"'
          ',"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"'
          ',"encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';

      Response response = Response();
      EnrollVerbHandler evh =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      HashMap<String, String?> evp = HashMap<String, String?>();
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.sessionID = 'dummy_session_id';

      EnrollVerbHandler.initialDelayInMilliseconds = 1;
      evh.delayForInvalidOTPSeries = [
        0,
        EnrollVerbHandler.initialDelayInMilliseconds
      ];
      evh.maxDelayInMillis = EnrollVerbHandler.initialDelayInMilliseconds * 10;

      evp = getVerbParam(VerbSyntax.enroll, makeEnrollRequest('123'));
      await swallow(() => evh.processVerb(response, evp, inboundConnection));
      expect(evh.getEnrollmentResponseDelayInMilliseconds(),
          EnrollVerbHandler.initialDelayInMilliseconds);

      evp = getVerbParam(VerbSyntax.enroll, makeEnrollRequest('123'));
      await swallow(() => evh.processVerb(response, evp, inboundConnection));
      expect(evh.getEnrollmentResponseDelayInMilliseconds(),
          EnrollVerbHandler.initialDelayInMilliseconds * 2);

      evp = getVerbParam(VerbSyntax.enroll, makeEnrollRequest('123'));
      await swallow(() => evh.processVerb(response, evp, inboundConnection));
      expect(evh.getEnrollmentResponseDelayInMilliseconds(),
          EnrollVerbHandler.initialDelayInMilliseconds * 3);

      evp = getVerbParam(VerbSyntax.enroll, makeEnrollRequest('123'));
      await swallow(() => evh.processVerb(response, evp, inboundConnection));
      expect(evh.getEnrollmentResponseDelayInMilliseconds(),
          EnrollVerbHandler.initialDelayInMilliseconds * 5);

      evp = getVerbParam(VerbSyntax.enroll, makeEnrollRequest('123'));
      await swallow(() => evh.processVerb(response, evp, inboundConnection));
      expect(evh.getEnrollmentResponseDelayInMilliseconds(),
          EnrollVerbHandler.initialDelayInMilliseconds * 8);

      evp = getVerbParam(VerbSyntax.enroll, makeEnrollRequest('123'));
      await swallow(() => evh.processVerb(response, evp, inboundConnection));
      expect(evh.getEnrollmentResponseDelayInMilliseconds(),
          EnrollVerbHandler.initialDelayInMilliseconds * 10);

      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      await otpVerbHandler.processVerb(
          response, getVerbParam(VerbSyntax.otp, 'otp:get'), inboundConnection);

      inboundConnection.metaData.isAuthenticated = false;
      evp = getVerbParam(VerbSyntax.enroll, makeEnrollRequest(response.data!));
      await evh.processVerb(response, evp, inboundConnection);
      Map<String, dynamic> enrollmentResponse = jsonDecode(response.data!);
      expect(enrollmentResponse['status'], 'pending');
      expect(evh.getEnrollmentResponseDelayInMilliseconds(),
          EnrollVerbHandler.initialDelayInMilliseconds);
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to validating the enrollment request', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test(
        'A test to verify same app and same device name throws exception when enrollment is approved',
        () async {
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      String key = '123.new.enrollments.__manage$alice';
      EnrollDataStoreValue enrollDataStoreValue =
          EnrollDataStoreValue('123', 'wavi', 'iphone', 'dummy_public_key');
      enrollDataStoreValue.approval =
          EnrollApproval(EnrollmentStatus.approved.name);

      AtData atData = AtData()..data = jsonEncode(enrollDataStoreValue);
      await keyValueStore.put(key, atData);

      EnrollParams enrollParams = EnrollParams()
        ..appName = 'wavi'
        ..deviceName = 'iphone'
        ..apkamPublicKey = 'dummy_public_key'
        ..namespaces = {'wavi': 'rw'};

      expect(
          () async => await enrollVerbHandler
              .preventDuplicateEnrollRequest(enrollParams),
          throwsA(predicate((dynamic e) =>
              e is IllegalStateException &&
              e.message ==
                  'Another enrollment with id 123 exists with the app name: ${enrollParams.appName} and device name: ${enrollParams.deviceName} in approved state')));
    });

    test(
        'A test to verify same app and same device name throws exception when enrollment is pending',
        () async {
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      String key = '123.new.enrollments.__manage$alice';
      EnrollDataStoreValue enrollDataStoreValue =
          EnrollDataStoreValue('123', 'wavi', 'iphone', 'dummy_public_key');
      enrollDataStoreValue.approval =
          EnrollApproval(EnrollmentStatus.pending.name);

      AtData atData = AtData()..data = jsonEncode(enrollDataStoreValue);
      await keyValueStore.put(key, atData);

      EnrollParams enrollParams = EnrollParams()
        ..appName = 'wavi'
        ..deviceName = 'iphone'
        ..apkamPublicKey = 'dummy_public_key'
        ..namespaces = {'wavi': 'rw'};

      expect(
          () async => await enrollVerbHandler
              .preventDuplicateEnrollRequest(enrollParams),
          throwsA(predicate((dynamic e) =>
              e is IllegalStateException &&
              e.message ==
                  'Another enrollment with id 123 exists with the app name: ${enrollParams.appName} and device name: ${enrollParams.deviceName} in pending state')));
    });

    test(
        'A test to verify enrollment requests with same appName and different deviceName is submitted successfully',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"device-1","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId_1 = jsonDecode(response.data!)['enrollmentId'];
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"device-2","namespaces":{"buzz":"r"},"otp":"${response.data}","apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId_2 = jsonDecode(response.data!)['enrollmentId'];

      expect(enrollmentId_1, isNotEmpty);
      expect(enrollmentId_2, isNotEmpty);
      expect(enrollmentId_1 == enrollmentId_2, false);
    });

    test(
        'A test to verify enrollment requests with different appName and same deviceName is submitted successfully',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"device-1","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId_1 = jsonDecode(response.data!)['enrollmentId'];
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      enrollmentRequest =
          'enroll:request:{"appName":"buzz","deviceName":"device-1","namespaces":{"buzz":"r"},"otp":"${response.data}","apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId_2 = jsonDecode(response.data!)['enrollmentId'];

      expect(enrollmentId_1, isNotEmpty);
      expect(enrollmentId_2, isNotEmpty);
      expect(enrollmentId_1 == enrollmentId_2, false);
    });

    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to enroll:fetch', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test('A test to verify enroll:fetch returns the enrollment data', () async {
      String key = '123.new.enrollments.__manage$alice';
      EnrollDataStoreValue enrollDataStoreValue =
          EnrollDataStoreValue('123', 'wavi', 'iphone', 'dummy_public_key');
      enrollDataStoreValue.namespaces = {'wavi': 'rw'};
      enrollDataStoreValue.approval =
          EnrollApproval(EnrollmentStatus.approved.name);
      enrollDataStoreValue.encryptedAPKAMSymmetricKey = 'dummy_apkam_key';
      AtData atData = AtData()..data = jsonEncode(enrollDataStoreValue);
      await keyValueStore.put(key, atData);

      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);

      String enrollmentRequest = 'enroll:fetch:{"enrollmentId":"123"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      Map enrollmentResponse = jsonDecode(response.data!);

      expect(enrollmentResponse['appName'], enrollDataStoreValue.appName);
      expect(enrollmentResponse['deviceName'], enrollDataStoreValue.deviceName);
      expect(enrollmentResponse['namespace'], enrollDataStoreValue.namespaces);
      expect(
          enrollmentResponse['status'], enrollDataStoreValue.approval?.state);
      expect(enrollmentResponse['encryptedAPKAMSymmetricKey'],
          enrollDataStoreValue.encryptedAPKAMSymmetricKey);
    });

    // enroll:fetch authorisation: self, or __manage plus access to ALL of
    // the target enrollment's namespaces.
    Future<void> seedEnrollment(String id, Map<String, String> ns) async {
      await keyValueStore.put(
          '$id.new.enrollments.__manage$alice',
          AtData()
            ..data = jsonEncode(
                EnrollDataStoreValue('session', 'wavi', 'pixel', 'pubkey')
                  ..namespaces = ns
                  ..approval = EnrollApproval(EnrollmentStatus.approved.name)
                  ..encryptedAPKAMSymmetricKey = 'secret-$id'));
    }

    Future<Map> fetchAs(String callerId, String targetId) async {
      final response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.enrollmentId = callerId;
      inboundConnection.metaData.authType = AuthType.apkam;
      final handler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await handler.processVerb(
          response,
          getVerbParam(
              VerbSyntax.enroll, 'enroll:fetch:{"enrollmentId":"$targetId"}'),
          inboundConnection);
      return jsonDecode(response.data!);
    }

    Future<void> expectFetchDenied(String callerId, String targetId) async {
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.enrollmentId = callerId;
      inboundConnection.metaData.authType = AuthType.apkam;
      final handler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await expectLater(
          handler.processVerb(
              Response(),
              getVerbParam(VerbSyntax.enroll,
                  'enroll:fetch:{"enrollmentId":"$targetId"}'),
              inboundConnection),
          throwsA(isA<UnAuthorizedException>()));
    }

    test(
        'enroll:fetch — a caller can fetch its OWN enrollment without __manage',
        () async {
      await seedEnrollment('self1', {'wavi': 'rw'});
      final r = await fetchAs('self1', 'self1');
      expect(r['encryptedAPKAMSymmetricKey'], 'secret-self1');
    });

    test(
        'enroll:fetch — fetching ANOTHER enrollment without __manage is denied',
        () async {
      await seedEnrollment('caller1', {'wavi': 'rw'});
      await seedEnrollment('target1', {'wavi': 'rw'});
      await expectFetchDenied('caller1', 'target1');
    });

    test(
        'enroll:fetch — __manage + access to all of the target namespaces is allowed',
        () async {
      await seedEnrollment('mgr1', {'wavi': 'rw', '__manage': 'rw'});
      await seedEnrollment('target2', {'wavi': 'rw'});
      final r = await fetchAs('mgr1', 'target2');
      expect(r['encryptedAPKAMSymmetricKey'], 'secret-target2');
    });

    test(
        'enroll:fetch — __manage but missing one of the target namespaces is denied',
        () async {
      await seedEnrollment('mgr2', {'wavi': 'rw', '__manage': 'rw'});
      await seedEnrollment('target3', {'buzz': 'rw'});
      await expectFetchDenied('mgr2', 'target3');
    });

    test(
        'enroll:fetch — __manage:r reading a __manage:rw enrollment is denied',
        () async {
      await seedEnrollment('readOnlyAdmin', {'*': 'rw', '__manage': 'r'});
      await seedEnrollment('root1', {'*': 'rw', '__manage': 'rw'});

      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.enrollmentId = 'readOnlyAdmin';
      inboundConnection.metaData.authType = AuthType.apkam;
      await expectLater(
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager)
              .processVerb(
                  Response(),
                  getVerbParam(VerbSyntax.enroll,
                      'enroll:fetch:{"enrollmentId":"root1"}'),
                  inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is UnAuthorizedException &&
              e.message ==
                  'Not authorized to fetch enrollment root1: requires __manage'
                      ' and access to all of its namespaces')),
          reason: 'a __manage:r administrator has no claim to approve, revoke '
              'or delete a __manage:rw enrollment, and none to read its '
              'record either');
    });

    test('enroll:fetch — …but it may read one holding no more than it does',
        () async {
      // The control: a narrowed caller may still fetch what it covers.
      await seedEnrollment('readOnlyAdmin', {'*': 'rw', '__manage': 'r'});
      await seedEnrollment('peer1', {'*': 'rw', '__manage': 'r'});

      Object? refusal;
      Map? record;
      try {
        record = await fetchAs('readOnlyAdmin', 'peer1');
      } catch (e) {
        refusal = e;
      }
      expect(refusal, isNull,
          reason: 'an administrator that may fetch nothing but its own record '
              'is a blanket refusal rather than the narrowing under test');
      expect(record!['encryptedAPKAMSymmetricKey'], 'secret-peer1',
          reason: 'it covers every namespace the target holds, __manage '
              'included');
    });

    tearDown(() async => await verbTestsTearDown());
  });
  group('A group of tests related to validate mandatory params in enrollment',
      () {
    setUp(() async {
      await verbTestsSetUp();
    });
    test('A test to validate appName is mandatory for enroll:request',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      String enrollmentRequest =
          'enroll:request:{"deviceName":"mydevice","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollmentRequestVerbParams, inboundConnection),
          throwsA(predicate((e) =>
              e is IllegalArgumentException &&
              e.message == 'appName is mandatory for enroll:request')));
    });
    test('A test to validate deviceName is mandatory for enroll:request',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollmentRequestVerbParams, inboundConnection),
          throwsA(predicate((e) =>
              e is IllegalArgumentException &&
              e.message == 'deviceName is mandatory for enroll:request')));
    });
    test('A test to validate apkam public key is mandatory for enroll:request',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice", "namespaces":{"wavi":"r"}}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollmentRequestVerbParams, inboundConnection),
          throwsA(predicate((e) =>
              e is IllegalArgumentException &&
              e.message ==
                  'apkam public key is mandatory for enroll:request')));
    });
    test(
        'A test to validate encrypted apkam symmetric key is mandatory for new client enrollment',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi1","deviceName":"mydevice1","namespaces":{"buzz":"r"},"otp":"${response.data}","apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollmentRequestVerbParams, inboundConnection),
          throwsA(predicate((e) =>
              e is IllegalArgumentException &&
              e.message ==
                  'encrypted apkam symmetric key is mandatory for new client enroll:request')));
    });
    test(
        'A test to validate a request advertising a key package may omit the '
        'encrypted apkam symmetric key', () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi1","deviceName":"mydevice1","namespaces":{"buzz":"r"},"otp":"${response.data}","apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}","metadata":{"keyPackage":{"v":1,"keys":[]}}}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);

      final decoded = jsonDecode(response.data!);
      expect(decoded['status'], 'pending');
      final stored = await enMgr.getEnrollmentById(decoded['enrollmentId']);
      expect(stored.encryptedAPKAMSymmetricKey, isNull);
      expect(stored.metadata, {
        'keyPackage': {'v': 1, 'keys': []}
      });
    });
    test('A test to validate namespace is mandatory for new client enrollment',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi1","deviceName":"mydevice1","namespaces":{},"otp":"${response.data}","apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollmentRequestVerbParams, inboundConnection),
          throwsA(predicate((e) =>
              e is IllegalArgumentException &&
              e.message ==
                  'At least one namespace must be specified for enroll:request')));
    });
    test('A test to validate enrollmentId is mandatory for enroll:approve',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      String enrollmentRequest =
          'enroll:approve:{"encryptedDefaultEncryptionPrivateKey": "dummy_encrypted_default_encryption_private_key","encryptedDefaultSelfEncryptionKey":"dummy_encrypted_default_self_encryption_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollmentRequestVerbParams, inboundConnection),
          throwsA(predicate((e) =>
              e is IllegalArgumentException &&
              e.message == 'enrollmentId is mandatory for enroll:approve')));
    });
    test(
        'A test to validate encryptedDefaultEncryptionPrivateKey is mandatory for enroll:approve',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      String enrollmentRequest =
          'enroll:approve:{"enrollmentId":"abc123", "encryptedDefaultSelfEncryptionKey":"dummy_encrypted_default_self_encryption_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollmentRequestVerbParams, inboundConnection),
          throwsA(predicate((e) =>
              e is IllegalArgumentException &&
              e.message ==
                  'encryptedDefaultEncryptionPrivateKey is mandatory for enroll:approve')));
    });
    test(
        'A test to validate encryptedDefaultSelfEncryptionKey is mandatory for enroll:approve',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      String enrollmentRequest =
          'enroll:approve:{"enrollmentId":"abc123","encryptedDefaultEncryptionPrivateKey": "dummy_encrypted_default_encryption_private_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      expect(
          () async => await enrollVerbHandler.processVerb(
              response, enrollmentRequestVerbParams, inboundConnection),
          throwsA(predicate((e) =>
              e is IllegalArgumentException &&
              e.message ==
                  'encryptedDefaultSelfEncryptionKey is mandatory for enroll:approve')));
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group(
      'A group of tests to verify client authorization to approve the enrollment request',
      () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test(
        'A test to verify that the authorization check throws exception when the client is not authorized to __manage namespace',
        () async {
      String key =
          '123.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'session-123', 'wavi', 'my-device', 'dummy-pkam-public-key')
        ..namespaces = {'wavi': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      AtData atData = AtData()
        ..data = jsonEncode(enrollDataStoreValue.toJson());
      await keyValueStore.put(key, atData);

      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      inboundConnection.metaData.isAuthenticated = true;
      castMetadata(inboundConnection).enrollmentId = '123';
      castMetadata(inboundConnection).authType = AuthType.apkam;

      expect(
          () async => await enrollVerbHandler.isAuthorized(
              inboundConnection.metadata,
              namespace: 'data.my_app',
              enrolledNamespaceAccess: 'rw',
              operation: 'approve'),
          throwsA(predicate((dynamic e) =>
              e is UnAuthorizedException &&
              e.message ==
                  'The approving enrollment does not have access to "__manage" namespace')));
    });

    test(
        'A test to verify that the authorization check returns true when the client is PKAM authentication and enrollment id is null',
        () async {
      String key =
          '123.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'session-123', 'wavi', 'my-device', 'dummy-pkam-public-key')
        ..namespaces = {EnrollmentConstants.allNamespaces: 'rw'};
      AtData atData = AtData()
        ..data = jsonEncode(enrollDataStoreValue.toJson());
      await keyValueStore.put(key, atData);

      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;

      var res = await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
          namespace: 'data.my_app', enrolledNamespaceAccess: 'rw');
      expect(res, true);
    });

    test('A test to verify namespace hierarchies on enrolling side', () async {
      String key =
          '123.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'session-123', 'wavi', 'my-device', 'dummy-pkam-public-key')
        ..namespaces = {'my_app': 'rw', '__manage': 'rw', 'buzz': 'r'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      AtData atData = AtData()
        ..data = jsonEncode(enrollDataStoreValue.toJson());
      await keyValueStore.put(key, atData);

      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      inboundConnection.metaData.isAuthenticated = true;
      castMetadata(inboundConnection).enrollmentId = '123';
      castMetadata(inboundConnection).authType = AuthType.apkam;

      var res = await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
          namespace: 'data.my_app', enrolledNamespaceAccess: 'rw');
      expect(res, true);

      res = await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
          namespace: 'orders.data.my_app', enrolledNamespaceAccess: 'rw');
      expect(res, true);

      res = await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
          namespace: 'buzz', enrolledNamespaceAccess: 'rw');
      expect(res, false);

      res = await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
          namespace: 'buzz', enrolledNamespaceAccess: 'r');
      expect(res, true);
    });

    test('A test to verify namespace hierarchies on approving side', () async {
      String key =
          '123.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'session-123', 'wavi', 'my-device', 'dummy-pkam-public-key')
        ..namespaces = {'data.my_app': 'rw', '__manage': 'rw', 'buzz': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      AtData atData = AtData()
        ..data = jsonEncode(enrollDataStoreValue.toJson());
      await keyValueStore.put(key, atData);

      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      inboundConnection.metaData.isAuthenticated = true;
      castMetadata(inboundConnection).enrollmentId = '123';
      castMetadata(inboundConnection).authType = AuthType.apkam;

      var res = await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
          namespace: 'data.my_app', enrolledNamespaceAccess: 'rw');
      expect(res, true);

      res = await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
          namespace: 'orders.data.my_app', enrolledNamespaceAccess: 'rw');
      expect(res, true);

      res = await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
          namespace: 'other.my_app', enrolledNamespaceAccess: 'rw');
      expect(res, false);

      res = await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
          namespace: 'fizzbuzz');
      expect(res, false);

      res = await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
          namespace: 'fizz.buzz', enrolledNamespaceAccess: 'rw');
      expect(res, true);
    });

    test('the __manage grant itself is compared against what the caller holds',
        () async {
      String key =
          '123.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'session-123', 'wavi', 'my-device', 'dummy-pkam-public-key')
        ..namespaces = {'__manage': 'r'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      await keyValueStore.put(
          key, AtData()..data = jsonEncode(enrollDataStoreValue.toJson()));

      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      inboundConnection.metaData.isAuthenticated = true;
      castMetadata(inboundConnection).enrollmentId = '123';
      castMetadata(inboundConnection).authType = AuthType.apkam;

      expect(
          await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
              namespace: EnrollmentConstants.enrollManageNamespace,
              enrolledNamespaceAccess: 'rw',
              operation: 'approve'),
          false,
          reason: 'a caller holding __manage:r may not confer __manage:rw');

      expect(
          await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
              namespace: EnrollmentConstants.enrollManageNamespace,
              enrolledNamespaceAccess: 'r',
              operation: 'approve'),
          true,
          reason: 'the control: it may confer exactly what it holds');

      expect(
          await enrollVerbHandler.isAuthorized(inboundConnection.metadata,
              namespace: EnrollmentConstants.enrollManageNamespace,
              operation: 'approve'),
          true,
          reason: 'the second control: an empty enrolledNamespaceAccess is a '
              'caller reaching a __manage key rather than conferring a grant, '
              'and read access is enough for that');
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group(
      'A group of tests to ensure enrollment keys are only access by certain verbs',
      () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test('A test to verify update verb cannot update the enrollment key',
        () async {
      String key =
          '123.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'session-123', 'wavi', 'my-device', 'dummy-pkam-public-key')
        ..namespaces = {'my_app': 'rw', '__manage': 'rw', 'buzz': 'r'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      AtData atData = AtData()
        ..data = jsonEncode(enrollDataStoreValue.toJson());
      await keyValueStore.put(key, atData);
      inboundConnection.metadata.isAuthenticated = true;
      castMetadata(inboundConnection).enrollmentId = '123';
      castMetadata(inboundConnection).authType = AuthType.apkam;

      UpdateVerbHandler updateVerbHandler = UpdateVerbHandler(
        keyValueStore,
        statsNotificationService,
        notificationManager,
        alice,
      );

      expect(
          () async => await updateVerbHandler.process(
              'update:123.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice 1234',
              inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is UnAuthorizedException &&
              e.message ==
                  'Connection with enrollment ID 123 is not authorized to update key: 123.new.enrollments.__manage$alice')));
    });

    test(
        'A test to verify delete verb cannot delete the enrollment key (using delete verb)',
        () async {
      String key =
          '123.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'session-123', 'wavi', 'my-device', 'dummy-pkam-public-key')
        ..namespaces = {'my_app': 'rw', '__manage': 'rw', 'buzz': 'r'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      AtData atData = AtData()
        ..data = jsonEncode(enrollDataStoreValue.toJson());
      await keyValueStore.put(key, atData);
      inboundConnection.metadata.isAuthenticated = true;
      castMetadata(inboundConnection).enrollmentId = '123';
      castMetadata(inboundConnection).authType = AuthType.apkam;

      DeleteVerbHandler deleteVerbHandler = DeleteVerbHandler(
        keyValueStore,
        statsNotificationService,
        notificationManager,
      );

      expect(
          () async => await deleteVerbHandler.process(
              'delete:123.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice',
              inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is UnAuthorizedException &&
              e.message ==
                  'Connection with enrollment ID 123 is not authorized to delete key: 123.new.enrollments.__manage$alice')));
    });

    tearDown(() async => await verbTestsTearDown());
  });

  group('Group of tests to validate enroll delete operation', () {
    Response response = Response();

    setUp(() async {
      await verbTestsSetUp();
    });

    test('Validate behaviour of deleting denied enrollment', () async {
      String dummyEnrollId = '2134567809009';
      String enrollmentKey =
          '$dummyEnrollId.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'dummy-sId', 'dummy-app', 'dummy-device', 'dummy-key')
        ..namespaces = {'test_namespace': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.denied.name);
      AtData enrollAtData = AtData()..data = jsonEncode(enrollDataStoreValue);

      await keyValueStore.put(enrollmentKey, enrollAtData);

      inboundConnection.metadata.isAuthenticated = true;
      inboundConnection.metadata.authType = AuthType.cram;
      // A caller that really holds what the target holds, plus __manage.
      castMetadata(inboundConnection).enrollmentId =
          await createAndPersistAnEnrollment('deleter', 'device',
              {'test_namespace': 'rw', '__manage': 'rw'});
      castMetadata(inboundConnection).authType = AuthType.apkam;
      String enrollDeleteCommand =
          'enroll:delete:{"enrollmentId":"$dummyEnrollId"}';

      EnrollVerbHandler enrollVerb =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      var enrollVerbParams = enrollVerb.parse(enrollDeleteCommand);

      await enrollVerb.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(response.data,
          '{"enrollmentId":"$dummyEnrollId","status":"deleted"}');
    });

    test('Validate behaviour of deleting revoked enrollment', () async {
      String dummyEnrollId = '34534253436';
      String enrollmentKey =
          '$dummyEnrollId.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'dummy-sId', 'dummy-app', 'dummy-device', 'dummy-key')
        ..namespaces = {'test_namespace': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.revoked.name);
      AtData enrollAtData = AtData()..data = jsonEncode(enrollDataStoreValue);

      await keyValueStore.put(enrollmentKey, enrollAtData);

      inboundConnection.metadata.isAuthenticated = true;
      inboundConnection.metadata.authType = AuthType.cram;
      castMetadata(inboundConnection).enrollmentId =
          await createAndPersistAnEnrollment('deleter', 'device',
              {'test_namespace': 'rw', '__manage': 'rw'});
      castMetadata(inboundConnection).authType = AuthType.apkam;
      String enrollDeleteCommand =
          'enroll:delete:{"enrollmentId":"$dummyEnrollId"}';

      EnrollVerbHandler enrollVerb =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      var enrollVerbParams = enrollVerb.parse(enrollDeleteCommand);

      await enrollVerb.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(response.data,
          '{"enrollmentId":"$dummyEnrollId","status":"deleted"}');
    });

    test(
        'Validate negative behaviour of deleting denied enrollment from unAuthenticated connection',
        () async {
      String dummyEnrollId = '39458346583465';
      String enrollmentKey =
          '$dummyEnrollId.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'dummy-sId-1', 'dummy-app-1', 'dummy-device-1', 'dummy-key-1')
        ..namespaces = {'test_namespace': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.denied.name);
      AtData enrollAtData = AtData()..data = jsonEncode(enrollDataStoreValue);

      await keyValueStore.put(enrollmentKey, enrollAtData);

      inboundConnection.metadata.isAuthenticated = false;
      castMetadata(inboundConnection).enrollmentId = '123653';
      castMetadata(inboundConnection).authType = AuthType.apkam;
      String enrollDeleteCommand =
          'enroll:delete:{"enrollmentId":"$dummyEnrollId"}';

      EnrollVerbHandler enrollVerb =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      var enrollVerbParams = enrollVerb.parse(enrollDeleteCommand);

      expect(
          () async => await enrollVerb.processVerb(
              response, enrollVerbParams, inboundConnection),
          throwsA(predicate((e) =>
              e.toString() ==
              'Exception: Cannot delete enrollment without authentication')));
    });

    test(
        'Validate negative behaviour of deleting revoked enrollment from unAuthenticated connection',
        () async {
      String dummyEnrollId = '4750345034850983';
      String enrollmentKey =
          '$dummyEnrollId.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'dummy-sId-11', 'dummy-app-11', 'dummy-device-11', 'dummy-key-11')
        ..namespaces = {'test_namespace': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.revoked.name);
      AtData enrollAtData = AtData()..data = jsonEncode(enrollDataStoreValue);

      await keyValueStore.put(enrollmentKey, enrollAtData);

      inboundConnection.metadata.isAuthenticated = false;
      castMetadata(inboundConnection).enrollmentId = '1425365';
      castMetadata(inboundConnection).authType = AuthType.apkam;
      String enrollDeleteCommand =
          'enroll:delete:{"enrollmentId":"$dummyEnrollId"}';

      EnrollVerbHandler enrollVerb =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      var enrollVerbParams = enrollVerb.parse(enrollDeleteCommand);

      expect(
          () => enrollVerb.processVerb(
              response, enrollVerbParams, inboundConnection),
          throwsA(predicate((e) =>
              e.toString() ==
              'Exception: Cannot delete enrollment without authentication')));
    });

    test('Validate negative behaviour of deleting approved enrollment',
        () async {
      String dummyEnrollId = '345345345141';
      String enrollmentKey =
          '$dummyEnrollId.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'dummy-sId-2', 'dummy-app-2', 'dummy-device-2', 'dummy-key-2')
        ..namespaces = {'test_namespace-2': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      AtData enrollAtData = AtData()..data = jsonEncode(enrollDataStoreValue);
      await keyValueStore.put(enrollmentKey, enrollAtData);

      inboundConnection.metadata.isAuthenticated = true;
      inboundConnection.metadata.authType = AuthType.cram;
      castMetadata(inboundConnection).enrollmentId =
          await createAndPersistAnEnrollment('deleter', 'device',
              {'test_namespace-2': 'rw', '__manage': 'rw'});
      castMetadata(inboundConnection).authType = AuthType.apkam;
      String enrollDeleteCommand =
          'enroll:delete:{"enrollmentId":"$dummyEnrollId"}';

      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      var enrollVerbParams = enrollVerbHandler.parse(enrollDeleteCommand);
      expect(
          () => enrollVerbHandler.processVerb(
              response, enrollVerbParams, inboundConnection),
          throwsA(predicate((e) =>
              e.toString() ==
              'Exception: Failed to delete enrollment id: 345345345141 | Cause: Cannot delete approved enrollments. Only denied and revoked enrollments can be deleted')));
    });

    /// A target holding NO namespaces passes every per-namespace
    /// authorisation loop vacuously: zero iterations and no refusal.
    group('an enrollment holding no namespaces', () {
      Future<String> anEmptyTarget(
          {EnrollmentStatus status = EnrollmentStatus.revoked}) async {
        final id = Uuid().v4();
        await keyValueStore.put(
            enMgr.buildEnrollmentKey(id),
            AtData()
              ..data = jsonEncode(EnrollDataStoreValue(
                  'sid', 'empty-app', 'empty-device', 'empty-key')
                ..namespaces = <String, String>{}
                ..approval = EnrollApproval(status.name)),
            skipCommit: true);
        return id;
      }

      Future<void> runAs(String? callerId, String command,
          {AuthType authType = AuthType.apkam}) async {
        inboundConnection.metadata.isAuthenticated = true;
        castMetadata(inboundConnection).enrollmentId = callerId;
        castMetadata(inboundConnection).authType = authType;
        final h = EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
        await h.processVerb(response, h.parse(command), inboundConnection);
      }

      test('is not fetchable by a scoped caller', () async {
        final targetId = await anEmptyTarget();
        final appOnly = await createAndPersistAnEnrollment(
            'fetch-app', 'device', {'test_namespace': 'rw'});
        await expectLater(
            () => runAs(appOnly, 'enroll:fetch:{"enrollmentId":"$targetId"}'),
            throwsA(isA<UnAuthorizedException>()),
            reason: 'the loop deciding authority iterates the TARGET\'s '
                'grants, so an empty map passes with zero iterations and the '
                '__manage requirement inside it is never asked');
      });

      test('is not revocable by a scoped caller', () async {
        final targetId = await anEmptyTarget(status: EnrollmentStatus.approved);
        final appOnly = await createAndPersistAnEnrollment(
            'shared-app', 'device', {'test_namespace': 'rw'});
        await expectLater(
            () => runAs(appOnly, 'enroll:revoke:{"enrollmentId":"$targetId"}'),
            throwsA(isA<UnAuthorizedException>()),
            reason: 'approve, deny, revoke and unrevoke share one loop, and it '
                'passed an empty grant map vacuously');
      });

      test('a LEGACY connection naming none is refused', () async {
        inboundConnection.metadata.isAuthenticated = true;
        inboundConnection.metaData.authType = AuthType.pkamLegacy;
        castMetadata(inboundConnection).enrollmentId = null;
        final h = EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
        await expectLater(
            () => h.processVerb(
                response,
                h.parse('enroll:request:{"appName":"legacy-app",'
                    '"deviceName":"legacy-device","namespaces":{},'
                    '"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}",'
                    '"encryptedAPKAMSymmetricKey":"dummy_symm_key"}'),
                inboundConnection),
            throwsA(isA<IllegalArgumentException>().having((e) => e.message,
                'message', contains('At least one namespace'))),
            reason: 'a legacy connection gets no grants filled in on its '
                'behalf, so a request naming none would mint a record no '
                'caller can ever demonstrate authority over');
      });

      test('control: a CRAM connection may still act on it', () async {
        final targetId = await anEmptyTarget(status: EnrollmentStatus.approved);
        await runAs(null, 'enroll:revoke:{"enrollmentId":"$targetId"}',
            authType: AuthType.cram);
        expect(response.isError, false, reason: '${response.errorMessage}');
      });

      test('is not revocable by a legacy connection carrying primary',
          () async {
        final targetId = await anEmptyTarget(status: EnrollmentStatus.approved);
        await expectLater(
            () => runAs(EnrollmentManager.primaryEnrollmentId,
                'enroll:revoke:{"enrollmentId":"$targetId"}',
                authType: AuthType.pkamLegacy),
            throwsA(isA<UnAuthorizedException>()),
            reason: 'a legacy connection authenticates as an enrollment like '
                'any other, so it is not the CRAM connection the exemption is '
                'for and it cannot demonstrate authority over a target '
                'holding no namespaces');
      });

      test('is not revocable by an APKAM connection naming no enrollment',
          () async {
        final targetId = await anEmptyTarget(status: EnrollmentStatus.approved);
        await expectLater(
            () => runAs(null, 'enroll:revoke:{"enrollmentId":"$targetId"}'),
            throwsA(isA<UnAuthorizedException>()),
            reason: 'the exemption is for a CRAM connection, so it must be '
                'keyed on the auth type rather than inferred from a missing '
                'enrollment id');
      });

      /// Every stored enrollment id against the state its record holds.
      Future<Map<String, String?>> storedRoster() async {
        return {
          for (final (id, v) in await enMgr.storedEnrollments())
            id: v.approval?.state
        };
      }

      test('is not approvable, even from a CRAM connection', () async {
        final targetId = await anEmptyTarget(status: EnrollmentStatus.pending);
        final before = await storedRoster();
        await expectLater(
            () => runAs(
                null,
                'enroll:approve:{"enrollmentId":"$targetId",'
                    '"encryptedDefaultEncryptionPrivateKey":"dummy_private",'
                    '"encryptedDefaultSelfEncryptionKey":"dummy_self"}',
                authType: AuthType.cram),
            throwsA(isA<IllegalArgumentException>().having((e) => e.message,
                'message', contains('It holds no namespaces'))),
            reason: 'the CRAM exemption keeps such a record actionable, so '
                'approve must refuse on its own or that route would activate '
                'an enrollment granting nothing');
        expect(await storedRoster(), before,
            reason: 'the refusal is decided before the write, so the target '
                'is still pending and nothing else was stored');
      });

      test('cannot be the predecessor of a self-enrollment', () async {
        final predecessorId =
            await anEmptyTarget(status: EnrollmentStatus.approved);
        inboundConnection.metaData.sessionID = Uuid().v4();
        final before = await storedRoster();
        await expectLater(
            () => runAs(
                predecessorId,
                'enroll:request:{"appName":"retrofit-app",'
                    '"deviceName":"retrofit-device",'
                    '"apkamPublicKey":"dummy_apkam_key-${Uuid().v4()}"}'),
            throwsA(isA<UnAuthorizedException>().having((e) => e.message,
                'message', contains('holds no namespaces'))),
            reason: 'a self-enrollment carries exactly the grants of the '
                'enrollment it replaces, so an empty predecessor would mint '
                'an empty successor with no approver in the way');
        expect(await storedRoster(), before,
            reason: 'the refusal is decided before the write, so no successor '
                'enrollment was stored');
      });
    });

    /// `enroll:delete` destroys a record irreversibly, so it asks the caller
    /// for authority over the target, exactly as `enroll:fetch` does to READ
    /// one.
    group('enroll:delete authorisation', () {
      Future<String> aTarget(Map<String, String> namespaces,
          {EnrollmentStatus status = EnrollmentStatus.revoked}) async {
        final id = Uuid().v4();
        await keyValueStore.put(
            enMgr.buildEnrollmentKey(id),
            AtData()
              ..data = jsonEncode(EnrollDataStoreValue(
                  'sid', 'target-app', 'target-device', 'target-key')
                ..namespaces = namespaces
                ..approval = EnrollApproval(status.name)),
            skipCommit: true);
        return id;
      }

      Future<void> deleteAs(String? callerId, String targetId) async {
        inboundConnection.metadata.isAuthenticated = true;
        castMetadata(inboundConnection).enrollmentId = callerId;
        castMetadata(inboundConnection).authType =
            callerId == null ? AuthType.cram : AuthType.apkam;
        final h = EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
        await h.processVerb(
            response,
            h.parse('enroll:delete:{"enrollmentId":"$targetId"}'),
            inboundConnection);
      }

      test('a caller without access to the target\'s namespace is refused',
          () async {
        final targetId = await aTarget({'test_namespace': 'rw'});
        final outsider = await createAndPersistAnEnrollment(
            'outsider', 'device', {'other_namespace': 'rw', '__manage': 'rw'});

        await expectLater(() => deleteAs(outsider, targetId),
            throwsA(isA<UnAuthorizedException>()));

        // The control, on the SAME target: a caller that does hold the
        // namespace succeeds.
        final insider = await createAndPersistAnEnrollment(
            'insider', 'device', {'test_namespace': 'rw', '__manage': 'rw'});
        await deleteAs(insider, targetId);
        expect(response.data,
            '{"enrollmentId":"$targetId","status":"deleted"}');
      });

      test('a caller holding the namespace but not __manage is refused',
          () async {
        final targetId = await aTarget({'test_namespace': 'rw'});
        final appOnly = await createAndPersistAnEnrollment(
            'app-only', 'device', {'test_namespace': 'rw'});

        await expectLater(() => deleteAs(appOnly, targetId),
            throwsA(isA<UnAuthorizedException>()));
      });

      test('a caller may always delete its OWN enrollment', () async {
        final selfId = await createAndPersistAnEnrollment(
            'self', 'device', {'test_namespace': 'rw'});
        // Revoked, because only denied and revoked enrollments may be deleted.
        await keyValueStore.put(
            enMgr.buildEnrollmentKey(selfId),
            AtData()
              ..data = jsonEncode(EnrollDataStoreValue(
                  'sid', 'self', 'device', 'target-key')
                ..namespaces = {'test_namespace': 'rw'}
                ..approval = EnrollApproval(EnrollmentStatus.revoked.name)),
            skipCommit: true);

        await deleteAs(selfId, selfId);
        expect(response.data, '{"enrollmentId":"$selfId","status":"deleted"}');
      });

      test('a CRAM connection may delete any', () async {
        final targetId = await aTarget({'test_namespace': 'rw'});

        await deleteAs(null, targetId);
        expect(response.data,
            '{"enrollmentId":"$targetId","status":"deleted"}');
      });

      test('a target holding NO namespaces is refused, not passed vacuously',
          () async {
        final targetId = await aTarget({});

        final appOnly = await createAndPersistAnEnrollment(
            'app-only', 'device', {'other_namespace': 'rw'});
        await expectLater(() => deleteAs(appOnly, targetId),
            throwsA(isA<UnAuthorizedException>()));

        final root = await createAndPersistAnEnrollment(
            'root', 'device', {'*': 'rw', '__manage': 'rw'});
        await expectLater(() => deleteAs(root, targetId),
            throwsA(isA<UnAuthorizedException>()));

        // The control: the exemptions still apply, so the record is not
        // stranded.
        await deleteAs(null, targetId);
        expect(response.data,
            '{"enrollmentId":"$targetId","status":"deleted"}');
      });

      test('an unauthorised caller is refused before it learns the state',
          () async {
        final targetId = await aTarget({'test_namespace': 'rw'},
            status: EnrollmentStatus.approved);
        final outsider = await createAndPersistAnEnrollment(
            'outsider', 'device', {'other_namespace': 'rw', '__manage': 'rw'});

        await expectLater(
            () => deleteAs(outsider, targetId),
            throwsA(predicate((e) =>
                e is UnAuthorizedException &&
                !e.toString().contains('approved'))));
      });
    });

    tearDown(() async => await verbTestsTearDown());
  });

  group(
      'A group of tests to validate the commit log state when performing enrollment operations',
      () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test(
        'A test to verify commit log state during create approve revoke and delete an enrollment request',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      String otp = response.data!;

      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice"'
          ',"namespaces":{"buzz":"r"},"otp":"$otp"'
          ',"apkamPublicKey":"lorem_apkam"'
          ',"encryptedAPKAMSymmetricKey": "ipsum_apkam"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];

      String enrollmentKey = EnrollmentManager(keyValueStore, alice)
          .buildEnrollmentKey(enrollmentId);

      AtData? atData = await keyValueStore.get(enrollmentKey);
      expect(atData!.data!.isNotEmpty, true);
      var enrollmentDataMap = jsonDecode(atData.data!);
      expect(enrollmentDataMap['appName'], 'wavi');
      expect(enrollmentDataMap['deviceName'], 'mydevice');
      expect(enrollmentDataMap['namespaces'], {'buzz': 'r'});
      expect(enrollmentDataMap['apkamPublicKey'], 'lorem_apkam');

      AtCommitLog atCommitLog = atServer.commitLog;
      expect(await atCommitLog.iterate().isEmpty, true);

      String approveEnrollment =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey": "dummy_encrypted_default_encryption_private_key","encryptedDefaultSelfEncryptionKey":"dummy_encrypted_default_self_encryption_key"}';
      HashMap<String, String?> approveEnrollmentVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollment);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, approveEnrollmentVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['status'], 'approved');

      atCommitLog = atServer.commitLog;
      expect(await atCommitLog.iterate().isEmpty, true);

      enrollmentRequest = 'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      HashMap<String, String?> revokeEnrollmentVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      response = Response();
      enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, revokeEnrollmentVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['status'], 'revoked');

      atCommitLog = atServer.commitLog;
      expect(await atCommitLog.iterate().isEmpty, true);

      enrollmentRequest = 'enroll:delete:{"enrollmentId":"$enrollmentId"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      response = Response();
      enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      expect(jsonDecode(response.data!)['status'], 'deleted');

      atCommitLog = atServer.commitLog;
      expect(await atCommitLog.iterate().isEmpty, true);

      expect(() async => await keyValueStore.get(enrollmentKey),
          throwsA(predicate((dynamic e) => e is KeyNotFoundException)));
    });

    test(
        'A test to verify commit log state during create deny and delete an enrollment request',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      String otp = response.data!;

      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice"'
          ',"namespaces":{"buzz":"r"},"otp":"$otp"'
          ',"apkamPublicKey":"lorem_apkam"'
          ',"encryptedAPKAMSymmetricKey": "ipsum_apkam"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = false;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];

      String enrollmentKey = EnrollmentManager(keyValueStore, alice)
          .buildEnrollmentKey(enrollmentId);

      AtData? atData = await keyValueStore.get(enrollmentKey);
      expect(atData!.data!.isNotEmpty, true);
      var enrollmentDataMap = jsonDecode(atData.data!);
      expect(enrollmentDataMap['appName'], 'wavi');
      expect(enrollmentDataMap['deviceName'], 'mydevice');
      expect(enrollmentDataMap['namespaces'], {'buzz': 'r'});
      expect(enrollmentDataMap['apkamPublicKey'], 'lorem_apkam');

      AtCommitLog atCommitLog = atServer.commitLog;
      expect(await atCommitLog.iterate().isEmpty, true);

      enrollmentRequest = 'enroll:deny:{"enrollmentId":"$enrollmentId"}';
      HashMap<String, String?> denyEnrollmentVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      response = Response();
      enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, denyEnrollmentVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['status'], 'denied');

      atCommitLog = atServer.commitLog;
      expect(await atCommitLog.iterate().isEmpty, true);

      enrollmentRequest = 'enroll:delete:{"enrollmentId":"$enrollmentId"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.sessionID = 'dummy_session';
      response = Response();
      enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      expect(jsonDecode(response.data!)['status'], 'deleted');

      atCommitLog = atServer.commitLog;
      expect(await atCommitLog.iterate().isEmpty, true);

      expect(() async => await keyValueStore.get(enrollmentKey),
          throwsA(predicate((dynamic e) => e is KeyNotFoundException)));
    });

    tearDown(() async => await verbTestsTearDown());
  });

  group('enroll:listns discovery + _apsk + request metadata', () {
    final etu = ETU();
    setUp(() async {
      await verbTestsSetUp();
      await etu.init();
    });
    tearDown(() async {
      await verbTestsTearDown();
    });

    test(
        'getEnrollmentsForNamespace returns apkamPubKey + metadata, '
        'approved-only, honours suffix/* match', () async {
      final (enIds, _) = await etu.createEnrollments(n: 2);

      final ev0 = await enMgr.getEnrollmentById(enIds[0]);
      ev0.metadata = {
        'keyPackage': {'v': 1, 'keys': []}
      };
      await enMgr.put(enIds[0], AtData()..data = jsonEncode(ev0.toJson()),
          EnrollmentStatus.approved);

      final pending = await etu.createPendingEnrollment(
          appName: 'pend',
          deviceName: 't',
          namespaces: {'test': 'r'},
          apkamKeysExpiryDuration: null);

      final members = await enMgr.getEnrollmentsForNamespace('test');
      final ids = members.map((m) => m['enrollmentId']).toSet();
      expect(ids.contains(enIds[0]), true);
      expect(ids.contains(enIds[1]), true);
      expect(ids.contains(pending), false);
      for (final m in members) {
        expect(m['apkamPubKey'], isNotNull);
        expect(m.containsKey('access'), true);
      }
      final m0 = members.firstWhere((m) => m['enrollmentId'] == enIds[0]);
      expect(m0['apkamPubKey'], 'apkam public key app_1 test');
      expect(m0['access'], 'r');
      expect(m0['metadata'], {
        'keyPackage': {'v': 1, 'keys': []}
      });
      final m1 = members.firstWhere((m) => m['enrollmentId'] == enIds[1]);
      expect(m1['metadata'], isNull);
    });

    test(
        'enroll:listns serves the roster to a caller with >=r and refuses '
        'a caller without access to the namespace', () async {
      final (enIds, _) = await etu.createEnrollments(n: 2);

      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.enrollmentId = enIds[0];
      inboundConnection.metaData.authType = AuthType.apkam;
      final okResp = Response();
      await etu.evh.processVerb(
          okResp,
          HashMap<String, String?>.from(
              {'operation': 'listns', 'listNamespace': 'test'}),
          inboundConnection);
      expect(okResp.isError, false);
      final roster = jsonDecode(okResp.data!) as List;
      expect(roster.any((m) => m['apkamPubKey'] != null), true);

      inboundConnection.metaData.enrollmentId = enIds[1];
      inboundConnection.metaData.authType = AuthType.apkam;
      await expectLater(
          etu.evh.processVerb(
              Response(),
              HashMap<String, String?>.from(
                  {'operation': 'listns', 'listNamespace': 'app_1'}),
              inboundConnection),
          throwsA(isA<UnAuthorizedException>()));
    });

    test(
        'the client-composed apsk is published VERBATIM on approval '
        '(CRAM + enroll:approve)', () async {
      final composed = {
        'v': 7,
        'signingAlgo': 'some-algo-this-server-never-heard-of',
        'publicKey': 'Y2xpZW50LWNvbXBvc2Vk',
        'extraFieldTheServerMustNotDrop': ['a', 'b'],
      };

      // The CRAM auto-approve path.
      final cramEnId = await etu.createPrimaryEnrollment(apsk: composed);
      final cramKey = 'public:_apsk.$cramEnId'
          '.${EnrollmentConstants.perEnrollmentApproved}$alice';
      expect(await keyValueStore.exists(cramKey), true);
      expect(jsonDecode((await keyValueStore.get(cramKey))!.data!), composed);

      // The standard enroll:approve path.
      final pendingEnId = await etu.createPendingEnrollment(
          appName: 'apskApp',
          deviceName: 'd',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null,
          apsk: composed);
      final pendingKey = 'public:_apsk.$pendingEnId'
          '.${EnrollmentConstants.perEnrollmentApproved}$alice';
      expect(await keyValueStore.exists(pendingKey), false,
          reason: 'nothing is published while the enrollment is only pending');

      await etu.approveEnrollment(etu.primaryEnId, pendingEnId);
      expect(await keyValueStore.exists(pendingKey), true);
      expect(jsonDecode((await keyValueStore.get(pendingKey))!.data!), composed);
    });

    test('an enrollment that sends no apsk gets no _apsk record at all',
        () async {
      final (enIds, _) = await etu.createEnrollments(n: 1);
      final apskKey = 'public:_apsk.${enIds[0]}'
          '.${EnrollmentConstants.perEnrollmentApproved}$alice';
      expect(await keyValueStore.exists(apskKey), false);

      final primaryApsk = 'public:_apsk.${etu.primaryEnId}'
          '.${EnrollmentConstants.perEnrollmentApproved}$alice';
      expect(await keyValueStore.exists(primaryApsk), false);
    });

    /// Submits an unauthenticated `enroll:request` built from [ep] and
    /// returns the future, so a caller can assert on how it is refused.
    Future<void> submitRequest(EnrollParams ep) async {
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.authType = null;
      inboundConnection.metaData.sessionID =
          DateTime.now().millisecondsSinceEpoch.toString();
      await etu.evh.processVerb(
          Response(),
          getVerbParam(
              VerbSyntax.enroll, 'enroll:request:${jsonEncode(ep.toJson())}'),
          inboundConnection);
    }

    /// An `enroll:request` params object with everything mandatory filled in
    /// and a fresh OTP, ready for a size arm to load up.
    Future<EnrollParams> sizedRequest(String appName) async {
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      final otp = await etu.getOtp();
      return EnrollParams()
        ..appName = appName
        ..deviceName = 'd'
        ..apkamPublicKey = 'apkam pub'
        ..encryptedAPKAMSymmetricKey = 'encrypted apkam aes key'
        ..namespaces = {'wavi': 'rw'}
        ..otp = otp;
    }

    /// Matches only a refusal that names the size bound.
    final refusedForSize = throwsA(isA<IllegalArgumentException>().having(
        (e) => e.message,
        'message',
        anyOf(contains('enrollment record is'), contains('enroll params are'))));

    test('a record over the cap is refused, and creates no enrollment',
        () async {
      final before = (await enMgr.getEnrollmentsAsJson(redactSecrets: false)).length;
      final ep = await sizedRequest('tooBig')
        ..apsk = {
          'publicKey': 'x' * (EnrollVerbHandler.maxEnrollmentRecordBytes + 1)
        };

      await expectLater(submitRequest(ep), refusedForSize);

      expect((await enMgr.getEnrollmentsAsJson(redactSecrets: false)).length, before,
          reason: 'the refusal lands before the record is created, so an '
              'oversized value cannot leave a half-made enrollment behind');
    });

    test('an oversized request does not spend the OTP', () async {
      final ep = await sizedRequest('otpPreserved')
        ..apsk = {
          'publicKey': 'x' * (EnrollVerbHandler.maxEnrollmentRecordBytes + 1)
        };
      final otp = ep.otp!;

      await expectLater(submitRequest(ep), refusedForSize);

      await submitRequest(EnrollParams()
        ..appName = 'otpPreserved'
        ..deviceName = 'd2'
        ..apkamPublicKey = 'apkam pub'
        ..encryptedAPKAMSymmetricKey = 'encrypted apkam aes key'
        ..namespaces = {'wavi': 'rw'}
        ..otp = otp);
    });

    test('the cap covers metadata, not just apsk', () async {
      final before = (await enMgr.getEnrollmentsAsJson(redactSecrets: false)).length;
      final ep = await sizedRequest('bigMetadata')
        ..metadata = {
          'keyPackage': {
            'pub': 'x' * (EnrollVerbHandler.maxEnrollmentRecordBytes + 1)
          }
        };

      await expectLater(submitRequest(ep), refusedForSize);
      expect((await enMgr.getEnrollmentsAsJson(redactSecrets: false)).length, before);
    });

    test('the cap counts the whole record, not each field separately',
        () async {
      final half = EnrollVerbHandler.maxEnrollmentRecordBytes ~/ 2;
      final before = (await enMgr.getEnrollmentsAsJson(redactSecrets: false)).length;
      final ep = await sizedRequest('sumOverCap')
        ..apsk = {'publicKey': 'x' * half}
        ..metadata = {
          'keyPackage': {'pub': 'x' * half}
        };
      expect(utf8.encode(jsonEncode(ep.apsk)).length <
              EnrollVerbHandler.maxEnrollmentRecordBytes,
          true,
          reason: 'neither field alone may exceed the cap, or the arm is '
              'testing the per-field bound it is meant to distinguish from');

      await expectLater(submitRequest(ep), refusedForSize);
      expect((await enMgr.getEnrollmentsAsJson(redactSecrets: false)).length, before);
    });

    test('a record comfortably under the cap is accepted and published',
        () async {
      final atCap = {'publicKey': 'x' * (100 * 1024)};

      final enId = await etu.createPendingEnrollment(
          appName: 'underCap',
          deviceName: 'd',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null,
          apsk: atCap);
      await etu.approveEnrollment(etu.primaryEnId, enId);
      final apskKey = 'public:_apsk.$enId'
          '.${EnrollmentConstants.perEnrollmentApproved}$alice';
      expect(jsonDecode((await keyValueStore.get(apskKey))!.data!), atCap);
    });

    test('an approver cannot substitute the apsk it publishes for an enrollee',
        () async {
      final enrolleeApsk = {'v': 1, 'publicKey': 'the-enrollees-own-key'};
      final enId = await etu.createPendingEnrollment(
          appName: 'substApp',
          deviceName: 'd',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null,
          apsk: enrolleeApsk);

      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.enrollmentId = etu.primaryEnId;
      inboundConnection.metaData.authType = AuthType.apkam;
      final approve = EnrollParams()
        ..enrollmentId = enId
        ..encryptedDefaultEncryptionPrivateKey = 'encrypted priv'
        ..encryptedDefaultSelfEncryptionKey = 'encrypted self'
        ..apsk = {'v': 1, 'publicKey': 'an-approver-substituted-key'};
      final r = Response();
      await etu.evh.processVerb(
          r,
          getVerbParam(
              VerbSyntax.enroll, 'enroll:approve:${jsonEncode(approve.toJson())}'),
          inboundConnection);
      expect(r.isError, false);

      final apskKey = 'public:_apsk.$enId'
          '.${EnrollmentConstants.perEnrollmentApproved}$alice';
      expect(jsonDecode((await keyValueStore.get(apskKey))!.data!), enrolleeApsk);
    });

    test('apskLegacy is published as the BARE string, never JSON-encoded',
        () async {
      // ⚠️ WIRE PIN. Every deployed _apsk consumer base64-decodes the value
      // as an RSA key, so the assertion is on the raw stored bytes.
      const bare = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAtestkey';

      // The CRAM auto-approve path.
      final cramEnId = await etu.createPrimaryEnrollment(apskLegacy: bare);
      final cramKey = 'public:_apsk.$cramEnId'
          '.${EnrollmentConstants.perEnrollmentApproved}$alice';
      final cramStored = (await keyValueStore.get(cramKey))!.data!;
      expect(cramStored, bare);
      expect(cramStored, isNot(jsonEncode(bare)),
          reason: 'a quoted string is not what a bare-RSA parser reads');

      // The standard enroll:approve path.
      final pendingEnId = await etu.createPendingEnrollment(
          appName: 'apskLegacyApp',
          deviceName: 'd',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null,
          apskLegacy: bare);
      final pendingKey = 'public:_apsk.$pendingEnId'
          '.${EnrollmentConstants.perEnrollmentApproved}$alice';
      expect(await keyValueStore.exists(pendingKey), false,
          reason: 'nothing is published while the enrollment is only pending');

      await etu.approveEnrollment(etu.primaryEnId, pendingEnId);
      expect((await keyValueStore.get(pendingKey))!.data!, bare);

      final enVal = await enMgr.getEnrollmentById(pendingEnId);
      expect(enVal.apskLegacy, bare);
      expect(enVal.apsk, isNull);
    });

    test('a request carrying BOTH apsk and apskLegacy is refused, and creates '
        'no enrollment', () async {
      final before = (await enMgr.getEnrollmentsAsJson(redactSecrets: false)).length;

      await expectLater(
          etu.createPendingEnrollment(
              appName: 'bothShapes',
              deviceName: 'd',
              namespaces: {'wavi': 'rw'},
              apkamKeysExpiryDuration: null,
              apsk: {'v': 1, 'keys': []},
              apskLegacy: 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A'),
          // Matched on the message, not just the type: several unrelated
          // refusals on this path are the same exception class.
          throwsA(isA<IllegalArgumentException>().having(
              (e) => e.message, 'message', contains('mutually exclusive'))));

      expect((await enMgr.getEnrollmentsAsJson(redactSecrets: false)).length, before,
          reason: 'the refusal lands before the record is created');
    });

    test('an apskLegacy over the cap is refused, and creates no enrollment',
        () async {
      final overCap = 'x' * (EnrollVerbHandler.maxEnrollmentRecordBytes + 1);
      final before = (await enMgr.getEnrollmentsAsJson(redactSecrets: false)).length;

      await expectLater(
          etu.createPendingEnrollment(
              appName: 'legacyTooBig',
              deviceName: 'd',
              namespaces: {'wavi': 'rw'},
              apkamKeysExpiryDuration: null,
              apskLegacy: overCap),
          refusedForSize);

      expect((await enMgr.getEnrollmentsAsJson(redactSecrets: false)).length, before);
    });

    test('metadata + signingAlgo on enroll:request are persisted on the record',
        () async {
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      final otp = await etu.getOtp();
      final reqJson = {
        'appName': 'metaApp',
        'deviceName': 'd',
        'apkamPublicKey': 'apkam meta pub',
        'encryptedAPKAMSymmetricKey': 'enc aes',
        'namespaces': {'wavi': 'rw'},
        'otp': otp,
        'signingAlgo': 'mldsa65',
        'apsk': {'v': 1, 'signingAlgo': 'mldsa65', 'publicKey': 'bWxkc2E='},
        'metadata': {
          'keyPackage': {
            'v': 1,
            'keys': [
              {'kid': 'k', 'use': 'enc', 'alg': 'x-wing', 'pub': 'p'}
            ]
          }
        },
      };
      inboundConnection.metaData.isAuthenticated = false;
      inboundConnection.metaData.authType = null;
      inboundConnection.metaData.sessionID =
          DateTime.now().millisecondsSinceEpoch.toString();
      final r = Response();
      await etu.evh.processVerb(
          r,
          getVerbParam(
              VerbSyntax.enroll, 'enroll:request:${jsonEncode(reqJson)}'),
          inboundConnection);
      expect(r.isError, false);
      final enId = jsonDecode(r.data!)['enrollmentId'];
      final ev = await enMgr.getEnrollmentById(enId);
      expect(ev.signingAlgo, 'mldsa65');
      expect(ev.apsk,
          {'v': 1, 'signingAlgo': 'mldsa65', 'publicKey': 'bWxkc2E='});
      expect(ev.metadata, {
        'keyPackage': {
          'v': 1,
          'keys': [
            {'kid': 'k', 'use': 'enc', 'alg': 'x-wing', 'pub': 'p'}
          ]
        }
      });
    });
  });

  group('enroll:update', () {
    final etu = ETU();
    setUp(() async {
      await verbTestsSetUp();
      await etu.init();
    });

    tearDown(() async {
      await verbTestsTearDown();
    });

    /// Signs `<enrollmentId>|<apkamPublicKey>|<signingAlgo>` with [keyPair]'s
    /// private half, the way a client rotating its key must.
    String popSignature(
        AtPkamKeyPair keyPair, String enId, String pub, String algo) {
      final input = AtSigningInput('$enId|$pub|$algo')
        ..signingAlgoType = SigningAlgoType.rsa2048
        ..hashingAlgoType = HashingAlgoType.sha256
        ..signingMode = AtSigningMode.pkam;
      return AtChopsImpl(AtChopsKeys.create(null, keyPair)).sign(input).result;
    }

    Future<Response> sendUpdate(String asEnrollmentId, EnrollParams p) async {
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.enrollmentId = asEnrollmentId;
      inboundConnection.metaData.authType = AuthType.apkam;
      final r = Response();
      await etu.evh.processVerb(
        r,
        getVerbParam(VerbSyntax.enroll, 'enroll:update:${jsonEncode(p.toJson())}'),
        inboundConnection,
      );
      return r;
    }

    test('a valid rotation replaces the key, and an invalid one does not', () async {
      final enId = (await etu.createEnrollments(n: 1)).$1.first;
      final newPair = AtChopsUtil.generateAtPkamKeyPair();
      final newPub = newPair.atPublicKey.publicKey;

      // Reject arm: signed by a DIFFERENT key than the one being installed.
      final wrongPair = AtChopsUtil.generateAtPkamKeyPair();
      await expectLater(
        sendUpdate(
            enId,
            EnrollParams()
              ..enrollmentId = enId
              ..apkamPublicKey = newPub
              ..signingAlgo = 'rsa2048'
              ..apkamPublicKeySignature =
                  popSignature(wrongPair, enId, newPub, 'rsa2048')),
        throwsA(isA<AtEnrollmentException>()),
      );
      expect((await etu.evh.enMgr.getEnrollmentById(enId)).apkamPublicKey,
          isNot(newPub),
          reason: 'a refused rotation must not have written anything');

      // Accept arm: signed by the key being installed.
      final r = await sendUpdate(
          enId,
          EnrollParams()
            ..enrollmentId = enId
            ..apkamPublicKey = newPub
            ..signingAlgo = 'rsa2048'
            ..apkamPublicKeySignature =
                popSignature(newPair, enId, newPub, 'rsa2048'));
      expect(r.isError, false);
      final enVal = await etu.evh.enMgr.getEnrollmentById(enId);
      expect(enVal.apkamPublicKey, newPub);
      expect(enVal.signingAlgo, 'rsa2048');
      expect(enVal.approval!.state, EnrollmentStatus.approved.name,
          reason: 'a rotation must not move the enrollment lifecycle');
    });

    test('a revoke landing during the update is not undone', () async {
      // NOTE the window is REPRODUCED rather than raced: revoking straight on
      // the keystore leaves the manager's cached snapshot saying approved.
      final enId = (await etu.createEnrollments(n: 1)).$1.first;
      final newPair = AtChopsUtil.generateAtPkamKeyPair();
      final newPub = newPair.atPublicKey.publicKey;

      await etu.evh.enMgr.getEnrollmentById(enId);

      final key = etu.evh.enMgr.buildEnrollmentKey(enId);
      final onDisk = await keyValueStore.get(key);
      final v = EnrollDataStoreValue.fromJson(jsonDecode(onDisk!.data!));
      v.approval = EnrollApproval(EnrollmentStatus.revoked.name);
      onDisk.data = jsonEncode(v.toJson());
      await keyValueStore.put(key, onDisk);

      await expectLater(
        sendUpdate(
            enId,
            EnrollParams()
              ..enrollmentId = enId
              ..apkamPublicKey = newPub
              ..signingAlgo = 'rsa2048'
              ..apkamPublicKeySignature =
                  popSignature(newPair, enId, newPub, 'rsa2048')),
        throwsA(isA<AtEnrollmentException>()),
        reason: 'the status is read off the record immediately before the '
            'write, so a revoke that landed while the request was in flight '
            'refuses the update rather than being written back as approved',
      );

      final after = EnrollDataStoreValue.fromJson(
          jsonDecode((await keyValueStore.get(key))!.data!));
      expect(after.approval?.state, EnrollmentStatus.revoked.name,
          reason: 'the revocation stands');
      expect(after.apkamPublicKey, isNot(newPub),
          reason: 'and nothing of the refused rotation was written');
    });

    test('an mldsa65 rotation proves possession of the ML-DSA key', () async {
      final enId = (await etu.createEnrollments(n: 1)).$1.first;
      final newKey = await MlDsa65PureDartAlgo().generateKeyPair();
      final wrongKey = await MlDsa65PureDartAlgo().generateKeyPair();
      final newPub = base64Encode(newKey.publicKey);
      final signable = utf8.encode('$enId|$newPub|mldsa65');

      EnrollParams rotation(String signature) => EnrollParams()
        ..enrollmentId = enId
        ..apkamPublicKey = newPub
        ..signingAlgo = 'mldsa65'
        ..apkamPublicKeySignature = signature;

      // Reject arm: signed by a different ML-DSA key than the one installed.
      await expectLater(
        sendUpdate(
            enId,
            rotation(base64Encode(await MlDsa65PureDartAlgo()
                .signBytes(signable, secretKey: wrongKey.secretKey)))),
        throwsA(isA<AtEnrollmentException>()),
      );
      expect((await etu.evh.enMgr.getEnrollmentById(enId)).apkamPublicKey,
          isNot(newPub),
          reason: 'a refused rotation must not have written anything');

      // Accept arm: the control proving the refusal was about the signature.
      final r = await sendUpdate(
          enId,
          rotation(base64Encode(await MlDsa65PureDartAlgo()
              .signBytes(signable, secretKey: newKey.secretKey))));
      expect(r.isError, false);
      final enVal = await etu.evh.enMgr.getEnrollmentById(enId);
      expect(enVal.apkamPublicKey, newPub);
      expect(enVal.signingAlgo, 'mldsa65');
    });

    test('changing apkamPublicKey without a signature is refused', () async {
      final enId = (await etu.createEnrollments(n: 1)).$1.first;
      await expectLater(
        sendUpdate(
            enId,
            EnrollParams()
              ..enrollmentId = enId
              ..apkamPublicKey = 'a key nobody proved they hold'),
        throwsA(isA<AtEnrollmentException>()),
      );
    });

    test('enroll:update is self-only', () async {
      final enIds = (await etu.createEnrollments(n: 2)).$1;
      await expectLater(
        sendUpdate(
            enIds[0],
            EnrollParams()
              ..enrollmentId = enIds[1]
              ..metadata = {'anything': 'at all'}),
        throwsA(isA<AtEnrollmentException>()),
        reason: 'one enrollment must not amend another',
      );
    });

    test('...and an ID-LESS connection is refused, not waved through',
        () async {
      final enId = (await etu.createEnrollments(n: 1)).$1.first;

      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metaData.enrollmentId = null;
      final r = Response();
      await expectLater(
        etu.evh.processVerb(
          r,
          getVerbParam(
              VerbSyntax.enroll,
              'enroll:update:${jsonEncode((EnrollParams()
                    ..enrollmentId = enId
                    ..metadata = {'anything': 'at all'})
                  .toJson())}'),
          inboundConnection,
        ),
        throwsA(isA<AtEnrollmentException>()),
        reason: 'an owner connection names no enrollment, so it cannot be the '
            'enrollment this record belongs to — and it cannot sign anything '
            'with that enrollment\'s APKAM private half either, so a write it '
            'made would fail every reader\'s verification and buy only a '
            'denial of service',
      );
      expect((await etu.evh.enMgr.getEnrollmentById(enId)).metadata, isNull,
          reason: 'refused before anything was written');
    });

    test('enroll:update cannot change namespaces', () async {
      final enId = (await etu.createEnrollments(n: 1)).$1.first;
      await expectLater(
        sendUpdate(
            enId,
            EnrollParams()
              ..enrollmentId = enId
              ..namespaces = {'__manage': 'rw'}),
        throwsA(isA<IllegalArgumentException>()),
      );
    });

    test('metadata is a per-key set, not a whole-map replace', () async {
      final enId = (await etu.createEnrollments(n: 1)).$1.first;

      await sendUpdate(
          enId,
          EnrollParams()
            ..enrollmentId = enId
            ..metadata = {'first': 'one', 'second': 'two'});
      await sendUpdate(
          enId,
          EnrollParams()
            ..enrollmentId = enId
            ..metadata = {'second': 'changed'});

      final md = (await etu.evh.enMgr.getEnrollmentById(enId)).metadata!;
      expect(md['second'], 'changed');
      expect(md['first'], 'one',
          reason: 'a key the second request did not name must survive: a '
              'whole-map replace would clobber a sibling field the caller '
              'does not know about');
    });

    test('an update naming nothing to change is refused', () async {
      final enId = (await etu.createEnrollments(n: 1)).$1.first;
      await expectLater(
        sendUpdate(enId, EnrollParams()..enrollmentId = enId),
        throwsA(isA<IllegalArgumentException>()),
      );
    });

    test('apsk is republished when the update carries one', () async {
      final enId = (await etu.createEnrollments(n: 1)).$1.first;
      final apsk = {
        'v': 1,
        'keys': [
          {'use': 'sign', 'alg': 'mldsa65', 'pub': 'bmV3', 'status': 'active'}
        ]
      };

      final r = await sendUpdate(
          enId, EnrollParams()..enrollmentId = enId..apsk = apsk);
      expect(r.isError, false);

      final published = await etu.evh.keyStore.get(
          'public:_apsk.$enId.${EnrollmentConstants.perEnrollmentApproved}$alice');
      expect(jsonDecode(published!.data!), apsk);
    });

    test('an update that moves an enrollment between the two shapes clears the '
        'one it left', () async {
      const bare = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A';
      final array = {
        'v': 1,
        'keys': [
          {'kid': 'k', 'use': 'sign', 'alg': 'mldsa65', 'pub': 'bmV3'}
        ]
      };
      final apskKey =
          'public:_apsk.\$id.${EnrollmentConstants.perEnrollmentApproved}$alice';

      final enId = (await etu.createEnrollments(n: 1)).$1.first;
      final key = apskKey.replaceFirst('\$id', enId);

      expect(
          (await sendUpdate(
                  enId, EnrollParams()..enrollmentId = enId..apskLegacy = bare))
              .isError,
          false);
      expect((await etu.evh.keyStore.get(key))!.data!, bare);
      expect((await enMgr.getEnrollmentById(enId)).apskLegacy, bare);

      expect(
          (await sendUpdate(
                  enId, EnrollParams()..enrollmentId = enId..apsk = array))
              .isError,
          false);
      expect(jsonDecode((await etu.evh.keyStore.get(key))!.data!), array);
      final afterArray = await enMgr.getEnrollmentById(enId);
      expect(afterArray.apsk, array);
      expect(afterArray.apskLegacy, isNull,
          reason: 'the shape it left must not linger on the record');

      expect(
          (await sendUpdate(
                  enId, EnrollParams()..enrollmentId = enId..apskLegacy = bare))
              .isError,
          false);
      expect((await etu.evh.keyStore.get(key))!.data!, bare);
      final afterBare = await enMgr.getEnrollmentById(enId);
      expect(afterBare.apskLegacy, bare);
      expect(afterBare.apsk, isNull);
    });

    test('an update carrying BOTH shapes is refused', () async {
      final enId = (await etu.createEnrollments(n: 1)).$1.first;
      await expectLater(
        sendUpdate(
            enId,
            EnrollParams()
              ..enrollmentId = enId
              ..apsk = {'v': 1, 'keys': []}
              ..apskLegacy = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A'),
        // On the message, not just the type: the same exception class is
        // reused by other refusals here.
        throwsA(isA<IllegalArgumentException>().having(
            (e) => e.message, 'message', contains('mutually exclusive'))),
      );
    });

    test('an update is refused when the MERGED record would exceed the cap',
        () async {
      final enId = (await etu.createEnrollments(n: 1)).$1.first;
      final chunk = EnrollVerbHandler.maxEnrollmentRecordBytes ~/ 2;

      final first = await sendUpdate(
          enId,
          EnrollParams()
            ..enrollmentId = enId
            ..metadata = {'first': 'x' * chunk});
      expect(first.isError, false,
          reason: 'the first half must be accepted, or the second is not '
              'testing the merge');

      await expectLater(
        sendUpdate(
            enId,
            EnrollParams()
              ..enrollmentId = enId
              ..metadata = {'second': 'x' * chunk}),
        throwsA(isA<IllegalArgumentException>().having((e) => e.message,
            'message', contains('enrollment record is'))),
      );
    });

    test('an update naming ONLY apskLegacy is accepted', () async {
      final enId = (await etu.createEnrollments(n: 1)).$1.first;
      const bare = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A';
      final r = await sendUpdate(
          enId, EnrollParams()..enrollmentId = enId..apskLegacy = bare);
      expect(r.isError, false);
      expect((await enMgr.getEnrollmentById(enId)).apskLegacy, bare);
    });
  });

  group('CRAM auto-approve leaves the flat credential alone', () {
    final etu = ETU();
    setUp(() async {
      await verbTestsSetUp();
      await etu.init(withPrimaryEnrollment: false);
      // NOTE the flat credential is seeded AFTER etu.init().
      await keyValueStore.put(AtConstants.atPkamPublicKey,
          AtData()..data = 'the-flat-pkam-key',
          skipCommit: true);
    });

    tearDown(() async {
      await verbTestsTearDown();
    });

    test('an auto-approved enrollment does not become the flat credential',
        () async {
      final ep = EnrollParams()
        ..appName = 'cram-app'
        ..deviceName = 'cram-device'
        ..apkamPublicKey = 'a fresh apkam public key';
      inboundConnection.metaData
        ..isAuthenticated = true
        ..authType = AuthType.cram
        ..sessionID = DateTime.now().millisecondsSinceEpoch.toString();
      inboundConnection.metadata.enrollmentId = null;

      final r = Response();
      await etu.evh.processVerb(
        r,
        getVerbParam(
            VerbSyntax.enroll, 'enroll:request:${jsonEncode(ep.toJson())}'),
        inboundConnection,
      );

      expect(r.isError, isFalse, reason: '${r.errorMessage}');
      final m = jsonDecode(r.data!);
      expect(m['status'], EnrollmentStatus.approved.name,
          reason: 'CRAM is auto-approved; at_auth throws unless a first '
              'enrollment comes back approved');
      final created = await enMgr.getEnrollmentById(m['enrollmentId']);
      expect(created.retrofitPredecessorEnrollmentId, isNull,
          reason: 'auto-approve MINTS an enrollment; it does not replace one');

      // ⚠️ RAW LITERAL, byte for byte: the whole claim is that this value is
      // untouched.
      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          'the-flat-pkam-key',
          reason: 'the flat credential is untouched — an enrollment key that '
              'landed here would authenticate with no enrollment id, giving '
              'one keypair an identity its own revocation cannot reach');
    });
  });
}
