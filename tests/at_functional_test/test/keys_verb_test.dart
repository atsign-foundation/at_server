import 'dart:convert';
import 'dart:io';

import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'at_demo_data.dart' as demo;
import 'functional_test_commons.dart';
import 'pkam_utils.dart';
import 'package:encrypt/encrypt.dart';
import 'package:crypton/crypton.dart';

Socket? socketConnection1;
Socket? socketConnection2;
var firstAtsignServer =
    ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
var firstAtsignPort =
    ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

Future<void> _connect() async {
  // socket connection for first atsign
  socketConnection1 =
      await secure_socket_connection(firstAtsignServer, firstAtsignPort);
  socket_listener(socketConnection1!);
}

void main() {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];

  //Establish the client socket connection
  setUp(() async {
    await _connect();
  });

  group('A group of tests to verify keys verb test', () {
    test(
        'check keys verb put operation - enroll request on authenticated connection',
        () async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      print('from verb response : $fromResponse');
      fromResponse = fromResponse.replaceAll('data:', '');
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'pkam:$pkamDigest');
      var pkamResult = await read();
      expect(pkamResult, 'data:success\n');
      var enrollRequest =
          'enroll:request:appName:wavi:deviceName:pixel:namespaces:[wavi,rw]:apkamPublicKey:${demo.pkamPublicKeyMap[firstAtsign]!}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      var enrollmentId = enrollJsonMap['enrollmentId'];
      expect(enrollmentId, isNotEmpty);
      expect(enrollJsonMap['status'], 'success');
      var encryptionPublicKey = encryptionPublicKeyMap[firstAtsign];

      //1. put encryption public key
      var keysPutPublicEncryptionKeyCommand =
          'keys:put:public:namespace:__global:keyType:rsa2048:keyName:encryption_$enrollmentId $encryptionPublicKey';
      await socket_writer(
          socketConnection1!, keysPutPublicEncryptionKeyCommand);
      var publicKeyPutResponse = await read();
      expect(publicKeyPutResponse, 'data:-1\n');

      //2. put self symmetric key which is encrypted with encryption public key
      var aesKey = AES(Key.fromSecureRandom(32)).key.base64;

      var rsaPublicKey = RSAPublicKey.fromString(encryptionPublicKey!);
      var encryptedAESKey = rsaPublicKey.encrypt(aesKey);
      var selfSymmetricKeyCommand =
          'keys:put:self:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes256:encryptionKeyName:encryption_$enrollmentId:keyName:myAESkey $encryptedAESKey';
      await socket_writer(socketConnection1!, selfSymmetricKeyCommand);
      var selfKeyPutResponse = await read();
      expect(selfKeyPutResponse, 'data:-1\n');

      //3. put encryption private key which is encrypted with self symmetric key
      var rsaPrivateKey = encryptionPrivateKeyMap[firstAtsign];
      var encryptedPrivateKey = Encrypter(AES(Key.fromBase64(aesKey)))
          .encrypt(rsaPrivateKey!, iv: IV.fromLength(16))
          .base64;
      var privateKeyCommand =
          'keys:put:private:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes:encryptionKeyName:myAESkey:keyName:myPrivateKey $encryptedPrivateKey';
      await socket_writer(socketConnection1!, privateKeyCommand);
      var privateKeyPutResponse = await read();
      expect(privateKeyPutResponse, 'data:-1\n');

      //4. test keys:get:public
      await socket_writer(socketConnection1!, 'keys:get:public');
      var getPublicKeysResponse = await read();
      getPublicKeysResponse = getPublicKeysResponse.replaceFirst('data:', '');
      var getPublicKeysResponseJson = jsonDecode(getPublicKeysResponse);
      expect(getPublicKeysResponseJson.length, greaterThanOrEqualTo(1));

      //5. test keys:get:self
      await socket_writer(socketConnection1!, 'keys:get:public');
      var getSelfKeysResponse = await read();
      getSelfKeysResponse = getSelfKeysResponse.replaceFirst('data:', '');
      var getSelfKeysResponseJson = jsonDecode(getSelfKeysResponse);
      expect(getSelfKeysResponseJson.length, greaterThanOrEqualTo(1));

      //6. test keys:get:private
      await socket_writer(socketConnection1!, 'keys:get:public');
      var getPrivateKeysResponse = await read();
      getPrivateKeysResponse = getPrivateKeysResponse.replaceFirst('data:', '');
      var getPrivateKeysResponseJson = jsonDecode(getPrivateKeysResponse);
      expect(getPrivateKeysResponseJson.length, greaterThanOrEqualTo(1));
    });
  });
}
