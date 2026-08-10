import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops.dart' show MlDsa65PureDartAlgo;
import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/encryption_util.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// End-to-end ML-DSA PKAM over the real wire.
///
/// The unit suite verifies an ML-DSA signature through the production
/// dispatch, but in-process. This drives the whole path: a genuine ML-DSA
/// keypair is generated here, enrolled over the wire, and used to answer a
/// real `from:` challenge on a fresh connection.
///
/// That distinction has bitten before — a resolved at_chops with no mldsa65
/// verification branch sat green against tests that only asserted record
/// storage, while the live wire died parsing a raw ML-DSA key as RSA.
void main() {
  String atSign = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String host = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int port = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  String encryptedPrivateKey = EncryptionUtil.encryptValue(
      encryptionPrivateKeyMap[atSign]!, apkamSymmetricKeyMap[atSign]!);
  String encryptedSelfKey = EncryptionUtil.encryptValue(
      aesKeyMap[atSign]!, apkamSymmetricKeyMap[atSign]!);
  String encryptedApkamSymmetricKey = EncryptionUtil.encryptKey(
      apkamSymmetricKeyMap[atSign]!, encryptionPublicKeyMap[atSign]!);

  List<OutboundConnectionFactory> open = [];

  Future<OutboundConnectionFactory> newConnection() async {
    OutboundConnectionFactory c = await OutboundConnectionFactory()
        .initiateConnectionWithListener(atSign, host, port);
    open.add(c);
    return c;
  }

  tearDown(() async {
    for (final c in open) {
      await c.close();
    }
    open = [];
  });

  /// Answers a real `from:` challenge with an ML-DSA signature over
  /// [secretKey], and returns the server's response to `pkam:`.
  Future<String> authenticateWithMlDsa(String enrollmentId, Uint8List secretKey,
      {bool tamper = false}) async {
    OutboundConnectionFactory client = await newConnection();
    String challenge = (await client.sendRequestToServer(
            'from:$atSign:clientConfig:${jsonEncode({'version': '3.0.57'})}'))
        .replaceAll('data:', '')
        .trim();

    Uint8List signature = await MlDsa65PureDartAlgo()
        .signBytes(Uint8List.fromList(utf8.encode(challenge)),
            secretKey: secretKey);
    if (tamper) {
      signature = Uint8List.fromList(signature)..[0] ^= 0xff;
    }

    return (await client.sendRequestToServer(
            'pkam:signingAlgo:mldsa65:enrollmentId:$enrollmentId:'
            '${base64Encode(signature)}'))
        .trim();
  }

  test('an ML-DSA enrollment authenticates over the wire', () async {
    final mlDsa = await MlDsa65PureDartAlgo().generateKeyPair();

    OutboundConnectionFactory owner = await newConnection();
    expect((await owner.authenticateConnection(authType: AuthType.cram)).trim(),
        'data:success');

    // Enrolled through the OTP path deliberately, NOT by auto-approval on the
    // CRAM connection: that path also writes the request's key as the atSign's
    // default pkam public key, which would leave every later legacy PKAM in
    // this suite trying to verify an RSA signature against an ML-DSA key.
    String otp = (await owner.sendRequestToServer('otp:get'))
        .replaceFirst('data:', '')
        .trim();
    OutboundConnectionFactory requester = await newConnection();
    String enrollResponse = await requester.sendRequestToServer(
        'enroll:request:{"appName":"mldsa-app-${Uuid().v4().hashCode}","deviceName":"device-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"${base64Encode(mlDsa.publicKey)}","signingAlgo":"mldsa65","encryptedAPKAMSymmetricKey":"$encryptedApkamSymmetricKey"}');
    Map enrollJson = jsonDecode(enrollResponse.replaceFirst('data:', ''));
    expect(enrollJson['status'], 'pending');
    String enrollmentId = enrollJson['enrollmentId'];

    String approval = await owner.sendRequestToServer(
        'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"$encryptedPrivateKey","encryptedDefaultSelfEncryptionKey":"$encryptedSelfKey"}');
    expect(jsonDecode(approval.replaceFirst('data:', ''))['status'], 'approved');

    // The signature is produced here from the generated secret key and
    // verified by the server through its real at_chops dispatch.
    expect(await authenticateWithMlDsa(enrollmentId, mlDsa.secretKey),
        'data:success');

    // Control: a tampered signature must be refused. Without it, the success
    // above would show the request was routed, not that anything was verified.
    // Asserted against the exact refusal, observed reaching
    // PkamMlDsa65SigningAlgo and failing verification there, so this cannot
    // pass by way of some unrelated error.
    expect(
        await authenticateWithMlDsa(enrollmentId, mlDsa.secretKey,
            tamper: true),
        'error:{"errorCode":"AT0401","errorDescription":"Exception: pkam '
            'authentication failed"}',
        reason: 'a corrupted ML-DSA signature must not authenticate');
  }, timeout: Timeout(Duration(minutes: 3)));
}
