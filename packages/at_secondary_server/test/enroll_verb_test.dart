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

/// Utility functions which support the "Per-enrollment data" and
/// "Enrollments datastore consistency" test groups are in
/// enrollment_test_utils.dart
///
/// General utility functions which support executing full-stack verb unit
/// tests are in test_utils.dart
///
/// TODO Update other groups of tests here to use these functions to reduce
/// the volume of duplicated test code
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
      // Set up the enrollment
      final String enrollmentId = (await etu.createEnrollments(n: 1)).$1.first;

      // set up the connection
      inboundConnection.metadata.isAuthenticated = true;
      inboundConnection.metadata.enrollmentId = enrollmentId;

      // Update a self key in the per-enrollment namespace
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

      // Verify that this connection can look it up
      final selfLookupResponse = Response();
      await etu.lvh.processVerb(
        selfLookupResponse,
        getVerbParam(VerbSyntax.lookup, 'lookup:$key'),
        inboundConnection,
      );
      expect(selfLookupResponse.data, 'private value');

      // Verify that an unauthenticated connection cannot look it up
      await expectLater(
          etu.lvh.processVerb(
            Response(),
            getVerbParam(VerbSyntax.lookup, 'lookup:$key'),
            DummyInboundConnection(),
          ),
          throwsA(predicate((dynamic e) => e is KeyNotFoundException)));
      // Verify that an unauthenticated connection cannot look it up
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
      // Set up the enrollments
      final List<String> enIds = (await etu.createEnrollments(n: 2)).$1;
      final String enId1 = enIds[0];
      final String enId2 = enIds[1];

      // set up the connection
      inboundConnection.metadata.isAuthenticated = true;
      inboundConnection.metadata.enrollmentId = enId1;

      // Execute an update as enId1 for key in the reserved namespace of enId2
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
      // Set up the enrollment
      final String enrollmentId = (await etu.createEnrollments(n: 1)).$1.first;
      // set up the connection
      inboundConnection.metadata.isAuthenticated = true;
      inboundConnection.metadata.enrollmentId = enrollmentId;

      // create the data
      String key = 'something_public'
          '.${AbstractVerbHandler.enrollmentReservedNamespace(enrollmentId)}'
          '$alice';
      // Execute an update against the enrollmentReservedNamespace
      final updateResponse = Response();
      await etu.uvh.processVerb(
          updateResponse,
          getVerbParam(
              VerbSyntax.update, 'update:public:$key some public value'),
          inboundConnection);
      expect(updateResponse.data, isNotNull);
      expect(updateResponse.isError, false);

      // now look it up via an unauthenticated connection
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
      // 1. make enrollment with imminent expiry
      String enId =
          (await etu.createEnrollments(n: 1, m: 1, ttl: ttl)).$1.first;
      // 2. Make some stuff in a.__e
      var (keys, values) = await etu.createSomePerEnrollmentData(enId);
      // 2a. Verify everything is in a.__e
      for (final k in keys) {
        expect(await keyValueStore.exists(k), true);
      }
      // 3. Run expired keys cleanup
      await Future.delayed(Duration(milliseconds: ttl + 1));
      await keyValueStore.deleteExpiredKeys();

      // 4. Verify nothing in a.__e
      for (final k in keys) {
        expect(await keyValueStore.exists(k), false);
      }

      // 5. Verify all in d.__e
      for (final k in keys.map((k) => k.replaceAll(
          '${EnrollmentConstants.perEnrollmentApproved}@',
          '${EnrollmentConstants.perEnrollmentDeleted}@'))) {
        expect(await keyValueStore.exists(k), true);
      }
    }, timeout: Timeout(Duration(minutes: 5)));

    test('Test per-enrollment data cleanup on enrollment delete', () async {
      // 1. make enrollment
      String enId = (await etu.createEnrollments(n: 1)).$1.first;
      // 2. Make some stuff in a.__e
      var (keys, values) = await etu.createSomePerEnrollmentData(enId);
      // 2a. Verify everything is in a.__e
      for (final k in keys) {
        expect(await keyValueStore.exists(k), true);
      }
      // 3. Delete the enrollment
      await enMgr.remove(enId: enId);

      // 4. Verify nothing in a.__e
      for (final k in keys) {
        expect(await keyValueStore.exists(k), false);
      }

      // 5. Verify all in d.__e
      for (final k in keys.map((k) => k.replaceAll(
          '${EnrollmentConstants.perEnrollmentApproved}@',
          '${EnrollmentConstants.perEnrollmentDeleted}@'))) {
        expect(await keyValueStore.exists(k), true);
      }
    });

    test('Test per-enrollment data cleanup on enrollment revoke', () async {
      // 1. make enrollment
      String enId = (await etu.createEnrollments(n: 1)).$1.first;
      // 2. Make some stuff in a.__e
      var (keys, values) = await etu.createSomePerEnrollmentData(enId);
      // 2a. Verify everything is in a.__e
      for (final k in keys) {
        expect(await keyValueStore.exists(k), true);
      }
      // 3. Revoke the enrollment
      await etu.revokeEnrollment(etu.primaryEnId, enId);

      // 4. Verify nothing in a.__e
      for (final k in keys) {
        expect(await keyValueStore.exists(k), false);
      }

      // 5. Verify all in r.__e
      for (final k in keys.map((k) => k.replaceAll(
          '${EnrollmentConstants.perEnrollmentApproved}@',
          '${EnrollmentConstants.perEnrollmentRevoked}@'))) {
        expect(await keyValueStore.exists(k), true);
      }
    });

    test('Test per-enrollment data cleanup on enrollment unrevoke', () async {
      // 1. make enrollment
      String enId = (await etu.createEnrollments(n: 1)).$1.first;
      // 2. Make some stuff in a.__e
      var (keys, values) = await etu.createSomePerEnrollmentData(enId);
      // 2a. Verify everything is in a.__e
      for (final k in keys) {
        expect(await keyValueStore.exists(k), true);
      }
      // 3. Revoke the enrollment
      await etu.revokeEnrollment(etu.primaryEnId, enId);

      // 4. Verify all in r.__e
      for (final k in keys.map((k) => k.replaceAll(
          '${EnrollmentConstants.perEnrollmentApproved}@',
          '${EnrollmentConstants.perEnrollmentRevoked}@'))) {
        expect(await keyValueStore.exists(k), true);
      }

      // 5. Unrevoke the enrollment
      await etu.unrevokeEnrollment(etu.primaryEnId, enId);

      // 6. Verify all in a.__e
      for (final k in keys) {
        expect(await keyValueStore.exists(k), true);
      }
    });

    test('Test per-enrollment data cleanup on delete of revoked', () async {
      // 1. make enrollment
      String enId = (await etu.createEnrollments(n: 1)).$1.first;
      // 2. Make some stuff in a.__e
      var (keys, values) = await etu.createSomePerEnrollmentData(enId);
      // 2a. Verify everything is in a.__e
      for (final k in keys) {
        expect(await keyValueStore.exists(k), true);
      }
      // 3. Revoke the enrollment
      await etu.revokeEnrollment(etu.primaryEnId, enId);

      // 4. Verify all in r.__e
      for (final k in keys.map((k) => k.replaceAll(
          '${EnrollmentConstants.perEnrollmentApproved}@',
          '${EnrollmentConstants.perEnrollmentRevoked}@'))) {
        expect(await keyValueStore.exists(k), true);
      }

      // 6. Delete the revoked enrollment
      await etu.deleteEnrollment(etu.primaryEnId, enId);

      // 7. Verify all in d.__e
      for (final k in keys.map((k) => k.replaceAll(
          '${EnrollmentConstants.perEnrollmentApproved}@',
          '${EnrollmentConstants.perEnrollmentDeleted}@'))) {
        expect(await keyValueStore.exists(k), true);
      }
    });

    test(
        'Test that a state change on one enrollment does not move another '
        'enrollment\'s per-enrollment data', () async {
      // Two enrollments, each with its own per-enrollment data in a.__e
      final List<String> enIds = (await etu.createEnrollments(n: 2)).$1;
      final String enId1 = enIds[0];
      final String enId2 = enIds[1];
      final (keys1, _) = await etu.createSomePerEnrollmentData(enId1);
      final (keys2, _) = await etu.createSomePerEnrollmentData(enId2);

      // Revoke ONLY enId1
      await etu.revokeEnrollment(etu.primaryEnId, enId1);

      // enId1's data moved a -> r
      for (final k in keys1) {
        expect(await keyValueStore.exists(k), false);
      }
      for (final k in keys1.map((k) => k.replaceAll(
          '${EnrollmentConstants.perEnrollmentApproved}@',
          '${EnrollmentConstants.perEnrollmentRevoked}@'))) {
        expect(await keyValueStore.exists(k), true);
      }

      // enId2's data is UNTOUCHED — still in a.__e, and nothing landed in r.__e.
      // (Before the scope-by-enId fix, movePerEnrollmentData ignored its enId argument and
      // moved EVERY enrollment's keys, so revoking enId1 wrongly moved enId2's data to r.__e.)
      for (final k in keys2) {
        expect(await keyValueStore.exists(k), true);
      }
      for (final k in keys2.map((k) => k.replaceAll(
          '${EnrollmentConstants.perEnrollmentApproved}@',
          '${EnrollmentConstants.perEnrollmentRevoked}@'))) {
        expect(await keyValueStore.exists(k), false);
      }
    });

    // Observe per-enrollment data directly in the keystore. These lifecycle
    // checks run against enrollments that get revoked/deleted (so the owning
    // enrollment can no longer read its own keys), and a '*:rw' enrollment is
    // no longer permitted to cross-read another enrollment's per-enrollment
    // reserved namespace — so the neutral observer is the keystore itself, as
    // in the sibling test above.
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
      // 1. make enrollment with 100ms expiry
      String enId =
          (await etu.createEnrollments(n: 1, m: 1, ttl: ttl)).$1.first;

      // 2. Make some stuff in a.__e
      // 50ms is enough to create 9 records
      var (keys, values) = await etu.createSomePerEnrollmentData(enId);

      // 2a. As the primary enrollment, verify all the keys are there
      await verifyKeysExist(keys, values);

      // 3. Wait for expiry, then run the expired-keys job so the enrollment key
      // is removed — which, via preRemoveHook, moves its per-enrollment data
      // a -> d. (Previously observed indirectly through a cross-enrollment
      // lookup; that cross-read is no longer permitted, so trigger and observe
      // the move directly.)
      await Future.delayed(Duration(milliseconds: ttl + 1));
      await keyValueStore.deleteExpiredKeys();

      // 4. Verify all the a.__e keys are GONE
      await verifyKeysGone(keys);

      // 5. Verify they are all now in d.__e
      await verifyKeysExist(
          keys
              .map((s) => s.replaceFirst(
                  '${EnrollmentConstants.perEnrollmentApproved}@',
                  '${EnrollmentConstants.perEnrollmentDeleted}@'))
              .toList(),
          values);
    });

    test('Test lookup per-enrollment data of revoked', () async {
      // 1. make enrollment
      String enId = (await etu.createEnrollments(n: 1)).$1.first;

      // 2. Make some stuff in a.__e
      // 50ms is enough to create 9 records
      var (keys, values) = await etu.createSomePerEnrollmentData(enId);

      // 2a. As the primary enrollment, verify all the keys are there
      await verifyKeysExist(keys, values);

      // 3. Revoke the enrollment
      await etu.revokeEnrollment(etu.primaryEnId, enId);

      // 4. As the primary enrollment, verify all the keys are GONE
      await verifyKeysGone(keys);

      // 5. Verify they are all now in d.__e
      await verifyKeysExist(
          keys
              .map((s) => s.replaceFirst(
                  '${EnrollmentConstants.perEnrollmentApproved}@',
                  '${EnrollmentConstants.perEnrollmentRevoked}@'))
              .toList(),
          values);
    });

    test('Test lookup per-enrollment data of deleted', () async {
      // 1. make enrollment
      String enId = (await etu.createEnrollments(n: 1)).$1.first;

      // 2. Make some stuff in a.__e
      // 50ms is enough to create 9 records
      var (keys, values) = await etu.createSomePerEnrollmentData(enId);

      // 2a. As the primary enrollment, verify all the keys are there
      await verifyKeysExist(keys, values);

      // 3. Revoke and delete the enrollment (can't delete an approved without
      // first revoking it)
      await etu.revokeEnrollment(etu.primaryEnId, enId);
      await etu.deleteEnrollment(etu.primaryEnId, enId);

      // 4. As the primary enrollment, verify all the keys are GONE
      await verifyKeysGone(keys);

      // 5. Verify they are all now in d.__e
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
      // We'll set a TTL but it's not relevant here
      final int ttl = 60000;
      final List<String> allEnIds;
      final List<String> withTtlEnIds;
      final List<String> deletedEnIds = [];

      // make some enrollments, some with ttl
      (allEnIds, withTtlEnIds) =
          await etu.createEnrollments(n: 20, m: 3, ttl: ttl);
      expect(withTtlEnIds.length, 6);

      // check datastore state before deleting or cleaning up
      await etu.verifyKeyStoreState(allEnIds, deletedEnIds, cleanedUp: false);

      // Delete some of them via the key store but don't delete related keys
      // NB: Remove the preRemoveHook for enrollments to make this test possible
      keyValueStore.preRemoveHooks.remove(enMgr.preRemoveHook);
      int i = 0;
      for (final enId in allEnIds) {
        if (++i % 3 == 0) {
          await keyValueStore.remove(enMgr.buildEnrollmentKey(enId));
          deletedEnIds.add(enId);
        }
      }

      // Verify that keystore state is correct (orphaned still there)
      await etu.verifyKeyStoreState(allEnIds, deletedEnIds, cleanedUp: false);

      // Execute the orphaned keys cleanup
      List<String> removedOrphans =
          await enMgr.removeOrphanedApkamEncryptionKeys();
      // Verify the return value against expected
      expect(removedOrphans.length, deletedEnIds.length * 2);
      for (final enId in deletedEnIds) {
        expect(removedOrphans.contains(enMgr.keyForPEK(enId)), true);
        expect(removedOrphans.contains(enMgr.keyForSEK(enId)), true);
      }

      // Verify that keystore state is correct (orphaned gone, others remain)
      await etu.verifyKeyStoreState(allEnIds, deletedEnIds, cleanedUp: true);
    });

    test(
        'Verify that all related keys are cleaned up by the normal expired keys job when enrollments expire',
        () async {
      int ttl = 100;
      List<String> allEnIds;
      List<String> withTtlEnIds;
      // Create and approve some enrollments - some with expirations, some without
      (allEnIds, withTtlEnIds) =
          await etu.createEnrollments(n: 20, m: 3, ttl: ttl);

      expect(allEnIds.length, 20);
      expect(withTtlEnIds.length, 6);

      // Verify that the keystore state is as expected with all keys
      await etu.verifyKeyStoreState(allEnIds, [], cleanedUp: false);

      // Allow the expiration time to pass
      await Future.delayed(Duration(milliseconds: ttl + 1));

      // Verify that the keystore state is still the same
      await etu.verifyKeyStoreState(allEnIds, [], cleanedUp: false);

      // Run the expired keys cleanup job
      await keyValueStore.deleteExpiredKeys();

      // Verify that the keystore state is correct (expired all gone, others remain)
      await etu.verifyKeyStoreState(allEnIds, withTtlEnIds, cleanedUp: true);
    });

    test(
        'Fetching an expired enrollment REPORTS it expired and removes nothing',
        () async {
      // BEHAVIOUR CHANGED — fetching used to remove an expired enrollment as
      // it encountered it, taking its per-enrollment data with it. That was a
      // store mutation on the path every verb command and every authorisation
      // check takes, all of it outside the atSign's one enrollment-mutation
      // critical section, and `remove` fires the pre-remove hook, which moves
      // per-enrollment data across several awaits.
      //
      // The guarantee that mattered — an expired enrollment and its ancillary
      // keys do go away — is unchanged and is the sibling test above: the
      // scheduled expired-keys pass removes them through the same
      // `AtKeyValueStore.remove`, so the same hooks fire. What is asserted
      // here is that the READ does not, and that it still tells its caller
      // the enrollment is expired, which is what every caller decides on.
      int ttl = 100;
      List<String> allEnIds;
      List<String> withTtlEnIds;
      // Create and approve some enrollments - some with expirations, some without
      (allEnIds, withTtlEnIds) =
          await etu.createEnrollments(n: 5, m: 2, ttl: ttl);
      expect(allEnIds.length, 5);
      expect(withTtlEnIds.length, 2);

      // Verify that the keystore state is as expected with all keys
      await etu.verifyKeyStoreState(allEnIds, [], cleanedUp: false);

      Map m1 = await enMgr.getEnrollmentsAsJson(redactSecrets: false);
      expect(m1.length, allEnIds.length + 1);
      // remove the primary enrollment id from what we got
      m1.remove(enMgr.buildEnrollmentKey(etu.primaryEnId));
      // and now the number returned should be the number we created
      expect(m1.length, allEnIds.length);

      // Allow the expiration time to pass
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

      // Verify that the keystore state is still the same
      await etu.verifyKeyStoreState(allEnIds, [], cleanedUp: false);

      // fetch all enrollments
      // this should return ALL of them (including expired) and write nothing
      //
      // Note that we have to supply the list of enrollment ids
      // because otherwise getEnrollmentsAsJson will do a getKeys
      // on the HiveAtKeyValueStore which in turn filters what it finds against
      // the _expiryCache which HiveAtKeyValueStore maintains.
      final int writesBefore = EnrollmentManager.cacheInvalidations;
      Map m = await enMgr.getEnrollmentsAsJson(
          redactSecrets: false,
          ekList:
              allEnIds.map((enId) => enMgr.buildEnrollmentKey(enId)).toList());
      expect(m.length, allEnIds.length);

      int expiredEncountered = 0;
      // check that we have the right number of expired enrollments
      for (final entry in m.entries) {
        if (entry.value['status'] == EnrollmentStatus.expired.name) {
          expiredEncountered++;
          // check that the expired enrollment is in the withTtl list
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

      // And the scheduled pass is what does remove them, ancillary keys and
      // all: the guarantee is kept, by the job whose business it is.
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
      inboundConnection.metaData.sessionID = 'dummy_session';
      // Enroll request
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId_1 = jsonDecode(response.data!)['enrollmentId'];
      // OTP Verb
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      // Enroll request 2
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
      // The same (appName, deviceName) twice over CRAM is allowed. Each
      // request carries a keypair of its own, as a real repeat would: the
      // key-uniqueness rule is a separate refusal and is not what is being
      // tested here.
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
      // OTP Verb
      inboundConnection.metaData.isAuthenticated = true;
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
      inboundConnection.metaData.sessionID = 'dummy_session';
      Response response = Response();
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      String enrollmentId = jsonDecode(response.data!)['enrollmentId'];

      String enrollmentList = 'enroll:list';
      castMetadata(inboundConnection).enrollmentId = enrollmentId;
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
      // Enroll request
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentIdOne = jsonDecode(response.data!)['enrollmentId'];
      // OTP Verb
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      // Enroll request
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
      enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, approveEnrollmentVerbParams, inboundConnection);
      // Enroll list
      String enrollmentList = 'enroll:list';
      castMetadata(inboundConnection).enrollmentId = enrollmentId;
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
      // test conditions set-up
      EnrollVerbHandler enrollVerb =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      inboundConnection.metadata.isAuthenticated = true;
      EnrollDataStoreValue enrollValue =
          EnrollDataStoreValue('abcd', 'unit_test_enroll', 'testDevice', 'aPK')
            ..namespaces = {"unit_tst": "rw"}
            ..encryptedAPKAMSymmetricKey = 'anSK';
      // Distribution of enrollments below:
      // Approved = 1(key: 0); Pending = 2(keys: 1,2); Revoked = 3(keys: 3,4,5); Denied = 4(keys: 6,7,8,9);
      // (This distribution will be used for validation)
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

      // will be used to store newly created enrollment keys
      List<String> enrollmentKeys = [];
      Map<String, String> enrollmentStatuses = {};
      Map<String, EnrollDataStoreValue> enrollmentData = {};
      // create 10 random enrollments and store them into keystore
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
      inboundConnection.metaData.sessionID = 'dummy_session';
      // OTP Verb
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
    });

    // Key represents the operation and value represents the expected status of
    // enrollment
    var enrollOperationMap = {
      'approve': 'approved',
      'deny': 'denied',
    };

    enrollOperationMap.forEach((operation, expectedStatus) {
      test('A test to verify pending enrollment is $operation', () async {
        // Enroll request
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
      inboundConnection.metaData.sessionID = 'dummy_session';
      castMetadata(inboundConnection).enrollmentId =
          '456'; // a client cannot revoke its own enrollment. Set a different enrollmentId in inbound
      Response response = Response();
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
      // Commit log
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
      // Commit log
      expect(await (keyValueStore.commitLog as AtCommitLog).iterate().isEmpty,
          true);
    });

    test('A test to ensure enroll approval is not added to commit log',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      // GET OTP
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      // Send enrollment request
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
      inboundConnection.metaData.sessionID = 'dummy_session';
      await enrollVerbHandler.processVerb(
          response, enrollmentVerbParams, inboundConnection);
      var approveEnrollmentResponse = jsonDecode(response.data!);
      expect(approveEnrollmentResponse['enrollmentId'], enrollmentId);
      expect(approveEnrollmentResponse['status'], 'approved');
      // Verify Commit log does not contain keys with __manage namespace
      // (the enrollment approval should NOT have produced a commit-log entry).
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
      // Fetch TOTP
      String totpCommand = 'otp:get';
      HashMap<String, String?> totpVerbParams =
          getVerbParam(VerbSyntax.otp, totpCommand);
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      inboundConnection.metaData.isAuthenticated = true;
      Response defaultResponse = Response();
      await otpVerbHandler.processVerb(
          defaultResponse, totpVerbParams, inboundConnection);
      otp = defaultResponse.data;
    });
    test('A test to verify expired enrollment cannot be approved', () async {
      Response response = Response();
      // Enroll a request on an unauthenticated connection which will expire in 1 millisecond
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
      //Approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
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
      // Enroll a request on an unauthenticated connection which will expire in 1 millisecond
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
      //Deny enrollment
      await Future.delayed(Duration(milliseconds: 2));
      String denyEnrollmentCommand =
          'enroll:deny:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams = getVerbParam(VerbSyntax.enroll, denyEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
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
      // Enroll a request on an unauthenticated connection which will expire in 1 minute
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
      // Verify TTL is added to the enrollment
      AtData? enrollmentData = await keyValueStore.get(enrollmentKey);
      expect(enrollmentData!.metaData!.expiresAt, isNotNull);
      expect(enrollmentData.metaData!.ttl, 600000);
      //Approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      // Verify TTL is reset
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
      // Verify TTL is not set
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
      // Store an enrollment request which has access to "__manage" namespace to approve enrollment requests.
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
      // Fetch OTP
      String totpCommand = 'otp:get';
      HashMap<String, String?> totpVerbParams =
          getVerbParam(VerbSyntax.otp, totpCommand);
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      inboundConnection.metaData.isAuthenticated = true;
      await otpVerbHandler.processVerb(
          defaultResponse, totpVerbParams, inboundConnection);
      otp = defaultResponse.data;
      // Enroll a request on an unauthenticated connection which will expire in 1 minute
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
      //deny enrollment
      String denyEnrollmentCommand =
          'enroll:deny:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams = getVerbParam(VerbSyntax.enroll, denyEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'denied');
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
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
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      //revoke enrollment
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
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      //revoke enrollment
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
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      inboundConnection.metadata.enrollmentId = enrollmentIdWithManageNamespace;

      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      //revoke enrollment
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
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      inboundConnection.metadata.enrollmentId = enrollmentIdWithManageNamespace;

      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      //revoke enrollment
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
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      //revoke enrollment
      String revokeEnrollmentCommand =
          'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, revokeEnrollmentCommand);
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'revoked');
      // Approved a revoked enrollment throws AtEnrollmentException
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
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');

      // Deny an approved enrollment throws AtEnrollmentException
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
      //revoke enrollment
      String denyEnrollmentCommand =
          'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams = getVerbParam(VerbSyntax.enroll, denyEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
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
      // __manage is the namespace that decides who may approve at all, so
      // conferring write on it hands out an authority the approver does not
      // have — the enrollment admitted this way can approve, revoke and
      // delete, including its own approver, which could do none of that.
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
      // The control. Without it the refusal above is equally satisfied by
      // "__manage:r may approve nothing", which would leave a read-only
      // administrator unable to admit its own kind.
      final String approverId = await storeApprovedEnrollment({'__manage': 'r'});
      final String targetId = await storePendingEnrollment({'__manage': 'r'});

      await approveAs(approverId, targetId);
      expect(await stateOf(targetId), EnrollmentStatus.approved.name);
    });

    test('…and an approver holding __manage:rw may confer __manage:rw',
        () async {
      // The second control: the same act, refused above, allowed here, and
      // the only thing that differs is the approver's own access.
      final String approverId =
          await storeApprovedEnrollment({'__manage': 'rw'});
      final String targetId = await storePendingEnrollment({'__manage': 'rw'});

      await approveAs(approverId, targetId);
      expect(await stateOf(targetId), EnrollmentStatus.approved.name);
    });

    test(
        'an approver holding everything BUT __manage:rw may not approve a '
        'full root', () async {
      // The climb-back, and the reason the __manage comparison exists. An
      // approver holding '*':'rw' covers every data namespace a root asks
      // for, so the per-namespace loop passes on all of them and __manage is
      // the only entry left to refuse. Were it not compared, this approver
      // would mint an enrollment strictly more privileged than itself — a
      // full root, able to revoke the very enrollment that admitted it.
      //
      // The tests above pair an approver and a target whose grants are
      // __manage ALONE. Such a target is not a root, and such an approver
      // could not cover a root's '*' entry in any case — so the refusal they
      // pin could as easily have come from the wildcard. This one cannot.
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
      // The control for the refusal above, differing from it in the target's
      // __manage access and in nothing else. Without it the refusal is
      // equally satisfied by an approver forbidden to approve anything at
      // all, which would make a '*':'rw' + '__manage':'r' administrator
      // useless rather than merely unable to promote.
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
      // Store an enrollment request which has access to "__manage" namespace to approve enrollment requests.
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
      // Fetch OTP
      String totpCommand = 'otp:get';
      HashMap<String, String?> totpVerbParams =
          getVerbParam(VerbSyntax.otp, totpCommand);
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      inboundConnection.metaData.isAuthenticated = true;
      await otpVerbHandler.processVerb(
          defaultResponse, totpVerbParams, inboundConnection);
      otp = defaultResponse.data;
      // Enroll a request on an unauthenticated connection which will expire in 1 minute
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
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      //revoke enrollment
      String revokeEnrollmentCommand =
          'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, revokeEnrollmentCommand);
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'revoked');
      // un- revoke enrollment
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
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      // un- revoke enrollment
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
      //approve enrollment
      String approveEnrollmentCommand =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"dummy_encrypted_private_key","encryptedDefaultSelfEncryptionKey":"dummy_self_encrypted_key"}';
      HashMap<String, String?> approveEnrollVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollmentCommand);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session_id';
      await enrollVerbHandler.processVerb(
          response, approveEnrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'approved');
      //revoke enrollment
      String revokeEnrollmentCommand =
          'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      enrollVerbParams =
          getVerbParam(VerbSyntax.enroll, revokeEnrollmentCommand);
      await enrollVerbHandler.processVerb(
          response, enrollVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['enrollmentId'], enrollmentId);
      expect(jsonDecode(response.data!)['status'], 'revoked');
      // un- revoke enrollment
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
      inboundConnection.metaData.sessionID = 'dummy_session';
      // OTP Verb
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
      // Assert the enrollment expiry is set to default value.
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

      // First Invalid request
      evp = getVerbParam(VerbSyntax.enroll, makeEnrollRequest('123'));
      await swallow(() => evh.processVerb(response, evp, inboundConnection));
      expect(evh.getEnrollmentResponseDelayInMilliseconds(),
          EnrollVerbHandler.initialDelayInMilliseconds);

      // Second Invalid request and verify the delay response interval
      evp = getVerbParam(VerbSyntax.enroll, makeEnrollRequest('123'));
      await swallow(() => evh.processVerb(response, evp, inboundConnection));
      expect(evh.getEnrollmentResponseDelayInMilliseconds(),
          EnrollVerbHandler.initialDelayInMilliseconds * 2);

      // Third Invalid request and verify the delay response interval
      evp = getVerbParam(VerbSyntax.enroll, makeEnrollRequest('123'));
      await swallow(() => evh.processVerb(response, evp, inboundConnection));
      expect(evh.getEnrollmentResponseDelayInMilliseconds(),
          EnrollVerbHandler.initialDelayInMilliseconds * 3);

      // Fourth Invalid request and verify the delay response interval
      evp = getVerbParam(VerbSyntax.enroll, makeEnrollRequest('123'));
      await swallow(() => evh.processVerb(response, evp, inboundConnection));
      expect(evh.getEnrollmentResponseDelayInMilliseconds(),
          EnrollVerbHandler.initialDelayInMilliseconds * 5);

      // Fifth Invalid request and verify the delay response interval
      evp = getVerbParam(VerbSyntax.enroll, makeEnrollRequest('123'));
      await swallow(() => evh.processVerb(response, evp, inboundConnection));
      expect(evh.getEnrollmentResponseDelayInMilliseconds(),
          EnrollVerbHandler.initialDelayInMilliseconds * 8);

      // Sixth Invalid request and verify the delay response interval has been
      // incremented, but not past the maximum value
      evp = getVerbParam(VerbSyntax.enroll, makeEnrollRequest('123'));
      await swallow(() => evh.processVerb(response, evp, inboundConnection));
      expect(evh.getEnrollmentResponseDelayInMilliseconds(),
          EnrollVerbHandler.initialDelayInMilliseconds * 10);

      // Get OTP and send a valid enrollment request. Verify the delay response
      // has been reset.
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      inboundConnection.metaData.isAuthenticated = true;
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
      inboundConnection.metaData.sessionID = 'dummy_session';
      // First enrollment request
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"device-1","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId_1 = jsonDecode(response.data!)['enrollmentId'];
      // OTP Verb
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      // Second enrollment request
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
      inboundConnection.metaData.sessionID = 'dummy_session';
      // First enrollment request
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"device-1","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      EnrollVerbHandler enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, enrollmentRequestVerbParams, inboundConnection);
      String enrollmentId_1 = jsonDecode(response.data!)['enrollmentId'];
      // OTP Verb
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      // Second enrollment request
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
      // Insert the enrollment data
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

    // --- enroll:fetch authorization: self, or __manage + access to ALL of the
    // target enrollment's namespaces (same bar as approve/deny/revoke) ---
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
      // "EVERY namespace the target holds" counts __manage as a namespace
      // like any other, and fetch is the one operation reaching that
      // comparison which confers nothing — it READS. The refusal is
      // therefore about authority over the target rather than about the
      // secrecy of what comes back, and it is pinned because a caller
      // covering every other namespace makes __manage the only entry left to
      // decide it.
      await seedEnrollment('readOnlyAdmin', {'*': 'rw', '__manage': 'r'});
      await seedEnrollment('root1', {'*': 'rw', '__manage': 'rw'});

      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.enrollmentId = 'readOnlyAdmin';
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
      // The control. Without it the refusal above is equally satisfied by
      // "__manage:r may fetch nothing but itself", and a correct narrowing
      // would be indistinguishable from a blanket one.
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
      inboundConnection.metaData.sessionID = 'dummy_session';
      // Enroll request
      String enrollmentRequest =
          'enroll:request:{"deviceName":"mydevice","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
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
      inboundConnection.metaData.sessionID = 'dummy_session';
      // Enroll request
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","namespaces":{"wavi":"r"},"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
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
      inboundConnection.metaData.sessionID = 'dummy_session';
      // Enroll request
      String enrollmentRequest =
          'enroll:request:{"appName":"wavi","deviceName":"mydevice", "namespaces":{"wavi":"r"}}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
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
      inboundConnection.metaData.sessionID = 'dummy_session';
      // OTP Verb
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
      inboundConnection.metaData.sessionID = 'dummy_session';
      // OTP Verb
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      // No encryptedAPKAMSymmetricKey: the approver mints the symmetric key and
      // encapsulates it to the advertised key package, so the request carries
      // no RSA-wrapped secret at all.
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
      inboundConnection.metaData.sessionID = 'dummy_session';
      // OTP Verb
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
      inboundConnection.metaData.sessionID = 'dummy_session';
      // Enroll request
      String enrollmentRequest =
          'enroll:approve:{"encryptedDefaultEncryptionPrivateKey": "dummy_encrypted_default_encryption_private_key","encryptedDefaultSelfEncryptionKey":"dummy_encrypted_default_self_encryption_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
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
      inboundConnection.metaData.sessionID = 'dummy_session';
      // Enroll request
      String enrollmentRequest =
          'enroll:approve:{"enrollmentId":"abc123", "encryptedDefaultSelfEncryptionKey":"dummy_encrypted_default_self_encryption_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
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
      inboundConnection.metaData.sessionID = 'dummy_session';
      // Enroll request
      String enrollmentRequest =
          'enroll:approve:{"enrollmentId":"abc123","encryptedDefaultEncryptionPrivateKey": "dummy_encrypted_default_encryption_private_key"}';
      HashMap<String, String?> enrollmentRequestVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
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
      // The approve/deny/revoke/unrevoke loop asks this question once per
      // namespace the target holds, so for a target carrying '__manage':'rw'
      // this IS the approve check. __manage is decided on its own branch,
      // ahead of checkEnrollmentNamespaceAccess, so the comparison every other
      // namespace gets has to be made there too.
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
      // A caller that really holds what the target holds, plus __manage.
      // This used to name an enrollment id that was never stored: nothing
      // looked it up, so any string did.
      castMetadata(inboundConnection).enrollmentId =
          await createAndPersistAnEnrollment('deleter', 'device',
              {'test_namespace': 'rw', '__manage': 'rw'});
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
      castMetadata(inboundConnection).enrollmentId =
          await createAndPersistAnEnrollment('deleter', 'device',
              {'test_namespace': 'rw', '__manage': 'rw'});
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
      // Authorised, so the refusal under test is the STATE one. An
      // unauthorised caller is refused earlier and never learns the state —
      // pinned separately below.
      castMetadata(inboundConnection).enrollmentId =
          await createAndPersistAnEnrollment('deleter', 'device',
              {'test_namespace-2': 'rw', '__manage': 'rw'});
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

    /// `enroll:delete` destroys a record irreversibly, and was the only
    /// enrollment operation naming a target that asked nothing of the caller.
    /// `enroll:fetch`, which merely READS the target, has always asked — and
    /// asks for exactly this. The omission was an oversight, not a decision.
    ///
    /// Two things now rest on it. `descendantsOf` fetches each
    /// `parentEnrollmentId` link BY KEY, which is what keeps an EXPIRED
    /// link traversable — a DELETED one is gone, so deleting a middle link
    /// puts everything behind it permanently beyond a later cascade. And the
    /// approver-not-approved refusal permits an enrollment whose approver no
    /// longer exists, so deleting that approver is what makes the orphan
    /// un-revokable.
    /// A target holding NO namespaces passes every per-namespace
    /// authorisation loop vacuously — zero iterations, no refusal — and the
    /// `__manage` requirement lives inside those loops, so it is not asked
    /// either. Three loops decide authority that way: `enroll:fetch`, the
    /// shared approve/deny/revoke/unrevoke loop, and `enroll:delete`. Only
    /// delete refused it before now, and nothing pinned even that.
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

      Future<void> runAs(String? callerId, String command) async {
        inboundConnection.metadata.isAuthenticated = true;
        castMetadata(inboundConnection).enrollmentId = callerId;
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

      test('cannot be produced by an authenticated request naming none',
          () async {
        // The producer. The "at least one namespace" check used to sit inside
        // the branch for requests carrying an OTP, and an authenticated
        // connection sends none — so such a request wrote an enrollment with
        // an empty grant map and nothing refused it. The check no longer
        // depends on the OTP.
        inboundConnection.metadata.isAuthenticated = true;
        castMetadata(inboundConnection).enrollmentId = null;
        final h = EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
        await expectLater(
            () => h.processVerb(
                response,
                h.parse('enroll:request:{"appName":"empty-app",'
                    '"deviceName":"empty-device","namespaces":{},'
                    '"apkamPublicKey":"dummy_apkam_public_key-${Uuid().v4().hashCode}",'
                    '"encryptedAPKAMSymmetricKey":"dummy_symm_key"}'),
                inboundConnection),
            throwsA(isA<IllegalArgumentException>()),
            reason: 'an authenticated request carries no OTP, so a check '
                'living inside the OTP branch never saw it');
      });

      test('...and a LEGACY connection naming none is refused too', () async {
        // ⛔ THE SILENT REGRESSION. The namespace requirement carries an
        // exemption per auth type, because the auth type decides which branch
        // of the request path fills the grants in: CRAM grants `__manage` and
        // `*`, a self-enrolment copies its predecessor's. A legacy connection
        // does neither — it has no predecessor to copy and gets no CRAM
        // grants — so exempting it lands exactly the record the three gates
        // above exist to refuse, written successfully, with nothing red.
        //
        // Its sibling above uses an owner connection, which is not the same
        // arm: the exemption is keyed on the auth type, and only a connection
        // carrying AuthType.pkamLegacy exercises the term that was struck.
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

      test('control: an owner connection may still act on it', () async {
        // Why the guards are gated on caller-vs-target rather than applied
        // unconditionally. A connection carrying no enrollment id — CRAM,
        // owner or legacy PKAM — is the atSign itself; if it could not reach
        // such a record, the most anomalous enrollment on the atSign would be
        // the one nothing could clear up.
        final targetId = await anEmptyTarget(status: EnrollmentStatus.approved);
        await runAs(null, 'enroll:revoke:{"enrollmentId":"$targetId"}');
        expect(response.isError, false, reason: '${response.errorMessage}');
      });
    });

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

        // The control, on the SAME target: a caller that does hold it
        // succeeds, so the refusal is about the namespace and not about a
        // target that could never be deleted.
        final insider = await createAndPersistAnEnrollment(
            'insider', 'device', {'test_namespace': 'rw', '__manage': 'rw'});
        await deleteAs(insider, targetId);
        expect(response.data,
            '{"enrollmentId":"$targetId","status":"deleted"}');
      });

      test('a caller holding the namespace but not __manage is refused',
          () async {
        // __manage is what separates "may use this namespace" from "may
        // administer enrollments in it". Without this, any app enrolled for a
        // namespace could destroy every revoked enrollment that held it.
        final targetId = await aTarget({'test_namespace': 'rw'});
        final appOnly = await createAndPersistAnEnrollment(
            'app-only', 'device', {'test_namespace': 'rw'});

        await expectLater(() => deleteAs(appOnly, targetId),
            throwsA(isA<UnAuthorizedException>()));
      });

      test('a caller may always delete its OWN enrollment', () async {
        // The self-exemption, and it is not decorative: an enrollment tidying
        // itself up holds no __manage in the ordinary case, so the rule above
        // would otherwise strand every revoked enrollment on the atSign.
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

      test('a connection carrying no enrollment id may delete any', () async {
        // A CRAM, owner or legacy-PKAM connection. Same exemption
        // `enroll:fetch` makes, and the same one isAuthorized makes for every
        // other verb: a connection with no enrollment id is the atSign
        // itself.
        final targetId = await aTarget({'test_namespace': 'rw'});

        await deleteAs(null, targetId);
        expect(response.data,
            '{"enrollmentId":"$targetId","status":"deleted"}');
      });

      test('a target holding NO namespaces is refused, not passed vacuously',
          () async {
        // The loop decides by iterating the TARGET's grants, so an empty map
        // would pass it with zero iterations and no refusal — and the
        // __manage requirement lives inside that loop, so it would not be
        // asked either. The most anomalous record on the atSign would become
        // the one any enrolled caller could destroy.
        final targetId = await aTarget({});

        // The hazard, first: a caller with one unrelated namespace and NO
        // __manage. Every refusal this gate makes is decided inside the loop,
        // so with nothing to iterate this caller would sail through.
        final appOnly = await createAndPersistAnEnrollment(
            'app-only', 'device', {'other_namespace': 'rw'});
        await expectLater(() => deleteAs(appOnly, targetId),
            throwsA(isA<UnAuthorizedException>()));

        // And a ROOT caller, so the rule is about the target rather than the
        // caller being weak: `*:rw` plus __manage would satisfy the loop for
        // any namespace there was to check.
        final root = await createAndPersistAnEnrollment(
            'root', 'device', {'*': 'rw', '__manage': 'rw'});
        await expectLater(() => deleteAs(root, targetId),
            throwsA(isA<UnAuthorizedException>()));

        // The control: the exemptions still apply, so the record is not
        // stranded. An owner connection can still remove it.
        await deleteAs(null, targetId);
        expect(response.data,
            '{"enrollmentId":"$targetId","status":"deleted"}');
      });

      test('an unauthorised caller is refused before it learns the state',
          () async {
        // The target is APPROVED, which is refused on its own terms with a
        // message naming the status. An unauthorised caller must not get that
        // message: whether an enrollment it may not touch is approved, denied
        // or revoked is not its business.
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
      // OTP Verb
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      String otp = response.data!;

      // 1. Create an enrollment request
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

      // Verify key is created in the secondary keystore.
      AtData? atData = await keyValueStore.get(enrollmentKey);
      expect(atData!.data!.isNotEmpty, true);
      var enrollmentDataMap = jsonDecode(atData.data!);
      expect(enrollmentDataMap['appName'], 'wavi');
      expect(enrollmentDataMap['deviceName'], 'mydevice');
      expect(enrollmentDataMap['namespaces'], {'buzz': 'r'});
      expect(enrollmentDataMap['apkamPublicKey'], 'lorem_apkam');

      AtCommitLog atCommitLog = atServer.commitLog;
      // Since there are no entries in commit log, the stream is empty.
      expect(await atCommitLog.iterate().isEmpty, true);

      // 2. Approve an enrollment and verify enrollmentKey is not stored in the commit log.
      String approveEnrollment =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey": "dummy_encrypted_default_encryption_private_key","encryptedDefaultSelfEncryptionKey":"dummy_encrypted_default_self_encryption_key"}';
      HashMap<String, String?> approveEnrollmentVerbParams =
          getVerbParam(VerbSyntax.enroll, approveEnrollment);
      inboundConnection.metaData.isAuthenticated = true;
      enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, approveEnrollmentVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['status'], 'approved');

      atCommitLog = atServer.commitLog;
      // Ensure there are no other keys in the commit log.
      expect(await atCommitLog.iterate().isEmpty, true);

      // 3. Revoke an enrollment and verify the commit log state.
      enrollmentRequest = 'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      HashMap<String, String?> revokeEnrollmentVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      response = Response();
      enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, revokeEnrollmentVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['status'], 'revoked');

      atCommitLog = atServer.commitLog;
      // Ensure there are no other keys in the commit log.
      expect(await atCommitLog.iterate().isEmpty, true);

      // 4. Delete an enrollment request.
      enrollmentRequest = 'enroll:delete:{"enrollmentId":"$enrollmentId"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      response = Response();
      enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      expect(jsonDecode(response.data!)['status'], 'deleted');

      atCommitLog = atServer.commitLog;
      // Ensure there are no other keys in the commit log.
      expect(await atCommitLog.iterate().isEmpty, true);

      // Verify key is deleted in the secondary keystore.
      expect(() async => await keyValueStore.get(enrollmentKey),
          throwsA(predicate((dynamic e) => e is KeyNotFoundException)));
    });

    test(
        'A test to verify commit log state during create deny and delete an enrollment request',
        () async {
      Response response = Response();
      // OTP Verb
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      HashMap<String, String?> otpVerbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, otpVerbParams, inboundConnection);
      String otp = response.data!;

      // 1. Create an enrollment request
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

      // Verify key is created in the secondary keystore.
      AtData? atData = await keyValueStore.get(enrollmentKey);
      expect(atData!.data!.isNotEmpty, true);
      var enrollmentDataMap = jsonDecode(atData.data!);
      expect(enrollmentDataMap['appName'], 'wavi');
      expect(enrollmentDataMap['deviceName'], 'mydevice');
      expect(enrollmentDataMap['namespaces'], {'buzz': 'r'});
      expect(enrollmentDataMap['apkamPublicKey'], 'lorem_apkam');

      AtCommitLog atCommitLog = atServer.commitLog;
      // Since there are no entries in commit log, the stream is empty.
      expect(await atCommitLog.iterate().isEmpty, true);

      // 2. Deny an enrollment and verify the commit log state.
      enrollmentRequest = 'enroll:deny:{"enrollmentId":"$enrollmentId"}';
      HashMap<String, String?> denyEnrollmentVerbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      response = Response();
      enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, denyEnrollmentVerbParams, inboundConnection);
      expect(jsonDecode(response.data!)['status'], 'denied');

      atCommitLog = atServer.commitLog;
      // Since there are no entries in commit log, the stream is empty.
      expect(await atCommitLog.iterate().isEmpty, true);

      // 3. Delete an enrollment request.
      enrollmentRequest = 'enroll:delete:{"enrollmentId":"$enrollmentId"}';
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.enroll, enrollmentRequest);
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.sessionID = 'dummy_session';
      response = Response();
      enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
      await enrollVerbHandler.processVerb(
          response, verbParams, inboundConnection);
      expect(jsonDecode(response.data!)['status'], 'deleted');

      atCommitLog = atServer.commitLog;
      // Since there are no entries in commit log, the stream is empty.
      expect(await atCommitLog.iterate().isEmpty, true);

      // Verify key is deleted in the secondary keystore.
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
      // enIds[0] = app_1 {app_1:rw, test:r}; enIds[1] = app_2 {app_2:rw, test:r}

      // Attach metadata to enIds[0]'s record (models the enroll:request tail).
      final ev0 = await enMgr.getEnrollmentById(enIds[0]);
      ev0.metadata = {
        'keyPackage': {'v': 1, 'keys': []}
      };
      await enMgr.put(enIds[0], AtData()..data = jsonEncode(ev0.toJson()),
          EnrollmentStatus.approved);

      // A pending (unapproved) enrollment authorised for 'test' — excluded.
      final pending = await etu.createPendingEnrollment(
          appName: 'pend',
          deviceName: 't',
          namespaces: {'test': 'r'},
          apkamKeysExpiryDuration: null);

      final members = await enMgr.getEnrollmentsForNamespace('test');
      final ids = members.map((m) => m['enrollmentId']).toSet();
      // primary(*:rw) + app_1(test:r) + app_2(test:r) authorised; pending excluded
      expect(ids.contains(enIds[0]), true);
      expect(ids.contains(enIds[1]), true);
      expect(ids.contains(pending), false);
      // every element carries apkamPubKey and access
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

      // app_1 (test:r) queries 'test' -> allowed
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.enrollmentId = enIds[0];
      final okResp = Response();
      await etu.evh.processVerb(
          okResp,
          HashMap<String, String?>.from(
              {'operation': 'listns', 'listNamespace': 'test'}),
          inboundConnection);
      expect(okResp.isError, false);
      final roster = jsonDecode(okResp.data!) as List;
      expect(roster.any((m) => m['apkamPubKey'] != null), true);

      // app_2 (app_2:rw, test:r — NOT app_1) queries 'app_1' -> refused
      inboundConnection.metaData.enrollmentId = enIds[1];
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
      // A shape the server has no code for, deliberately: the value is opaque,
      // so what comes back out must be what went in and nothing the server
      // could have composed from (apkamPublicKey, signingAlgo).
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
      // The server composes nothing from (apkamPublicKey, signingAlgo): PKAM
      // verification reads the record, so an unsent signing key is the
      // enrollee's own to publish, or to go without.
      final (enIds, _) = await etu.createEnrollments(n: 1);
      final apskKey = 'public:_apsk.${enIds[0]}'
          '.${EnrollmentConstants.perEnrollmentApproved}$alice';
      expect(await keyValueStore.exists(apskKey), false);

      // Including on the CRAM path, which is where an atSign's very first
      // enrollment is auto-approved.
      final primaryApsk = 'public:_apsk.${etu.primaryEnId}'
          '.${EnrollmentConstants.perEnrollmentApproved}$alice';
      expect(await keyValueStore.exists(primaryApsk), false);
    });

    /// Submits an unauthenticated `enroll:request` built from [ep] and returns
    /// the future, so a caller can assert on how it is refused.
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
    ///
    /// `encryptedAPKAMSymmetricKey` is not optional dressing here: without it
    /// `_validateParams` refuses the request — as an IllegalArgumentException,
    /// the same class the size refusal throws — before the size check is ever
    /// reached. Every arm below therefore matches on the MESSAGE too, or it
    /// goes green on a refusal that has nothing to do with the cap.
    Future<EnrollParams> sizedRequest(String appName) async {
      inboundConnection.metaData.isAuthenticated = true;
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
      // What the params pre-filter buys, and the only thing that distinguishes
      // it from the record check that follows: the size refusal lands before
      // isPasscodeValid, which deletes the OTP on use. Without it a client
      // that sent too much would have to go back to the user for a new
      // passcode to retry.
      final ep = await sizedRequest('otpPreserved')
        ..apsk = {
          'publicKey': 'x' * (EnrollVerbHandler.maxEnrollmentRecordBytes + 1)
        };
      final otp = ep.otp!;

      await expectLater(submitRequest(ep), refusedForSize);

      // The same one-shot OTP still works, which it would not had the
      // oversized request reached isPasscodeValid.
      await submitRequest(EnrollParams()
        ..appName = 'otpPreserved'
        ..deviceName = 'd2'
        ..apkamPublicKey = 'apkam pub'
        ..encryptedAPKAMSymmetricKey = 'encrypted apkam aes key'
        ..namespaces = {'wavi': 'rw'}
        ..otp = otp);
    });

    test('the cap covers metadata, not just apsk', () async {
      // The reason the cap moved from the field to the record. metadata
      // carries the enrollment's key package — the largest blob in play — and
      // was uncapped while apsk was capped, so the bound applied to the one
      // field nobody would use to make a record big.
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
      // Neither field is over the cap on its own; together they are. A
      // per-field bound goes green here, which is exactly the hole that made
      // the old one worth replacing.
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
      // The other arm of the bound: a large-but-legitimate value goes through
      // untouched. ~100KB is far more than any real key package and well
      // inside 500KB.
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
      // The publish reads the RECORD, so an approve-time value is ignored:
      // the signing key an enrollment advertises is the enrollee's alone.
      final enrolleeApsk = {'v': 1, 'publicKey': 'the-enrollees-own-key'};
      final enId = await etu.createPendingEnrollment(
          appName: 'substApp',
          deviceName: 'd',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null,
          apsk: enrolleeApsk);

      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.enrollmentId = etu.primaryEnId;
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
      // The whole point of the second field: every deployed _apsk consumer
      // base64-decodes the value as an RSA key, and a JSON string — quotes and
      // all — is not what that parser reads. So the assertion is on the raw
      // stored bytes, and it explicitly rejects the jsonEncode spelling: an
      // `expect(jsonDecode(stored), bare)` would pass on BOTH, which is the
      // mistake this pins against.
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

      // And it is on the record, so it survives a restart rather than living
      // only in the published copy.
      final enVal = await enMgr.getEnrollmentById(pendingEnId);
      expect(enVal.apskLegacy, bare);
      expect(enVal.apsk, isNull);
    });

    test('a request carrying BOTH apsk and apskLegacy is refused, and creates '
        'no enrollment', () async {
      // Not a precedence question: one record publishes one value, and the
      // server has no basis for choosing between two the client disagreed with
      // itself about. Refusing is also what keeps the choice observable.
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
          // refusals on this path are also IllegalArgumentException, so a
          // type-only matcher would go green on the wrong one.
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
      final otp = await etu.getOtp();
      // Built as raw request JSON rather than through EnrollParams: these are
      // the wire spellings the server reads, and going through the typed
      // builder would let a field rename pass unnoticed on both sides.
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
    /// private half, the way a client rotating its key must. Real crypto, not
    /// a stand-in: a fake string would make the accept arm pass for the wrong
    /// reason and the reject arm pass for no reason at all.
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
      final r = Response();
      await etu.evh.processVerb(
        r,
        getVerbParam(VerbSyntax.enroll, 'enroll:update:${jsonEncode(p.toJson())}'),
        inboundConnection,
      );
      return r;
    }

    test('a valid rotation replaces the key, and an invalid one does not', () async {
      // Both arms in one test deliberately: the accept arm is the control that
      // proves the reject arm is refusing the signature rather than refusing
      // everything.
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
      // The handler reads the enrollment, then awaits an APKAM signature
      // verification before writing it back with the status it read at the
      // top. `put` moves an enrollment's per-enrollment data to match the
      // status it is handed, so writing `approved` back from that snapshot
      // returns a revoked enrollment's published `_apsk` to the live address
      // the revocation had just parked it from. `enroll:update` is self-only,
      // so the caller IS the enrollment being revoked — precisely the
      // compromised-client case revocation exists for.
      //
      // The window is REPRODUCED rather than raced. The handler's first read
      // goes through EnrollmentManager's cache, which is evicted only by a
      // write through the manager, so revoking the record straight on the
      // keystore leaves that snapshot saying approved while the disk says
      // revoked — the state the race produces, without depending on
      // scheduling.
      final enId = (await etu.createEnrollments(n: 1)).$1.first;
      final newPair = AtChopsUtil.generateAtPkamKeyPair();
      final newPub = newPair.atPublicKey.publicKey;

      // Prime the snapshot the handler will read at the top of the method.
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
      // The rsa2048 arms above cannot reach this: at_chops verifies rsa2048
      // synchronously and mldsa65 asynchronously, so only the ML-DSA path
      // hands the handler a Future where it reads a bool. Real ML-DSA
      // material for the same reason the rsa2048 test uses real keys.
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
      // The carve-out, and it is the half that needs saying. `isAuthorized`'s
      // default is that NO enrollment id means full permissions — an owner
      // connection is normally waved through everything. This refusal is an
      // explicit exception to that default, so the id-less case is the
      // SURPRISING one and the one worth pinning; the enrollment-vs-
      // enrollment case above is what anyone would guess.
      //
      // Reached by a CRAM, owner or legacy-PKAM connection — every
      // connection carrying no enrollment id. Pinned here rather than over
      // the wire, deliberately: the rule is server-side and needs no wire to
      // prove.
      final enId = (await etu.createEnrollments(n: 1)).$1.first;

      inboundConnection.metaData.isAuthenticated = true;
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
      // The privilege-escalation guard: self-only plus reachable namespaces
      // would let an enrollment widen its own grant.
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
      // This is the operation that moves an enrollment across: a retrofit that
      // gains a structured key must stop the record claiming the bare one, or
      // the record holds both and the published value depends on a precedence
      // rule nobody stated.
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

      // bare, then array
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

      // and back again
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
        // On the message, not just the type: enroll:update's own "names
        // nothing to change" refusal is the same exception class, and this
        // arm has to fail for the reason it is testing.
        throwsA(isA<IllegalArgumentException>().having(
            (e) => e.message, 'message', contains('mutually exclusive'))),
      );
    });

    test('an update is refused when the MERGED record would exceed the cap',
        () async {
      // Why the record check is the authority and the params pre-filter is
      // not: metadata merges rather than replaces, so two updates that are
      // each comfortably inside the cap can leave a record outside it. Only a
      // measurement taken after the merge can see that.
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
      // The "names nothing to change" guard lists the fields an update may
      // reach; a field added to the operation and not to that list is refused
      // by a check written before it existed, which is how this one was caught.
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
      // The flat credential, seeded AFTER etu.init() — so the assertion below
      // is about a value a CRAM auto-approve found and had to leave alone,
      // not one that merely happens to be in the store.
      await keyValueStore.put(AtConstants.atPkamPublicKey,
          AtData()..data = 'the-flat-pkam-key',
          skipCommit: true);
    });

    tearDown(() async {
      await verbTestsTearDown();
    });

    test('an auto-approved enrollment does not become the flat credential',
        () async {
      // `at_pkam_publickey` is what a `pkam:` carrying NO enrollment id is
      // verified against. An `enroll:request` mints an APKAM credential,
      // which always authenticates WITH an id, so a key minted for the second
      // has no business becoming the first. The CRAM branch used to copy it
      // there "for old clients", which gave one keypair two identities AND,
      // being unconditional, destroyed whatever flat credential the atSign
      // already had — and enroll:request is deliberately repeatable on a CRAM
      // connection, so every repeat clobbered it again.
      //
      // It also pins that CRAM is auto-approved rather than treated as a
      // self-enrolment: at_auth throws unless a FIRST enrollment comes back
      // approved, so onboarding breaks for every new user if this branch is
      // ever reordered behind another.
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
      // untouched, and composing it from whatever the handler wrote would
      // assert nothing.
      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          'the-flat-pkam-key',
          reason: 'the flat credential is untouched — an enrollment key that '
              'landed here would authenticate with no enrollment id, giving '
              'one keypair an identity its own revocation cannot reach');
    });
  });
}
