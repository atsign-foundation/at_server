import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/verb/handler/scan_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

/// A connection that records the close it is asked for. [DummyInboundConnection]
/// closes to nothing and leaves `metadata.isClosed` alone, so the close itself
/// — as opposed to the error response that accompanies it — is otherwise
/// unobservable.
class CloseRecordingConnection extends DummyInboundConnection {
  int closeCount = 0;

  @override
  Future<void> close() async {
    closeCount++;
    await super.close();
  }
}

/// Writes an enrollment record straight to the keystore, in [state], holding
/// [namespaces]. Returns its id.
Future<String> _putEnrollment(
    Map<String, String> namespaces, String state) async {
  final String enrollmentId = Uuid().v4();
  await keyValueStore.put(
      '$enrollmentId.new.enrollments.__manage$alice',
      AtData()
        ..data = jsonEncode({
          'sessionId': '123',
          'appName': 'wavi',
          'deviceName': 'pixel',
          'namespaces': namespaces,
          'apkamPublicKey': 'testPublicKeyValue',
          'requestType': 'newEnrollment',
          'approval': {'state': state}
        }));
  return enrollmentId;
}

void main() {
  group('scan re-checks the approval state on the wildcard fast path', () {
    late ScanVerbHandler scanVerbHandler;

    setUp(() async {
      await verbTestsSetUp();
      scanVerbHandler = ScanVerbHandler(
          keyValueStore, mockOutboundClientManager, cacheManager);
      await keyValueStore.put(
          '@alice:secret.wavi$alice', AtData()..data = 'shhh');
      await keyValueStore.put(
          'public:hello.wavi$alice', AtData()..data = 'hello');
    });

    tearDown(() async => await verbTestsTearDown());

    /// The scan the handler would answer for [enrollmentId], entered at the
    /// filter rather than through `process` — a connection whose enrollment
    /// has left `approved` never reaches the filter through `process`, because
    /// AbstractVerbHandler closes it first (pinned in the group below). The
    /// two gates are independent, and this is the one that decides what a
    /// wildcard enrollment may enumerate.
    Future<List<String>> scanAs(String enrollmentId) async {
      final metadata = DummyInboundConnection().metadata
        ..isAuthenticated = true
        ..sessionID = 'dummy_session'
        ..enrollmentId = enrollmentId;
      return await scanVerbHandler.getLocalKeys(
          metadata, null, false, alice.toString());
    }

    test('a revoked wildcard enrollment enumerates nothing but public keys',
        () async {
      final String enrollmentId =
          await _putEnrollment({'*': 'rw'}, EnrollmentStatus.revoked.name);

      expect(await scanAs(enrollmentId), ['public:hello.wavi$alice'],
          reason: 'a revoked enrollment holds no namespace grant, so the '
              'wildcard branch must not hand it the whole keystore — the '
              'public key is what a caller holding nothing already sees');
    });

    test('and so does a denied one', () async {
      final String enrollmentId =
          await _putEnrollment({'*': 'rw'}, EnrollmentStatus.denied.name);

      expect(await scanAs(enrollmentId), ['public:hello.wavi$alice'],
          reason: 'the gate is on being approved, not on being revoked '
              'specifically');
    });

    test('CONTROL: an approved wildcard enrollment still sees everything',
        () async {
      final String enrollmentId =
          await _putEnrollment({'*': 'rw'}, EnrollmentStatus.approved.name);

      final List<String> keys = await scanAs(enrollmentId);
      expect(keys, contains('@alice:secret.wavi$alice'),
          reason: 'the wildcard grant still means what it means; a gate that '
              'refused this would be measuring nothing');
      expect(keys, contains('public:hello.wavi$alice'));
    });

    test('CONTROL: the per-key branch already refused a revoked enrollment',
        () async {
      final String enrollmentId =
          await _putEnrollment({'wavi': 'rw'}, EnrollmentStatus.revoked.name);

      expect(await scanAs(enrollmentId), ['public:hello.wavi$alice'],
          reason: 'a narrow enrollment is decided by isAuthorized per key, '
              'which has always refused a non-approved enrollment — this is '
              'the behaviour the wildcard branch is being brought into line '
              'with, and it must not move');
    });

    test('CONTROL: an approved narrow enrollment sees its own namespace',
        () async {
      final String enrollmentId =
          await _putEnrollment({'wavi': 'rw'}, EnrollmentStatus.approved.name);

      expect(await scanAs(enrollmentId), contains('@alice:secret.wavi$alice'));
    });
  });

  group('a connection whose enrollment has left approved is closed', () {
    late UpdateVerbHandler updateVerbHandler;
    late CloseRecordingConnection connection;

    setUp(() async {
      await verbTestsSetUp();
      updateVerbHandler = UpdateVerbHandler(
        keyValueStore,
        statsNotificationService,
        notificationManager,
        alice,
      );
      connection = CloseRecordingConnection();
      connection.metadata.isAuthenticated = true;
    });

    tearDown(() async => await verbTestsTearDown());

    /// Null when the verb ran and threw instead of the gate answering. A gate
    /// that fails to close lets the verb body run, and the update handler
    /// refuses on its own authorisation check — so without swallowing that
    /// the assertions below would never be reached, and the failure would
    /// report the verb's refusal rather than the gate's absence.
    Future<Response?> updateAs(String enrollmentId) async {
      connection.metadata.enrollmentId = enrollmentId;
      try {
        return await updateVerbHandler.processInternal(
            'update:$alice:phone.wavi$alice 123', connection);
      } on Exception {
        return null;
      }
    }

    test('a revoked enrollment closes it, with the code pkam would refuse with',
        () async {
      final String enrollmentId =
          await _putEnrollment({'wavi': 'rw'}, EnrollmentStatus.revoked.name);

      final Response? response = await updateAs(enrollmentId);

      expect(connection.closeCount, 1,
          reason: 'revocation has to be total: denying verb by verb is only '
              'ever as complete as the least careful handler');
      expect(response, isNotNull,
          reason: 'the gate answers with a response; a verb that ran and threw '
              'its own refusal instead means the gate did not fire');
      expect(response!.isError, true);
      expect(response.errorCode, 'AT0027',
          reason: 'the code pkam refuses a revoked enrollment with, so a '
              'client cut off mid-session reads the same reason it would have '
              'been given had it connected a moment later');
      expect(response.errorMessage,
          'The enrollment id: $enrollmentId is revoked. Closing the connection');
    });

    test('a denied enrollment closes it', () async {
      final String enrollmentId =
          await _putEnrollment({'wavi': 'rw'}, EnrollmentStatus.denied.name);

      final Response? response = await updateAs(enrollmentId);

      expect(connection.closeCount, 1,
          reason: 'a denied enrollment is as unable to authenticate as a '
              'revoked one');
      expect(response!.errorCode, 'AT0025');
      expect(response.errorMessage,
          'The enrollment id: $enrollmentId is denied. Closing the connection');
    });

    test('a pending enrollment closes it', () async {
      final String enrollmentId =
          await _putEnrollment({'wavi': 'rw'}, EnrollmentStatus.pending.name);

      final Response? response = await updateAs(enrollmentId);

      expect(connection.closeCount, 1,
          reason: 'a pending enrollment could not have opened this connection '
              'in the first place');
      expect(response!.errorCode, 'AT0026');
      expect(response.errorMessage,
          'The enrollment id: $enrollmentId is pending. Closing the connection');
    });

    test('a record whose approval cannot be read closes it', () async {
      final String enrollmentId = Uuid().v4();
      await keyValueStore.put(
          '$enrollmentId.new.enrollments.__manage$alice',
          AtData()
            ..data = jsonEncode({
              'sessionId': '123',
              'appName': 'wavi',
              'deviceName': 'pixel',
              'namespaces': {'wavi': 'rw'},
              'apkamPublicKey': 'testPublicKeyValue',
              'requestType': 'newEnrollment',
            }));

      final Response? response = await updateAs(enrollmentId);

      expect(connection.closeCount, 1,
          reason: 'an unreadable approval is not an approval');
      expect(response!.errorCode, 'AT0028');
      expect(
          response.errorMessage,
          'The enrollment id: $enrollmentId is in an unreadable state. '
          'Closing the connection');
    });

    test('CONTROL: an approved enrollment is left alone', () async {
      final String enrollmentId =
          await _putEnrollment({'wavi': 'rw'}, EnrollmentStatus.approved.name);

      final Response? response = await updateAs(enrollmentId);

      expect(connection.closeCount, 0,
          reason: 'the gate must not close a connection that is entitled to '
              'be open, or every assertion above is about a gate that closes '
              'everything');
      expect(response?.isError, false,
          reason: 'and the verb must actually run — a fixture whose update '
              'fails anyway would satisfy the close count while measuring '
              'nothing');
    });

    test('CONTROL: a connection carrying no enrollment id is left alone',
        () async {
      connection.metadata.enrollmentId = null;

      final Response response = await updateVerbHandler.processInternal(
          'update:$alice:phone.wavi$alice 123', connection);

      expect(connection.closeCount, 0,
          reason: 'a connection carrying no enrollment id — CRAM, owner or '
              'legacy PKAM — stands over no enrollment record, so there is no '
              'approval state for the gate to read');
      expect(response.isError, false);
    });
  });
}
