import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/src/algorithm/ecc_signing_algo.dart';
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
    // authenticating to the server to update the public key
    String fromResponse =
        await firstAtSignConnection.sendRequestToServer('from:$firstAtSign');
    fromResponse = fromResponse.replaceAll('data:', '');
    String pkamDigest = AuthenticationUtils.generatePKAMDigest(
        pkamPrivateKeyMap[firstAtSign]!, fromResponse);
    String pkamResponse =
        await firstAtSignConnection.sendRequestToServer('pkam:$pkamDigest');
    expect(pkamResponse, 'data:success');
    // updating the public key to ecc public key
    var response = await firstAtSignConnection.sendRequestToServer(
        'update:privatekey:at_pkam_publickey ${eccPrivateKey.publicKey.toString()}');
    expect(response, 'data:-1');
    fromResponse =
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
      // authenticating to the server to update the public key
      fromResponse =
          await firstAtSignConnection.sendRequestToServer('from:$firstAtSign');
      fromResponse = fromResponse.replaceAll('data:', '');
      String cramDigest =
          AuthenticationUtils.getCRAMDigest(firstAtSign, fromResponse);
      String cramResult =
          await firstAtSignConnection.sendRequestToServer('cram:$cramDigest');
      expect(cramResult, 'data:success');
      // updating the public key back to the original one
      var publicKey = pkamPublicKeyMap[firstAtSign];
      await firstAtSignConnection.sendRequestToServer(
          'update:privatekey:at_pkam_publickey $publicKey');
    }
  });
}
