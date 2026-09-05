import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/auth_utils.dart';
import 'package:elliptic/elliptic.dart';
import 'package:test/test.dart';

void main() {
  OutboundConnectionFactory firstAtSignConnection = OutboundConnectionFactory();

  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  //Establish the client socket connection
  setUp(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
  });

  /// Installs [publicKey] at `privatekey:at_pkam_publickey` over the
  /// CURRENTLY AUTHENTICATED connection.
  ///
  /// The plain `update` form, because the server no longer asks a writer to
  /// prove anything about the value: it refuses the write outright unless the
  /// connection is CRAM-authenticated, in every mode. That is the only way
  /// this key can be written at all — it is the credential legacy PKAM
  /// authenticates against, it carries no enrollment id, and nothing can
  /// withdraw it once it is installed.
  String rotationCommand(String publicKey) =>
      'update:${AtConstants.atPkamPublicKey} $publicKey';

  /// Authenticates the connection with the atSign's CRAM secret.
  Future<void> authenticateWithCram() async {
    String fromResponse =
        await firstAtSignConnection.sendRequestToServer('from:$firstAtSign');
    fromResponse = fromResponse.replaceAll('data:', '');
    String cramDigest =
        AuthenticationUtils.getCRAMDigest(firstAtSign, fromResponse);
    expect(await firstAtSignConnection.sendRequestToServer('cram:$cramDigest'),
        'data:success');
  }

  test('pkam authentication using the old syntax', () async {
    String fromResponse =
        await firstAtSignConnection.sendRequestToServer('from:$firstAtSign');
    fromResponse = fromResponse.replaceAll('data:', '');
    String pkamDigest = AuthenticationUtils.generatePKAMDigest(
        pkamPrivateKeyMap[firstAtSign]!, fromResponse);
    String pkamResult =
        await firstAtSignConnection.sendRequestToServer('pkam:$pkamDigest');
    expect(pkamResult, 'data:success');
  });

  test('pkam authentication using the new syntax', () async {
    String fromResponse =
        await firstAtSignConnection.sendRequestToServer('from:$firstAtSign');
    fromResponse = fromResponse.replaceAll('data:', '');
    String pkamDigest = AuthenticationUtils.generatePKAMDigest(
        pkamPrivateKeyMap[firstAtSign]!, fromResponse);
    String pkamResult = await firstAtSignConnection.sendRequestToServer(
        'pkam:signingAlgo:rsa2048:hashingAlgo:sha256:$pkamDigest');
    expect(pkamResult, 'data:success');
  });

  test('pkam authentication - new syntax - passing invalid signing algo',
      () async {
    String fromResponse =
        await firstAtSignConnection.sendRequestToServer('from:$firstAtSign');
    fromResponse = fromResponse.replaceAll('data:', '');
    String pkamDigest = AuthenticationUtils.generatePKAMDigest(
        pkamPrivateKeyMap[firstAtSign]!, fromResponse);
    String pkamResult = await firstAtSignConnection.sendRequestToServer(
        'pkam:signingAlgo:rsa2047:hashingAlgo:sha256:$pkamDigest');
    expect(pkamResult.contains('Exception'), true);
  });

  test('pkam authentication using ecc ', () async {
    final eccAlgo = EccSigningAlgo();
    var ec = getSecp256r1();
    final eccPrivateKey = ec.generatePrivateKey();
    eccAlgo.privateKey = eccPrivateKey;

    // CRAM, not PKAM. Installing this key is refused to every connection
    // except a CRAM one, in every mode, so the rotation this test needs
    // cannot be made over the PKAM connection that used to make it —
    // authenticating with the key being replaced no longer buys the right to
    // replace it.
    await authenticateWithCram();

    final String eccPublicKey = eccPrivateKey.publicKey.toString();
    var response = await firstAtSignConnection
        .sendRequestToServer(rotationCommand(eccPublicKey));
    expect(response, 'data:-1');

    String fromResponse =
        await firstAtSignConnection.sendRequestToServer('from:$firstAtSign');
    fromResponse = fromResponse.replaceAll('data:', '');

    final dataToSign = fromResponse.trim();
    final dataInBytes = Uint8List.fromList(utf8.encode(dataToSign));
    final signature = eccAlgo.sign(dataInBytes);
    String encodedSignature = base64Encode(signature);
    try {
      String pkamResult = await firstAtSignConnection.sendRequestToServer(
          'pkam:signingAlgo:ecc_secp256r1:hashingAlgo:sha256:$encodedSignature');
      expect(pkamResult, 'data:success');
    } finally {
      // Back over CRAM for the same reason: the ECC PKAM connection this test
      // just proved works is no more entitled to write this key than any
      // other. Leaving the rig's own keypair behind matters — every other
      // test in the pack authenticates with it.
      await authenticateWithCram();
      await firstAtSignConnection
          .sendRequestToServer(rotationCommand(pkamPublicKeyMap[firstAtSign]!));
    }
  });
}
