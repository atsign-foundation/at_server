import 'dart:convert';

import 'package:at_demo_data/at_demo_data.dart' as at_demos;
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/encryption_util.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Functional tests for the `enroll:listns:<namespace>` discovery verb and the
/// `metadata` / `signingAlgo` fields that now ride an `enroll:request`.
///
/// `enroll:listns` returns every approved enrollment that holds read-or-better
/// access to the requested namespace, as a flat list of
/// `{enrollmentId, access, apkamPubKey, metadata}`. The caller must be
/// APKAM-authenticated with an approved enrollment that itself holds >=r on the
/// namespace, otherwise the server refuses with UnAuthorized.
void main() {
  final firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  final firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  final firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  // Encrypted-key bundle the enroll flow needs: the two default keys wrapped for
  // enroll:approve, and the APKAM symmetric key for a second (OTP) enrollment.
  final apkamEncryptedKeysMap = <String, String>{
    'encryptedDefaultEncPrivateKey': EncryptionUtil.encryptValue(
        at_demos.encryptionPrivateKeyMap[firstAtSign]!,
        at_demos.apkamSymmetricKeyMap[firstAtSign]!),
    'encryptedSelfEncKey': EncryptionUtil.encryptValue(
        at_demos.aesKeyMap[firstAtSign]!,
        at_demos.apkamSymmetricKeyMap[firstAtSign]!),
    'encryptedAPKAMSymmetricKey': EncryptionUtil.encryptKey(
        at_demos.apkamSymmetricKeyMap[firstAtSign]!,
        at_demos.encryptionPublicKeyMap[firstAtSign]!),
  };

  final firstAtSignConnection = OutboundConnectionFactory();

  setUp(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
  });

  tearDown(() async {
    await firstAtSignConnection.close();
  });

  group('enroll:listns discovery + request metadata', () {
    test(
        'listns returns an approved enrollment carrying its apkamPubKey and '
        'metadata', () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);

      // A namespace unique to this run so the assertions are unambiguous.
      final namespace = 'listns${Uuid().v4().hashCode}';
      final apkamPublicKey = at_demos.apkamPublicKeyMap[firstAtSign]!;
      final keyPackage = {
        'v': 1,
        'keys': [
          {'kid': 'k', 'use': 'enc', 'alg': 'x-wing', 'pub': 'p'}
        ]
      };

      // enroll:request on a CRAM connection is auto-approved. metadata and
      // signingAlgo ride the request and are persisted on the record.
      //
      // This is the enrollment under inspection, not the one we authenticate
      // as. It is labelled mldsa65 while carrying an RSA key, and PKAM reads
      // the algorithm from the enrollment record rather than the wire, so it
      // cannot authenticate — correctly, since the record is what a verifier
      // would trust. The roster it appears in is what this test is about.
      final enrollRequest = 'enroll:request:${jsonEncode({
            'appName': 'listns-app',
            'deviceName': 'device-${Uuid().v4().hashCode}',
            'namespaces': {namespace: 'rw'},
            'apkamPublicKey': apkamPublicKey,
            'signingAlgo': 'mldsa65',
            'metadata': {'keyPackage': keyPackage},
          })}\n';
      final enrollJson = jsonDecode(
          (await firstAtSignConnection.sendRequestToServer(enrollRequest))
              .replaceFirst('data:', ''));
      final enrollmentId = enrollJson['enrollmentId'];
      expect(enrollmentId, isNotEmpty);
      expect(enrollJson['status'], 'approved');

      // A second, unlabelled (so rsa2048) enrollment on the same namespace is
      // the CALLER: listns needs an APKAM-authenticated connection holding at
      // least read access to the namespace.
      //
      // On its own connection: the enrollment rate limiter is per-connection,
      // and another file in this pack lowers maxRequestsPerTimeFrame to 1
      // server-wide without restoring it, so a second request on the
      // connection above would fail depending on run order.
      final callerConnection = await OutboundConnectionFactory()
          .initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      await callerConnection.authenticateConnection(authType: AuthType.cram);
      final callerRequest = 'enroll:request:${jsonEncode({
            'appName': 'listns-caller',
            'deviceName': 'device-${Uuid().v4().hashCode}',
            'namespaces': {namespace: 'rw'},
            'apkamPublicKey': apkamPublicKey,
          })}\n';
      final callerJson = jsonDecode(
          (await callerConnection.sendRequestToServer(callerRequest))
              .replaceFirst('data:', ''));
      expect(callerJson['status'], 'approved');
      await callerConnection.close();

      // Assert the authentication itself: without this a failure here surfaces
      // much later as a JSON parse error on an unrelated line.
      expect(
          (await firstAtSignConnection.authenticateConnection(
                  authType: AuthType.apkam,
                  enrollmentId: callerJson['enrollmentId']))
              .trim(),
          'data:success');

      final roster = jsonDecode(
          (await firstAtSignConnection
                  .sendRequestToServer('enroll:listns:$namespace\n'))
              .replaceFirst('data:', '')) as List;

      final mine = roster.firstWhere((m) => m['enrollmentId'] == enrollmentId,
          orElse: () => null);
      expect(mine, isNotNull,
          reason: 'the enrollment should appear in the listns roster for the '
              'namespace it was granted');
      expect(mine['access'], 'rw');
      expect(mine['apkamPubKey'], apkamPublicKey);
      expect(mine['metadata'], {'keyPackage': keyPackage});
    });

    test(
        'listns refuses a caller whose enrollment lacks access to the '
        'namespace', () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);

      final grantedNamespace = 'buzz${Uuid().v4().hashCode}';
      final otherNamespace = 'wavi${Uuid().v4().hashCode}';

      // Second enrollment via OTP, scoped to grantedNamespace only.
      final otp = (await firstAtSignConnection.sendRequestToServer('otp:get'))
          .replaceAll('data:', '')
          .trim();
      final secondConnection = await OutboundConnectionFactory()
          .initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      final secondEnrollRequest = 'enroll:request:${jsonEncode({
            'appName': 'buzz',
            'deviceName': 'device-${Uuid().v4().hashCode}',
            'namespaces': {grantedNamespace: 'rw'},
            'otp': otp,
            'apkamPublicKey': at_demos.apkamPublicKeyMap[firstAtSign],
            'encryptedAPKAMSymmetricKey':
                apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey'],
          })}\n';
      final pendingJson = jsonDecode(
          (await secondConnection.sendRequestToServer(secondEnrollRequest))
              .replaceFirst('data:', ''));
      expect(pendingJson['status'], 'pending');
      final secondEnrollId = pendingJson['enrollmentId'];

      // Approve it from the CRAM (owner) connection.
      final approveJson = jsonDecode((await firstAtSignConnection
              .sendRequestToServer('enroll:approve:${jsonEncode({
                    'enrollmentId': secondEnrollId,
                    'encryptedDefaultEncryptionPrivateKey':
                        apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey'],
                    'encryptedDefaultSelfEncryptionKey':
                        apkamEncryptedKeysMap['encryptedSelfEncKey'],
                  })}'))
          .replaceFirst('data:', ''));
      expect(approveJson['status'], 'approved');

      // APKAM-authenticate as the second enrollment and query a namespace it
      // was NOT granted -> the server refuses.
      await secondConnection.authenticateConnection(
          authType: AuthType.apkam, enrollmentId: secondEnrollId);
      final refusal = await secondConnection
          .sendRequestToServer('enroll:listns:$otherNamespace\n');
      expect(refusal, startsWith('error:'),
          reason: 'a caller without >=r on the namespace must be refused');

      await secondConnection.close();
    });
  });
}
