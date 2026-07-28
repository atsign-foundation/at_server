import 'dart:convert';

import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/encryption_util.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Functional (over-the-wire) coverage for enrollment authorization GATES whose
/// deny paths were previously only unit-tested (or untested). Each test drives a
/// real scoped APKAM enrollment through the CRAM+OTP+APKAM flow and asserts the
/// gate fires (or, for allow twins, that it does not).
void main() {
  OutboundConnectionFactory firstAtSignConnection = OutboundConnectionFactory();
  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  Map<String, String> apkamEncryptedKeysMap = <String, String>{
    'encryptedDefaultEncPrivateKey': EncryptionUtil.encryptValue(
        encryptionPrivateKeyMap[firstAtSign]!,
        apkamSymmetricKeyMap[firstAtSign]!),
    'encryptedSelfEncKey': EncryptionUtil.encryptValue(
        aesKeyMap[firstAtSign]!, apkamSymmetricKeyMap[firstAtSign]!),
    'encryptedAPKAMSymmetricKey': EncryptionUtil.encryptKey(
        apkamSymmetricKeyMap[firstAtSign]!,
        encryptionPublicKeyMap[firstAtSign]!)
  };

  setUp(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
  });

  group('enrollment authorization gates — functional coverage', () {
    /// Owner (CRAM-authed) issues an OTP, a second connection sends a scoped
    /// enroll:request, the owner approves it, and the second connection
    /// APKAM-authenticates. Returns the (connection, enrollmentId).
    Future<(OutboundConnectionFactory, String)> createApprovedEnrollment(
        Map<String, String> namespaces) async {
      final otp = (await firstAtSignConnection.sendRequestToServer('otp:get'))
          .replaceAll('data:', '')
          .trim();
      final conn = await OutboundConnectionFactory()
          .initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      final reqBody = jsonEncode({
        'appName': 'app-${Uuid().v4().hashCode}',
        'deviceName': 'device-${Uuid().v4().hashCode}',
        'namespaces': namespaces,
        'otp': otp,
        'apkamPublicKey': apkamPublicKeyMap[firstAtSign],
        'encryptedAPKAMSymmetricKey':
            apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey'],
      });
      final pending = jsonDecode(
          (await conn.sendRequestToServer('enroll:request:$reqBody\n'))
              .replaceAll('data:', ''));
      final enrollmentId = pending['enrollmentId'] as String;
      final approveBody = jsonEncode({
        'enrollmentId': enrollmentId,
        'encryptedDefaultEncryptionPrivateKey':
            apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey'],
        'encryptedDefaultSelfEncryptionKey':
            apkamEncryptedKeysMap['encryptedSelfEncKey'],
      });
      final approve = jsonDecode((await firstAtSignConnection
              .sendRequestToServer('enroll:approve:$approveBody'))
          .replaceAll('data:', ''));
      expect(approve['status'], 'approved');
      await conn.authenticateConnection(
          authType: AuthType.apkam, enrollmentId: enrollmentId);
      return (conn, enrollmentId);
    }

    // ---- otp:get / otp:put require __manage ----

    test('otp:get is denied for a scoped enrollment without __manage',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      final (scoped, _) = await createApprovedEnrollment({'buzz': 'rw'});
      final resp = await scoped.sendRequestToServer('otp:get');
      expect(resp, startsWith('error:'), reason: resp);
      expect(resp.toLowerCase(), contains('__manage'));
      await scoped.close();
    });

    test(
        'otp:put is denied for a scoped enrollment without __manage, allowed for the owner',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      final (scoped, _) = await createApprovedEnrollment({'buzz': 'rw'});
      final denied = await scoped.sendRequestToServer('otp:put:ABC123');
      expect(denied, startsWith('error:'), reason: denied);
      await scoped.close();
      // The owner (CRAM / no enrollmentId) IS allowed to store an SPP.
      final ok = await firstAtSignConnection.sendRequestToServer('otp:put:XYZ789');
      expect(ok, 'data:ok');
    });

    // ---- enroll:fetch: self, or __manage + all target namespaces ----

    test(
        'enroll:fetch of another enrollment is denied without __manage (no secret returned)',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      final (target, targetId) = await createApprovedEnrollment({'buzz': 'rw'});
      await target.close();
      final (caller, _) = await createApprovedEnrollment({'wavi': 'rw'});
      final resp = await caller
          .sendRequestToServer('enroll:fetch:{"enrollmentId":"$targetId"}');
      expect(resp, startsWith('error:'), reason: resp);
      expect(resp, isNot(contains('encryptedAPKAMSymmetricKey')));
      await caller.close();
    });

    test(
        'enroll:fetch of another enrollment is allowed with __manage + all its namespaces',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      final (target, targetId) = await createApprovedEnrollment({'wavi': 'rw'});
      await target.close();
      final (mgr, _) =
          await createApprovedEnrollment({'wavi': 'rw', '__manage': 'rw'});
      final resp = await mgr
          .sendRequestToServer('enroll:fetch:{"enrollmentId":"$targetId"}');
      expect(resp, startsWith('data:'), reason: resp);
      expect(resp, contains('appName'));
      await mgr.close();
    });

    // ---- __manage key not reachable via the '*' wildcard with a generic verb ----

    test(
        'a *:rw enrollment without __manage cannot reach a __manage key via a generic verb',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      final (wild, wildId) = await createApprovedEnrollment({'*': 'rw'});
      final manageKey = '$wildId.new.enrollments.__manage$firstAtSign';
      final resp = await wild.sendRequestToServer('llookup:$manageKey');
      expect(resp, startsWith('error:'), reason: resp);
      await wild.close();
    });

    // ---- otp on an unauthenticated connection ----

    test('otp: on an unauthenticated connection is denied', () async {
      final unauth = await OutboundConnectionFactory()
          .initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      final g = await unauth.sendRequestToServer('otp:get');
      expect(g, startsWith('error:'), reason: g);
      final p = await unauth.sendRequestToServer('otp:put:ABC123');
      expect(p, startsWith('error:'), reason: p);
      await unauth.close();
    });

    // ---- enroll state-machine deny that was untested functionally ----

    test('enroll:deny on a non-pending (approved) enrollment is rejected',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      final (conn, id) = await createApprovedEnrollment({'buzz': 'rw'});
      await conn.close();
      final resp = await firstAtSignConnection
          .sendRequestToServer('enroll:deny:{"enrollmentId":"$id"}');
      expect(resp, startsWith('error:'), reason: resp);
      expect(resp.toLowerCase(), contains('deny'));
    });

    // ---- enroll:approve requires the caller to hold __manage ----

    test('enroll:approve by a caller without __manage is denied', () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      // A pending target enrollment.
      final otp = (await firstAtSignConnection.sendRequestToServer('otp:get'))
          .replaceAll('data:', '')
          .trim();
      final targetConn = await OutboundConnectionFactory()
          .initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      final targetReq = jsonEncode({
        'appName': 't-${Uuid().v4().hashCode}',
        'deviceName': 'd-${Uuid().v4().hashCode}',
        'namespaces': {'buzz': 'rw'},
        'otp': otp,
        'apkamPublicKey': apkamPublicKeyMap[firstAtSign],
        'encryptedAPKAMSymmetricKey':
            apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey'],
      });
      final targetId = jsonDecode(
          (await targetConn.sendRequestToServer('enroll:request:$targetReq\n'))
              .replaceAll('data:', ''))['enrollmentId'];
      // A scoped caller that does NOT hold __manage.
      final (caller, _) = await createApprovedEnrollment({'wavi': 'rw'});
      // Well-formed approve (encrypted keys present) so it passes param
      // validation and reaches the __manage authorization check.
      final approveCmd = 'enroll:approve:${jsonEncode({
            'enrollmentId': targetId,
            'encryptedDefaultEncryptionPrivateKey':
                apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey'],
            'encryptedDefaultSelfEncryptionKey':
                apkamEncryptedKeysMap['encryptedSelfEncKey'],
          })}';
      final resp = await caller.sendRequestToServer(approveCmd);
      expect(resp, startsWith('error:'), reason: resp);
      expect(resp.toLowerCase(), contains('__manage'));
      await caller.close();
      await targetConn.close();
    });

    // ---- enroll:list is narrowed to own record without __manage ----

    test(
        'enroll:list is narrowed to the caller\'s own record for a scoped enrollment',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      final (other, otherId) = await createApprovedEnrollment({'buzz': 'rw'});
      await other.close();
      final (scoped, scopedId) = await createApprovedEnrollment({'wavi': 'rw'});
      final resp = (await scoped.sendRequestToServer('enroll:list'))
          .replaceAll('data:', '');
      expect(resp, contains(scopedId),
          reason: 'own enrollment record should be listed');
      expect(resp, isNot(contains(otherId)),
          reason: 'another enrollment must not appear without __manage');
      await scoped.close();
    });

    // ---- enroll:listns deny branches ----

    test('enroll:listns requires APKAM auth (owner/CRAM is denied)', () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      final resp =
          await firstAtSignConnection.sendRequestToServer('enroll:listns:wavi');
      expect(resp, startsWith('error:'), reason: resp);
      expect(resp.toLowerCase(), contains('apkam'));
    });

    test('enroll:listns with an empty namespace is rejected', () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      final (scoped, _) = await createApprovedEnrollment({'wavi': 'rw'});
      final resp = await scoped.sendRequestToServer('enroll:listns:');
      expect(resp, startsWith('error:'), reason: resp);
      await scoped.close();
    });
  });
}
