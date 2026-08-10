import 'dart:convert';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_utils/at_logger.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

/// Which notifications reach a SCOPED enrollment's monitor.
///
/// `MonitorVerbHandler._sendNotification` gates every delivery on
/// `isAuthorized(connectionMetadata, atKey: notification.notification)` and
/// drops a failing one by bare `return` — no log at any level. A dropped
/// notification is indistinguishable from one that was never sent, so a
/// receiver-side authorization mismatch presents as "the sender didn't
/// send".
///
/// Provoked by a live observation (at_client_sdk
/// `docs/projects/pq/decisions.md` 44.3): a self-notification for a key in
/// the enrollment's OWN granted namespace never reached that enrollment's
/// monitor, while statsNotifications flowed.
///
/// **What these pin: the authorization gate is NOT the cause.** It permits
/// exactly what it should — the enrollment's own namespace through, another
/// namespace refused. Whatever drops that notification is upstream of here
/// (creation, or the notification manager's dispatch), and the silent
/// `return` is why it presents as a sender-side absence either way.
void main() {
  AtSignLogger.root_level = 'WARNING';

  group('notification delivery authorization for a scoped enrollment', () {
    late LocalLookupVerbHandler handler;

    setUpAll(() async {
      await verbTestsSetUpAll();
    });

    setUp(() async {
      await verbTestsSetUp();
      handler = LocalLookupVerbHandler(keyValueStore, enMgr);
    });

    tearDown(() async {
      await verbTestsTearDown();
    });

    /// An approved enrollment holding exactly `buzz:rw`, bound to the
    /// connection — the shape a PQ self-retrofit produces.
    Future<String> bindBuzzEnrollment() async {
      inboundConnection.metadata.isAuthenticated = true;
      final enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'rf2c',
        'deviceName': 'device',
        'namespaces': {'buzz': 'rw'},
        'apkamPublicKey': 'pk',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      await keyValueStore.put('$enrollId.new.enrollments.__manage$alice',
          AtData()..data = jsonEncode(enrollJson));
      return enrollId;
    }

    test('a self-notification in the enrollment\'s own namespace IS delivered',
        () async {
      await bindBuzzEnrollment();

      // What the monitor sees for a self notify: sharedWith:key@sharedBy,
      // both halves the same atSign.
      expect(
          await handler.isAuthorized(inboundConnection.metadata,
              atKey: '$alice:rf2cmon-1.buzz$alice'),
          isTrue,
          reason: 'the enrollment holds buzz:rw and the key is in buzz — if '
              'this is false, every notification for the enrollment\'s own '
              'data is dropped silently at the monitor');
    });

    test('a notification outside the granted namespace is NOT delivered',
        () async {
      await bindBuzzEnrollment();

      expect(
          await handler.isAuthorized(inboundConnection.metadata,
              atKey: '$alice:secret.wavi$alice'),
          isFalse,
          reason: 'control: the gate must actually gate, or the assertion '
              'above proves nothing');
    });
  });
}
