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

/// `enroll:list` returns every enrollment on the atSign, each carrying the
/// wrapped key an approver uses to admit an enrollment. These pin which
/// projection each caller gets, on the caller's own `__manage` letter.
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
        ..authType = callerId == null ? AuthType.cram : AuthType.apkam
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

      expect(target['encryptedAPKAMSymmetricKey'], isNull);

      expect(target['appName'], 'wavi');
      expect(target['status'], 'approved');
      expect(target['namespace'], {'wavi': 'rw'});
      expect(target['namespaces'], {'wavi': 'rw'});
    });

    test('a __manage:rw administrator still gets the key material', () async {
      // The control: it is the letter that decides, not redaction being
      // unconditional.
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

    test('a CRAM connection gets the whole record',
        () async {
      final targetId = await storeEnrollment({'wavi': 'rw'});

      final listed = await listAs(null);
      final target = listed['$targetId.new.enrollments.__manage$alice']
          as Map<String, dynamic>;

      expect(target['encryptedAPKAMSymmetricKey'],
          'the-wrapped-apkam-symmetric-key');
    });

    test('a caller without __manage still sees its own record whole',
        () async {
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
