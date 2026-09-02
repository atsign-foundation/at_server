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

  /// The id the server gives the housekeeping enrollment — the identity a
  /// legacy PKAM connection authenticates as. A RAW LITERAL: it is at-rest
  /// and cross-repo, so a change to it has to break this test rather than
  /// follow along.
  const String housekeepingId = 'primary';

  /// The `update:json` command that installs [publicKey] at
  /// `privatekey:at_pkam_publickey`, carrying the proof of possession the
  /// server demands of a ROTATION.
  ///
  /// The server refuses a rotation that does not prove the sender holds the
  /// private half of the key it is installing, because it cannot test that
  /// afterwards: a well-formed key nobody holds leaves `primary` counted as
  /// the atSign's surviving unexpiring root while nothing can authenticate as
  /// it. [signature] is over `primary|<publicKey>|<signingAlgo>`, made with
  /// the NEW private half — the same framing `enroll:update` demands of every
  /// other credential.
  ///
  /// The plain `update:privatekey:at_pkam_publickey <value>` form has no
  /// parameter that could carry a signature, so a rotation must use the JSON
  /// form. `metadata` is a whole Metadata document because `Metadata.fromJson`
  /// reads `isPublic` into a non-nullable bool.
  String rotationCommand(
      String publicKey, String signingAlgo, String signature) {
    final document = (UpdateParams()
          ..atKey = AtConstants.atPkamPublicKey
          ..value = publicKey
          ..metadata = Metadata())
        .toJson();
    document['signingAlgo'] = signingAlgo;
    document['apkamPublicKeySignature'] = signature;
    return 'update:json:${jsonEncode(document)}';
  }

  String signableFor(String publicKey, String signingAlgo) =>
      '$housekeepingId|$publicKey|$signingAlgo';

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
    // updating the public key to ecc public key. The connection has just
    // authenticated with the key it is replacing, which proves possession of
    // the OLD one; the signature below proves possession of the NEW one,
    // which is what the server demands of every rotation.
    final String eccPublicKey = eccPrivateKey.publicKey.toString();
    final String eccProof = base64Encode(eccAlgo.sign(Uint8List.fromList(
        utf8.encode(signableFor(eccPublicKey, 'ecc_secp256r1')))));
    var response = await firstAtSignConnection.sendRequestToServer(
        rotationCommand(eccPublicKey, 'ecc_secp256r1', eccProof));
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
      // updating the public key back to the original one, proving possession
      // of it exactly as the rotation above did. A CRAM connection is not
      // exempt: it can strand the atSign the same way, and the exemption is
      // about the atSign never having minted the legacy identity rather than
      // about who is asking.
      var publicKey = pkamPublicKeyMap[firstAtSign]!;
      final String restoreProof = AuthenticationUtils.generatePKAMDigest(
          pkamPrivateKeyMap[firstAtSign]!,
          signableFor(publicKey, 'rsa2048'));
      await firstAtSignConnection.sendRequestToServer(
          rotationCommand(publicKey, 'rsa2048', restoreProof));
    }
  });
}
