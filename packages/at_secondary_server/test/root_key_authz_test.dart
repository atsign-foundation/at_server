import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
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

    setUpAll(() async {
      await verbTestsSetUpAll();
    });

    setUp(() async {
      await verbTestsSetUp();
      updateVerbHandler = UpdateVerbHandler(
          keyValueStore, statsNotificationService, notificationManager, alice);
    });

    tearDown(() async {
      await verbTestsTearDown();
    });

    /// Binds an approved enrollment with [namespaces] and returns its id.
    Future<String> bindEnrollment(Map<String, String> namespaces) async {
      inboundConnection.metadata.isAuthenticated = true;
      final enrollId = Uuid().v4();
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
            () =>
                updateVerbHandler.isAuthorizedSync(enroll, enrollId, atKey: key),
            returnsNormally,
            reason: '$key must not throw out of the authorization check');
      }
    });
  });
}
