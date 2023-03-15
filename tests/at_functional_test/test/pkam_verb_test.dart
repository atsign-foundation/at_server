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
      'pkam authentication - new syntax - passing invalid signing algo',
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

  test('pkam authentication using ecc ', () async {
    final eccAlgo = EccSigningAlgo();
    var ec = getSecp256r1();
    final eccPrivateKey = ec.generatePrivateKey();
    eccAlgo.privateKey = eccPrivateKey;
    await socket_writer(socketFirstAtsign!, 'from:$firstAtsign');
    var fromResponse = await read();
    fromResponse = fromResponse.replaceAll('data:', '');
    var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
    await socket_writer(socketFirstAtsign!, 'pkam:$pkamDigest');
    var pkamResponse = await read();
    expect(pkamResponse, 'data:success\n');
    await socket_writer(socketFirstAtsign!,
        'update:privatekey:at_pkam_publickey ${eccPrivateKey.publicKey.toString()}');
    var response = await read();
    expect(response, 'data:-1\n');
    await socket_writer(socketFirstAtsign!, 'from:$firstAtsign');
    fromResponse = await read();
    fromResponse = fromResponse.replaceAll('data:', '');

    final dataToSign = fromResponse.trim();
    final dataInBytes = Uint8List.fromList(utf8.encode(dataToSign));
    final signature = eccAlgo.sign(dataInBytes);
    String encodedSignature = base64Encode(signature);
    // var decodedSignature = base64Decode(encodedSignature);
    // var verifyResult = eccAlgo.verify(dataInBytes, decodedSignature,
    //     publicKey: eccPrivateKey.publicKey.toString());
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
