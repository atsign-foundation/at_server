// ignore_for_file: prefer_typing_uninitialized_variables

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_demo_data/at_demo_data.dart' as at_demos;
import 'package:at_functional_test/conf/config_util.dart';
import 'package:crypton/crypton.dart';
import 'package:encrypt/encrypt.dart';
import 'package:test/test.dart';

// import 'at_demo_data.dart' as demo;
import 'encryption_util.dart';
import 'functional_test_commons.dart';
import 'pkam_utils.dart';

Socket? socketConnection1;
Socket? socketConnection2;

var aliceDefaultEncKey;
var aliceSelfEncKey;
var aliceApkamSymmetricKey;
var encryptedDefaultEncPrivateKey;
var encryptedSelfEncKey;

var firstAtsignServer =
    ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
var firstAtsignPort =
    ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];
var firstAtsign =
    ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];

Future<void> _connect() async {
  // socket connection for first atsign
  socketConnection1 =
      await secure_socket_connection(firstAtsignServer, firstAtsignPort);
  socket_listener(socketConnection1!);
}

Future<void> _encryptKeys() async {
  aliceDefaultEncKey = at_demos.encryptionPrivateKeyMap[firstAtsign];
  aliceSelfEncKey = at_demos.aesKeyMap[firstAtsign];
  aliceApkamSymmetricKey = at_demos.apkamSymmetricKeyMap[firstAtsign];
  encryptedDefaultEncPrivateKey =
      EncryptionUtil.encryptValue(aliceDefaultEncKey!, aliceApkamSymmetricKey!);
  encryptedSelfEncKey =
      EncryptionUtil.encryptValue(aliceSelfEncKey!, aliceApkamSymmetricKey);
}

void main() {
  //Establish the client socket connection
  setUp(() async {
    await _connect();
    await _encryptKeys();
  });

  group('A group of tests to verify keys verb test', () {
    test(
        'check keys verb put operation - enroll request on authenticated connection',
        () async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      fromResponse = fromResponse.replaceAll('data:', '');
      var cramResponse = getDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'cram:$cramResponse');
      var cramResult = await read();
      expect(cramResult, 'data:success\n');

      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptedPrivateKey":"$encryptedDefaultEncPrivateKey","encryptedDefaultSelfEncryptionKey":"$encryptedSelfEncKey","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';

      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      var enrollmentId = enrollJsonMap['enrollmentId'];
      expect(enrollmentId, isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');
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
          .encrypt(rsaPrivateKey!, iv: IV(Uint8List(16)))
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
      expect(getPublicKeyResponseJson['enrollmentId'], enrollmentId);

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
      expect(getselfKeyResponseJson['enrollmentId'], enrollmentId);
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
      expect(getprivateKeyResponseJson['enrollmentId'], enrollmentId);
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
      await prepare(socketConnection1!, firstAtsign, isCRAM: true);

      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptedPrivateKey":"$encryptedDefaultEncPrivateKey","encryptedDefaultSelfEncryptionKey":"$encryptedSelfEncKey","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');

      var otpRequest = 'otp:get\n';
      await socket_writer(socketConnection1!, otpRequest);
      var otpResponse = await read();
      otpResponse = otpResponse.replaceFirst('data:', '');
      otpResponse = otpResponse.trim();

      // connect to the second client
      socketConnection2 =
          await secure_socket_connection(firstAtsignServer, firstAtsignPort);
      socket_listener(socketConnection2!);
      //send second enroll request with otp
      var secondEnrollRequest =
          'enroll:request:{"appName":"buzz","deviceName":"pixel","namespaces":{"buzz":"rw"},"otp":"$otpResponse","encryptedDefaultEncryptedPrivateKey":"$encryptedDefaultEncPrivateKey","encryptedDefaultSelfEncryptionKey":"$encryptedSelfEncKey","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(socketConnection2!, secondEnrollRequest);

      var secondEnrollResponse = await read();
      secondEnrollResponse = secondEnrollResponse.replaceFirst('data:', '');
      var enrollJson = jsonDecode(secondEnrollResponse);
      expect(enrollJson['enrollmentId'], isNotEmpty);
      expect(enrollJson['status'], 'pending');
      var secondEnrollId = enrollJson['enrollmentId'];

      // connect to the first client to approve the enroll request
      await socket_writer(socketConnection1!,
          'enroll:approve:{"enrollmentId":"$secondEnrollId"}\n');
      var approveResponse = await read();
      approveResponse = approveResponse.replaceFirst('data:', '');
      var approveJson = jsonDecode(approveResponse);
      expect(approveJson['status'], 'approved');
      expect(approveJson['enrollmentId'], secondEnrollId);

      // connect to the second client to do an apkam
      await prepare(socketConnection2!, firstAtsign, isAPKAM: true, enrollmentId: secondEnrollId);
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
          .encrypt(rsaPrivateKey!, iv: IV(Uint8List(16)))
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
      expect(getPublicKeyResponseJson['enrollmentId'], secondEnrollId);

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
      expect(getselfKeyResponseJson['enrollmentId'], secondEnrollId);
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
      expect(getprivateKeyResponseJson['enrollmentId'], secondEnrollId);
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

    test('check keys verb get operation - without authentication', () async {
      await socket_writer(socketConnection1!, 'keys:get:self');
      var getResponse = await read();
      expect(getResponse,
          'error:AT0401-Exception: Command cannot be executed without auth\n');
    });

    test('check keys verb put operation - without authentication', () async {
      var putCommand =
          'keys:put:public:namespace:__global:keyType:rsa2048:keyName:encryption_12344444 testPublicKeyValue';
      await socket_writer(socketConnection1!, putCommand);
      var putResponse = await read();
      expect(putResponse,
          'error:AT0401-Exception: Command cannot be executed without auth\n');
    });
  });

  tearDown(() async{
    await socketConnection1?.close();
    await socketConnection2?.close();
  });
}
