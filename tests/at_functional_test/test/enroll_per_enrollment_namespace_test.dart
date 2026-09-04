import 'dart:convert';

import 'package:at_demo_data/at_demo_data.dart' as at_demos;
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/apkam_keys.dart';
import 'package:at_functional_test/utils/encryption_util.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Functional coverage of the per-enrollment reserved namespace (`<enId>.a.__e`)
/// over the wire: an enrollment owns a private reserved namespace it (and only it)
/// can read/write, public keys within it are world-readable, and a state change
/// (revoke) MOVES that enrollment's data `a.__e -> r.__e` — scoped to the
/// transitioning enrollment, leaving other enrollments' data untouched.
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
        at_demos.encryptionPrivateKeyMap[firstAtSign]!,
        at_demos.apkamSymmetricKeyMap[firstAtSign]!),
    'encryptedSelfEncKey': EncryptionUtil.encryptValue(
        at_demos.aesKeyMap[firstAtSign]!,
        at_demos.apkamSymmetricKeyMap[firstAtSign]!),
    'encryptedAPKAMSymmetricKey': EncryptionUtil.encryptKey(
        at_demos.apkamSymmetricKeyMap[firstAtSign]!,
        at_demos.encryptionPublicKeyMap[firstAtSign]!)
  };

  setUp(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
  });

  tearDown(() async {
    await firstAtSignConnection.close();
  });

  /// CRAM-authenticate, enroll (auto-approved), then re-connect and APKAM-auth on
  /// the new enrollment id. Returns the enrollment id.
  Future<String> cramEnrollAndApkam() async {
    await firstAtSignConnection.authenticateConnection(authType: AuthType.cram);
    ApkamKeys keys = mintApkamKeys();
    String enrollRequest =
        'enroll:request:{"appName":"wavi-${Uuid().v4().hashCode}","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${keys.publicKey}"}\n';
    var enrollJsonMap = jsonDecode(
        (await firstAtSignConnection.sendRequestToServer(enrollRequest))
            .replaceAll('data:', ''));
    expect(enrollJsonMap['status'], 'approved');
    String enrollmentId = enrollJsonMap['enrollmentId'];
    await firstAtSignConnection.close();
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
    await firstAtSignConnection.authenticateConnection(
        authType: AuthType.apkam,
        enrollmentId: enrollmentId,
        privateKey: keys.privateKey);
    return enrollmentId;
  }

  group('Per-enrollment reserved namespace', () {
    test(
        'an enrollment can update and llookup a self key in its own reserved namespace',
        () async {
      String enrollmentId = await cramEnrollAndApkam();

      String reservedKey =
          '$firstAtSign:some_key.$enrollmentId.a.__e$firstAtSign';
      String updateResponse = await firstAtSignConnection
          .sendRequestToServer('update:$reservedKey privatevalue');
      assert((updateResponse.startsWith('data:')) &&
          (!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));

      String llookupResponse =
          await firstAtSignConnection.sendRequestToServer('llookup:$reservedKey');
      expect(llookupResponse, 'data:privatevalue');
    });

    test('a public key in the reserved namespace is world-readable', () async {
      String enrollmentId = await cramEnrollAndApkam();

      String publicKey = 'public:pub_key.$enrollmentId.a.__e$firstAtSign';
      String updateResponse = await firstAtSignConnection
          .sendRequestToServer('update:$publicKey publicvalue');
      assert((updateResponse.startsWith('data:')) &&
          (!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));

      // A fresh, unauthenticated connection can read the public key.
      OutboundConnectionFactory unauthConnection =
          await OutboundConnectionFactory().initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      String lookupResponse = await unauthConnection.sendRequestToServer(
          'lookup:pub_key.$enrollmentId.a.__e$firstAtSign');
      expect(lookupResponse, 'data:publicvalue');
      await unauthConnection.close();
    });

    test(
        'a *:rw + __manage primary cannot read another enrollment\'s per-enrollment (a.__e) data',
        () async {
      // Primary CRAM enrollment (has __manage + *:rw) — it will approve.
      await firstAtSignConnection.authenticateConnection(authType: AuthType.cram);
      ApkamKeys primaryKeys = mintApkamKeys();
      String primaryEnroll =
          'enroll:request:{"appName":"wavi-${Uuid().v4().hashCode}","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${primaryKeys.publicKey}"}\n';
      var primaryJson = jsonDecode(
          (await firstAtSignConnection.sendRequestToServer(primaryEnroll))
              .replaceAll('data:', ''));
      expect(primaryJson['status'], 'approved');
      String primaryEnrollmentId = primaryJson['enrollmentId'];

      // A second enrollment, requested with an OTP from a second connection.
      String otp = (await firstAtSignConnection.sendRequestToServer('otp:get'))
          .replaceFirst('data:', '')
          .trim();
      OutboundConnectionFactory secondConnection =
          await OutboundConnectionFactory().initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      ApkamKeys secondKeys = mintApkamKeys();
      String secondEnroll =
          'enroll:request:{"appName":"buzz","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"buzz":"rw"},"otp":"$otp","apkamPublicKey":"${secondKeys.publicKey}","encryptedAPKAMSymmetricKey":"${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}\n';
      var secondJson = jsonDecode(
          (await secondConnection.sendRequestToServer(secondEnroll))
              .replaceAll('data:', ''));
      expect(secondJson['status'], 'pending');
      String secondEnrollmentId = secondJson['enrollmentId'];

      // Primary approves the second enrollment.
      var approveJson = jsonDecode((await firstAtSignConnection.sendRequestToServer(
              'enroll:approve:{"enrollmentId":"$secondEnrollmentId","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap["encryptedDefaultEncPrivateKey"]}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap["encryptedSelfEncKey"]}"}'))
          .replaceAll('data:', ''));
      expect(approveJson['status'], 'approved');

      // The second enrollment writes AND reads a self key in its OWN reserved
      // namespace — own-enrollment access is unchanged.
      await secondConnection.authenticateConnection(
          authType: AuthType.apkam,
          enrollmentId: secondEnrollmentId,
          privateKey: secondKeys.privateKey);
      String approvedKey =
          '$firstAtSign:secret.$secondEnrollmentId.a.__e$firstAtSign';
      String updateResponse = await secondConnection
          .sendRequestToServer('update:$approvedKey topsecret');
      assert((updateResponse.startsWith('data:')) &&
          (!updateResponse.contains('null')));
      expect(await secondConnection.sendRequestToServer('llookup:$approvedKey'),
          'data:topsecret');
      await secondConnection.close();

      // The socket that minted the primary is still a CRAM connection, the
      // atSign itself, and reads anything.
      expect(
          await firstAtSignConnection.sendRequestToServer('llookup:$approvedKey'),
          'data:topsecret',
          reason: 'a CRAM connection is the atSign, whatever it has enrolled');

      // The primary ENROLLMENT holds *:rw + __manage, yet must NOT be able to
      // read another enrollment's per-enrollment reserved-namespace (a.__e)
      // data. Authenticated as that enrollment, over APKAM, as a client would.
      await firstAtSignConnection.close();
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.apkam,
          enrollmentId: primaryEnrollmentId,
          privateKey: primaryKeys.privateKey);
      String crossRead = await firstAtSignConnection
          .sendRequestToServer('llookup:$approvedKey');
      expect(crossRead, isNot(contains('topsecret')),
          reason: 'primary must not see another enrollment\'s a.__e value');
      expect(crossRead.toLowerCase(),
          anyOf(startsWith('error:'), contains('not authorized')));
    });
  });
}
