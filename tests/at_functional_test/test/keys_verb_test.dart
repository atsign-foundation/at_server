import 'dart:convert';
import 'dart:io';

import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:crypton/crypton.dart';
import 'package:encrypt/encrypt.dart';
import 'package:test/test.dart';

import 'at_demo_data.dart' as demo;
import 'functional_test_commons.dart';
import 'pkam_utils.dart';

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

      // 5. test keys:get:publicKey value
      var publicKeyGetCommand =
          'keys:get:keyName:public:encryption_$enrollmentId.__public_keys.__global$firstAtsign';
      await socket_writer(socketConnection1!, publicKeyGetCommand);
      var getPublicKeyResponse = await read();
      getPublicKeyResponse = getPublicKeyResponse.replaceFirst('data:', '');
      var getPublicKeyResponseJson = jsonDecode(getPublicKeyResponse);

      expect(getPublicKeyResponseJson['value'], encryptionPublicKey);
      expect(getPublicKeyResponseJson['keyType'], 'rsa2048');
      expect(getPublicKeyResponseJson['enrollApprovalId'], enrollmentId);

      //6. test keys:get:self
      await socket_writer(socketConnection1!, 'keys:get:self');
      var getSelfKeysResponse = await read();
      getSelfKeysResponse = getSelfKeysResponse.replaceFirst('data:', '');
      var getSelfKeysResponseJson = jsonDecode(getSelfKeysResponse);
      expect(getSelfKeysResponseJson.length, greaterThanOrEqualTo(1));

      // 7. test keys:get:selfKey value
      var selfKeyGetCommand =
          'keys:get:keyName:wavi.pixel.myaesKey.__self_keys.__global$firstAtsign';
      await socket_writer(socketConnection1!, selfKeyGetCommand);
      var getselfKeyResponse = await read();
      getselfKeyResponse = getselfKeyResponse.replaceFirst('data:', '');
      var getselfKeyResponseJson = jsonDecode(getselfKeyResponse);

      expect(getselfKeyResponseJson['value'], encryptedAESKey);
      expect(getselfKeyResponseJson['keyType'], 'aes256');
      expect(getselfKeyResponseJson['enrollApprovalId'], enrollmentId);
      expect(getselfKeyResponseJson['encryptionKeyName'],
          'encryption_$enrollmentId');

      //8. test keys:get:private
      await socket_writer(socketConnection1!, 'keys:get:private');
      var getPrivateKeysResponse = await read();
      getPrivateKeysResponse = getPrivateKeysResponse.replaceFirst('data:', '');
      var getPrivateKeysResponseJson = jsonDecode(getPrivateKeysResponse);
      expect(getPrivateKeysResponseJson.length, greaterThanOrEqualTo(1));

      // 9. test keys:get:private:key
      var privateKeyGetCommand =
          'keys:get:keyName:private:wavi.pixel.myPrivateKey.__private_keys.__global$firstAtsign';
      await socket_writer(socketConnection1!, privateKeyGetCommand);
      var getprivateKeyResponse = await read();
      getprivateKeyResponse = getprivateKeyResponse.replaceFirst('data:', '');
      var getprivateKeyResponseJson = jsonDecode(getprivateKeyResponse);

      expect(getprivateKeyResponseJson['value'], encryptedPrivateKey);
      expect(getprivateKeyResponseJson['keyType'], 'aes');
      expect(getprivateKeyResponseJson['enrollApprovalId'], enrollmentId);
      expect(getprivateKeyResponseJson['encryptionKeyName'], 'myAESkey');

      // delete the public key and check if it is deleted
      await socket_writer(socketConnection1!,
          'keys:delete:keyName:public:encryption_$enrollmentId.__public_keys.__global$firstAtsign');
      var deletePublicKeyResponse = await read();
     expect(deletePublicKeyResponse, 'data:-1\n');

      // delete the private key and check if it is deleted
      await socket_writer(socketConnection1!,
          'keys:delete:keyName:private:wavi.pixel.myPrivateKey.__private_keys.__global$firstAtsign');
      var deletePrivateKeyResponse = await read();
      expect(deletePrivateKeyResponse, 'data:-1\n');

      // delete the self key and check if it is deleted
      await socket_writer(socketConnection1!,
          'keys:delete:keyName:wavi.pixel.myaesKey.__self_keys.__global$firstAtsign');
      var deleteSelfKeyResponse = await read();
      expect(deleteSelfKeyResponse, 'data:-1\n');
    });

    test(
        'check keys verb put operation - enroll request on a second authenticated connection using otp',
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
          'enroll:request:appName:wavi:deviceName:pixel:namespaces:[wavi,rw]:apkamPublicKey:${pkamPublicKeyMap[firstAtsign]!}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'success');

      var totpRequest = 'totp:get\n';
      await socket_writer(socketConnection1!, totpRequest);
      var totpResponse = await read();
      totpResponse = totpResponse.replaceFirst('data:', '');
      totpResponse = totpResponse.trim();

      // connect to the second client
      socketConnection2 =
          await secure_socket_connection(firstAtsignServer, firstAtsignPort);
      socket_listener(socketConnection2!);
      //send second enroll request with totp
      var apkamPublicKey = pkamPublicKeyMap[firstAtsign];
      var secondEnrollRequest =
          'enroll:request:appName:buzz:deviceName:pixel:namespaces:[buzz,rw]:totp:$totpResponse:apkamPublicKey:$apkamPublicKey\n';
      await socket_writer(socketConnection2!, secondEnrollRequest);

      var secondEnrollResponse = await read();
      secondEnrollResponse = secondEnrollResponse.replaceFirst('data:', '');
      var enrollJson = jsonDecode(secondEnrollResponse);
      expect(enrollJson['enrollmentId'], isNotEmpty);
      expect(enrollJson['status'], 'pending');
      var secondEnrollId = enrollJson['enrollmentId'];

      // connect to the first client to approve the enroll request
      await socket_writer(
          socketConnection1!, 'enroll:approve:enrollmentId:$secondEnrollId\n');
      var approveResponse = await read();
      approveResponse = approveResponse.replaceFirst('data:', '');
      var approveJson = jsonDecode(approveResponse);
      expect(approveJson['status'], 'approved');
      expect(approveJson['enrollmentId'], secondEnrollId);

      // connect to the second client to do an apkam
      await socket_writer(socketConnection2!, 'from:$firstAtsign');
      fromResponse = await read();
      fromResponse = fromResponse.replaceAll('data:', '');
      // now do the apkam using the enrollment id
      pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollApprovalId:$secondEnrollId:$pkamDigest\n';

      await socket_writer(socketConnection2!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      print(apkamEnrollIdResponse);
      expect(apkamEnrollIdResponse, 'data:success\n');
      var encryptionPublicKey = encryptionPublicKeyMap[firstAtsign];

      //1. put encryption public key
      var keysPutPublicEncryptionKeyCommand =
          'keys:put:public:namespace:__global:keyType:rsa2048:keyName:encryption_$secondEnrollId $encryptionPublicKey';
      await socket_writer(
          socketConnection2!, keysPutPublicEncryptionKeyCommand);
      var publicKeyPutResponse = await read();
      expect(publicKeyPutResponse, 'data:-1\n');

      //2. put self symmetric key which is encrypted with encryption public key
      var aesKey = AES(Key.fromSecureRandom(32)).key.base64;

      var rsaPublicKey = RSAPublicKey.fromString(encryptionPublicKey!);
      var encryptedAESKey = rsaPublicKey.encrypt(aesKey);
      var selfSymmetricKeyCommand =
          'keys:put:self:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes256:encryptionKeyName:encryption_$secondEnrollId:keyName:myAESkey $encryptedAESKey';
      await socket_writer(socketConnection2!, selfSymmetricKeyCommand);
      var selfKeyPutResponse = await read();
      expect(selfKeyPutResponse, 'data:-1\n');

      //3. put encryption private key which is encrypted with self symmetric key
      var rsaPrivateKey = encryptionPrivateKeyMap[firstAtsign];
      var encryptedPrivateKey = Encrypter(AES(Key.fromBase64(aesKey)))
          .encrypt(rsaPrivateKey!, iv: IV.fromLength(16))
          .base64;
      var privateKeyCommand =
          'keys:put:private:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes:encryptionKeyName:myAESkey:keyName:myPrivateKey $encryptedPrivateKey';
      await socket_writer(socketConnection2!, privateKeyCommand);
      var privateKeyPutResponse = await read();
      expect(privateKeyPutResponse, 'data:-1\n');

      //4. test keys:get:public
      await socket_writer(socketConnection2!, 'keys:get:public');
      var getPublicKeysResponse = await read();
      getPublicKeysResponse = getPublicKeysResponse.replaceFirst('data:', '');
      var getPublicKeysResponseJson = jsonDecode(getPublicKeysResponse);
      expect(getPublicKeysResponseJson.length, greaterThanOrEqualTo(1));

      // 5. test keys:get:publicKey value
      var publicKeyGetCommand =
          'keys:get:keyName:public:encryption_$secondEnrollId.__public_keys.__global$firstAtsign';
      await socket_writer(socketConnection2!, publicKeyGetCommand);
      var getPublicKeyResponse = await read();
      getPublicKeyResponse = getPublicKeyResponse.replaceFirst('data:', '');
      var getPublicKeyResponseJson = jsonDecode(getPublicKeyResponse);

      expect(getPublicKeyResponseJson['value'], encryptionPublicKey);
      expect(getPublicKeyResponseJson['keyType'], 'rsa2048');
      expect(getPublicKeyResponseJson['enrollApprovalId'], secondEnrollId);

      //6. test keys:get:self
      await socket_writer(socketConnection2!, 'keys:get:self');
      var getSelfKeysResponse = await read();
      getSelfKeysResponse = getSelfKeysResponse.replaceFirst('data:', '');
      var getSelfKeysResponseJson = jsonDecode(getSelfKeysResponse);
      expect(getSelfKeysResponseJson.length, greaterThanOrEqualTo(1));

      // 7. test keys:get:selfKey value
      var selfKeyGetCommand =
          'keys:get:keyName:wavi.pixel.myaesKey.__self_keys.__global$firstAtsign';
      await socket_writer(socketConnection2!, selfKeyGetCommand);
      var getselfKeyResponse = await read();
      getselfKeyResponse = getselfKeyResponse.replaceFirst('data:', '');
      var getselfKeyResponseJson = jsonDecode(getselfKeyResponse);

      expect(getselfKeyResponseJson['value'], encryptedAESKey);
      expect(getselfKeyResponseJson['keyType'], 'aes256');
      expect(getselfKeyResponseJson['enrollApprovalId'], secondEnrollId);
      expect(getselfKeyResponseJson['encryptionKeyName'],
          'encryption_$secondEnrollId');

      //8. test keys:get:private
      await socket_writer(socketConnection2!, 'keys:get:private');
      var getPrivateKeysResponse = await read();
      getPrivateKeysResponse = getPrivateKeysResponse.replaceFirst('data:', '');
      var getPrivateKeysResponseJson = jsonDecode(getPrivateKeysResponse);
      expect(getPrivateKeysResponseJson.length, greaterThanOrEqualTo(1));

      // 9. test keys:get:private key value
      var privateKeyGetCommand =
          'keys:get:keyName:private:wavi.pixel.myPrivateKey.__private_keys.__global$firstAtsign';
      await socket_writer(socketConnection2!, privateKeyGetCommand);
      var getprivateKeyResponse = await read();
      getprivateKeyResponse = getprivateKeyResponse.replaceFirst('data:', '');
      var getprivateKeyResponseJson = jsonDecode(getprivateKeyResponse);

      expect(getprivateKeyResponseJson['value'], encryptedPrivateKey);
      expect(getprivateKeyResponseJson['keyType'], 'aes');
      expect(getprivateKeyResponseJson['enrollApprovalId'], secondEnrollId);
      expect(getprivateKeyResponseJson['encryptionKeyName'], 'myAESkey');

      // delete the public key and check if it is deleted
      await socket_writer(socketConnection2!,
          'keys:delete:keyName:public:encryption_$secondEnrollId.__public_keys.__global$firstAtsign');
      var deletePublicKeyResponse = await read();
      expect(deletePublicKeyResponse, 'data:-1\n');

      // delete the private key and check if it is deleted
      await socket_writer(socketConnection2!,
          'keys:delete:keyName:private:wavi.pixel.myPrivateKey.__private_keys.__global$firstAtsign');
      var deletePrivateKeyResponse = await read();
      expect(deletePrivateKeyResponse, 'data:-1\n');

      // delete the self key and check if it is deleted
      await socket_writer(socketConnection2!,
          'keys:delete:keyName:wavi.pixel.myaesKey.__self_keys.__global$firstAtsign');
      var deleteSelfKeyResponse = await read();
      expect(deleteSelfKeyResponse, 'data:-1\n');
    });
  });
}
