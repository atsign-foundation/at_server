import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

/// `enroll:list` returns every enrollment on the atSign, and the record it
/// returns carries `encryptedAPKAMSymmetricKey` — the wrapped key an approver
/// uses to admit an enrollment.
///
/// The gate used to be `namespaces.containsKey('__manage')` and nothing else,
/// so a caller holding `__manage:r` — which can never approve anything — was
/// handed the key material for every enrollment on the atSign. enroll:fetch
/// refused that same caller the same field for a single enrollment.
///
/// The bar is now the caller's own `__manage` LETTER, which is the audience
/// the server already states for this value elsewhere: the pending-enrollment
/// notification goes to clients holding `__manage` at `rw`.
void main() {
  AtSignLogger.root_level = 'WARNING';

  group('enroll:list projects by the caller\'s __manage letter', () {
    late EnrollVerbHandler enrollVerbHandler;

    setUpAll(() async => await verbTestsSetUpAll());
    setUp(() async {
      await verbTestsSetUp();
      enrollVerbHandler = EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
    });
    tearDown(() async => await verbTestsTearDown());

    /// Stores an approved enrollment holding [namespaces] and returns its id.
    Future<String> storeEnrollment(Map<String, String> namespaces,
        {String secret = 'the-wrapped-apkam-symmetric-key'}) async {
      final enrollId = Uuid().v4();
      await keyValueStore.put(
          '$enrollId.new.enrollments.__manage$alice',
          AtData()
            ..data = jsonEncode({
              'sessionId': Uuid().v4(),
              'appName': 'wavi',
              'deviceName': 'pixel-${Uuid().v4()}',
              'namespaces': namespaces,
              'apkamPublicKey': 'aPublicKeyValue',
              'encryptedAPKAMSymmetricKey': secret,
              'requestType': 'newEnrollment',
              'approval': {'state': 'approved'}
            }));
      return enrollId;
    }

    /// Runs `enroll:list` as [callerId].
    Future<Map<String, dynamic>> listAs(String? callerId) async {
      inboundConnection.metaData
        ..isAuthenticated = true
        ..authType =
            callerId == null ? AuthType.pkamLegacy : AuthType.apkam
        ..sessionID = Uuid().v4();
      inboundConnection.metadata.enrollmentId = callerId;
      final response = Response();
      await enrollVerbHandler.processVerb(response,
          getVerbParam(VerbSyntax.enroll, 'enroll:list'), inboundConnection);
      expect(response.isError, isFalse, reason: '${response.errorMessage}');
      return jsonDecode(response.data!) as Map<String, dynamic>;
    }

    test('a __manage:r administrator gets the roster without the key material',
        () async {
      // A target worth reading about, and a read-only administrator.
      final targetId = await storeEnrollment({'wavi': 'rw'});
      final callerId = await storeEnrollment({'__manage': 'r'});

      final listed = await listAs(callerId);
      final target = listed['$targetId.new.enrollments.__manage$alice']
          as Map<String, dynamic>;

      expect(target.containsKey('encryptedAPKAMSymmetricKey'), isFalse,
          reason: 'a caller that can never approve can never have a use for '
              'the wrapped key, and enroll:fetch already refuses it the same '
              'value for a single enrollment');
      expect(target.containsKey('apkamPublicKey'), isFalse,
          reason: 'the credential itself is not roster data');
      expect(target.containsKey('sessionId'), isFalse);

      // ABSENT, not blanked: a null would be indistinguishable from an
      // enrollment that never carried one.
      expect(target['encryptedAPKAMSymmetricKey'], isNull);

      // And it is still a usable roster — the redaction has to leave an
      // administrator able to do its job, or it is a denial of service
      // rather than a projection.
      expect(target['appName'], 'wavi');
      expect(target['status'], 'approved');
      expect(target['namespace'], {'wavi': 'rw'});
      expect(target['namespaces'], {'wavi': 'rw'});
    });

    test('a __manage:rw administrator still gets the key material', () async {
      // The control, and the reason the assertion above is about the LETTER
      // rather than about redaction being unconditional.
      final targetId = await storeEnrollment({'wavi': 'rw'});
      final callerId = await storeEnrollment({'__manage': 'rw'});

      final listed = await listAs(callerId);
      final target = listed['$targetId.new.enrollments.__manage$alice']
          as Map<String, dynamic>;

      expect(target['encryptedAPKAMSymmetricKey'],
          'the-wrapped-apkam-symmetric-key',
          reason: 'an approver needs the wrapped key to admit an enrollment; '
              'this is the flow the field exists for');
    });

    test('an owner connection carrying no enrollment id gets the whole record',
        () async {
      // CRAM, owner and legacy PKAM hold the atSign itself rather than a
      // delegated share of it, so there is no secret here they are not
      // already entitled to read straight out of the keystore.
      final targetId = await storeEnrollment({'wavi': 'rw'});

      final listed = await listAs(null);
      final target = listed['$targetId.new.enrollments.__manage$alice']
          as Map<String, dynamic>;

      expect(target['encryptedAPKAMSymmetricKey'],
          'the-wrapped-apkam-symmetric-key');
    });

    test('a caller without __manage still sees its own record whole',
        () async {
      // Its own key material, which the client holding the enrollment
      // already has — narrowing this would break the caller's own client
      // while protecting nothing.
      await storeEnrollment({'wavi': 'rw'});
      final callerId = await storeEnrollment({'buzz': 'rw'});

      final listed = await listAs(callerId);
      expect(listed.keys.length, 1,
          reason: 'a caller without __manage is narrowed to its own record');
      final own = listed.values.single as Map<String, dynamic>;
      expect(own['encryptedAPKAMSymmetricKey'],
          'the-wrapped-apkam-symmetric-key');
    });
  });
}
