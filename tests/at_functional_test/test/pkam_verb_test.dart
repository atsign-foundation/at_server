import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:at_chops/src/algorithm/ecc_signing_algo.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:elliptic/elliptic.dart';
import 'package:test/test.dart';
import 'at_demo_data.dart';
import 'functional_test_commons.dart';
import 'pkam_utils.dart';

void main() {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];

  Socket? socketFirstAtsign;

  //Establish the client socket connection
  setUp(() async {
    var firstAtsignServer =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    var firstAtsignPort =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    // socket connection for first atsign
    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
  });

  test('pkam authentication using the old syntax', () async {
    await socket_writer(socketFirstAtsign!, 'from:$firstAtsign');
    var fromResponse = await read();
    print('from verb response : $fromResponse');
    fromResponse = fromResponse.replaceAll('data:', '');
    var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
    await socket_writer(socketFirstAtsign!, 'pkam:$pkamDigest');
    var pkamResult = await read();
    expect(pkamResult, 'data:success\n');
  });

  test('pkam authentication using the new syntax', () async {
    await socket_writer(socketFirstAtsign!, 'from:$firstAtsign');
    var fromResponse = await read();
    print('from verb response : $fromResponse');
    fromResponse = fromResponse.replaceAll('data:', '');
    var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
    await socket_writer(socketFirstAtsign!,
        'pkam:signingAlgo:rsa2048:hashingAlgo:sha256:$pkamDigest');
    var pkamResult = await read();
    expect(pkamResult, 'data:success\n');
  });

  test(
      'pkam authentication using the new syntax by passing invalid signing algo',
      () async {
    await socket_writer(socketFirstAtsign!, 'from:$firstAtsign');
    var fromResponse = await read();
    fromResponse = fromResponse.replaceAll('data:', '');
    var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
    await socket_writer(socketFirstAtsign!,
        'pkam:signingAlgo:rsa2047:hashingAlgo:sha256:$pkamDigest');
    var pkamResult = await read();
    expect(pkamResult.contains('Exception'), true);
  });

//   pkam using ecc
// - generate key pair using
// final eccPrivateKey = ec.generatePrivateKey();
// - update the public key eccPrivateKey.publicKey to server.
//(update:privatekey:at_pkam_publickey <ecc_public key>.
// - call ecc pkam using pkam:signingAlgo:ecc_secp256r1:hashingAlgo:sha256:<signature>
  test('pkam authentication using ecc ', () async {
    final eccAlgo = EccSigningAlgo();
    var ec = getSecp256r1();
    final eccPrivateKey = ec.generatePrivateKey();
    eccAlgo.privateKey = eccPrivateKey;
    //  doing an cram auth in order to update public key to server
    await socket_writer(socketFirstAtsign!, 'from:$firstAtsign');
    var fromResponse = await read();
    fromResponse = fromResponse.replaceAll('data:', '');
    var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
    await socket_writer(socketFirstAtsign!, 'pkam:$pkamDigest');
    var cramResponse = await read();
    expect(cramResponse, 'data:success\n');
    await socket_writer(socketFirstAtsign!,
        'update:privatekey:at_pkam_publickey ${eccPrivateKey.publicKey}');
    var response = await read();
    print('update private key response : $response');
    expect(response, 'data:-1\n');
    await socket_writer(socketFirstAtsign!, 'from:$firstAtsign');
    fromResponse = await read();
    print('from verb response : $fromResponse');
    fromResponse = fromResponse.replaceAll('data:', '');

    final dataToSign = fromResponse.trim();
    final dataInBytes = Uint8List.fromList(dataToSign.codeUnits);
    final signature = eccAlgo.sign(dataInBytes);
    String encodedSignature = base64Encode(signature);
    await socket_writer(socketFirstAtsign!,
        'pkam:signingAlgo:ecc_secp256r1:hashingAlgo:sha256:$encodedSignature');
    var pkamResult = await read();
    expect(pkamResult, 'data:success\n');

    // updating the public key to the original one
    var publicKey = pkamPublicKeyMap[firstAtsign];
    await socket_writer(socketFirstAtsign!,
        'update:privatekey:at_pkam_publickey $publicKey');
  });
}
