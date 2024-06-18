import 'dart:convert';
import 'dart:typed_data';

import 'package:at_demo_data/at_demo_data.dart' as at_demos;
import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/encryption_util.dart';
import 'package:crypton/crypton.dart';
import 'package:encrypt/encrypt.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() {
  OutboundConnectionFactory firstAtSignConnection = OutboundConnectionFactory();
  OutboundConnectionFactory secondAtSignConnection =
      OutboundConnectionFactory();
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
    await secondAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
  });

  group('A group of tests to verify keys verb test', () {
    test(
        'check keys verb put operation - enroll request on authenticated connection',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptedPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap['encryptedSelfEncKey']}","apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}';

      String enrollResponse =
          await firstAtSignConnection.sendRequestToServer(enrollRequest);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      var enrollmentId = enrollJsonMap['enrollmentId'];
      expect(enrollmentId, isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');
      var encryptionPublicKey = encryptionPublicKeyMap[firstAtSign];

      //1. put encryption public key
      var keysPutPublicEncryptionKeyCommand =
          'keys:put:public:namespace:__global:keyType:rsa2048:keyName:encryption_$enrollmentId $encryptionPublicKey';
      String publicKeyPutResponse = await firstAtSignConnection
          .sendRequestToServer(keysPutPublicEncryptionKeyCommand);
      expect(publicKeyPutResponse, 'data:-1');

      //2. put self symmetric key which is encrypted with encryption public key
      var aesKey = AES(Key.fromSecureRandom(32)).key.base64;
      var rsaPublicKey = RSAPublicKey.fromString(encryptionPublicKey!);
      var encryptedAESKey = rsaPublicKey.encrypt(aesKey);
      var selfSymmetricKeyCommand =
          'keys:put:self:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes256:encryptionKeyName:encryption_$enrollmentId:keyName:myAESkey $encryptedAESKey';
      String selfKeyPutResponse = await firstAtSignConnection
          .sendRequestToServer(selfSymmetricKeyCommand);
      expect(selfKeyPutResponse, 'data:-1');

      //3. put encryption private key which is encrypted with self symmetric key
      var rsaPrivateKey = encryptionPrivateKeyMap[firstAtSign];
      var encryptedPrivateKey = Encrypter(AES(Key.fromBase64(aesKey)))
          .encrypt(rsaPrivateKey!, iv: IV(Uint8List(16)))
          .base64;
      var privateKeyCommand =
          'keys:put:private:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes:encryptionKeyName:myAESkey:keyName:myPrivateKey $encryptedPrivateKey';
      String privateKeyPutResponse =
          await firstAtSignConnection.sendRequestToServer(privateKeyCommand);
      expect(privateKeyPutResponse, 'data:-1');

      //4. test keys:get:public
      var getPublicKeysResponse =
          await firstAtSignConnection.sendRequestToServer('keys:get:public');
      getPublicKeysResponse = getPublicKeysResponse.replaceFirst('data:', '');
      var getPublicKeysResponseJson = jsonDecode(getPublicKeysResponse);
      expect(getPublicKeysResponseJson.length, greaterThanOrEqualTo(1));

      // 5. test keys:get:publicKey value
      var publicKeyGetCommand =
          'keys:get:keyName:public:encryption_$enrollmentId.__public_keys.__global$firstAtSign';
      String getPublicKeyResponse =
          await firstAtSignConnection.sendRequestToServer(publicKeyGetCommand);
      getPublicKeyResponse = getPublicKeyResponse.replaceFirst('data:', '');
      var getPublicKeyResponseJson = jsonDecode(getPublicKeyResponse);

      expect(getPublicKeyResponseJson['value'], encryptionPublicKey);
      expect(getPublicKeyResponseJson['keyType'], 'rsa2048');
      expect(getPublicKeyResponseJson['enrollmentId'], enrollmentId);

      //6. test keys:get:self
      var getSelfKeysResponse =
          await firstAtSignConnection.sendRequestToServer('keys:get:self');
      getSelfKeysResponse = getSelfKeysResponse.replaceFirst('data:', '');
      var getSelfKeysResponseJson = jsonDecode(getSelfKeysResponse);
      expect(getSelfKeysResponseJson.length, greaterThanOrEqualTo(1));

      // 7. test keys:get:selfKey value
      var selfKeyGetCommand =
          'keys:get:keyName:wavi.pixel.myaesKey.__self_keys.__global$firstAtSign';
      String getselfKeyResponse =
          await firstAtSignConnection.sendRequestToServer(selfKeyGetCommand);
      getselfKeyResponse = getselfKeyResponse.replaceFirst('data:', '');
      var getselfKeyResponseJson = jsonDecode(getselfKeyResponse);

      expect(getselfKeyResponseJson['value'], encryptedAESKey);
      expect(getselfKeyResponseJson['keyType'], 'aes256');
      expect(getselfKeyResponseJson['enrollmentId'], enrollmentId);
      expect(getselfKeyResponseJson['encryptionKeyName'],
          'encryption_$enrollmentId');

      //8. test keys:get:private
      String getPrivateKeysResponse =
          await firstAtSignConnection.sendRequestToServer('keys:get:private');
      getPrivateKeysResponse = getPrivateKeysResponse.replaceFirst('data:', '');
      var getPrivateKeysResponseJson = jsonDecode(getPrivateKeysResponse);
      expect(getPrivateKeysResponseJson.length, greaterThanOrEqualTo(1));

      // 9. test keys:get:private:key
      String privateKeyGetCommand =
          'keys:get:keyName:private:wavi.pixel.myPrivateKey.__private_keys.__global$firstAtSign';
      String getprivateKeyResponse =
          await firstAtSignConnection.sendRequestToServer(privateKeyGetCommand);
      getprivateKeyResponse = getprivateKeyResponse.replaceFirst('data:', '');
      var getprivateKeyResponseJson = jsonDecode(getprivateKeyResponse);

      expect(getprivateKeyResponseJson['value'], encryptedPrivateKey);
      expect(getprivateKeyResponseJson['keyType'], 'aes');
      expect(getprivateKeyResponseJson['enrollmentId'], enrollmentId);
      expect(getprivateKeyResponseJson['encryptionKeyName'], 'myAESkey');

      // delete the public key and check if it is deleted
      String deletePublicKeyResponse =
          await firstAtSignConnection.sendRequestToServer(
              'keys:delete:keyName:public:encryption_$enrollmentId.__public_keys.__global$firstAtSign');
      expect(deletePublicKeyResponse, 'data:-1');

      // delete the private key and check if it is deleted
      String deletePrivateKeyResponse =
          await firstAtSignConnection.sendRequestToServer(
              'keys:delete:keyName:private:wavi.pixel.myPrivateKey.__private_keys.__global$firstAtSign');
      expect(deletePrivateKeyResponse, 'data:-1');

      // delete the self key and check if it is deleted
      var deleteSelfKeyResponse = await firstAtSignConnection.sendRequestToServer(
          'keys:delete:keyName:wavi.pixel.myaesKey.__self_keys.__global$firstAtSign');
      expect(deleteSelfKeyResponse, 'data:-1');
    });

    test(
        'check keys verb put operation - enroll request on a second authenticated connection using otp',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);

      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptedPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap['encryptedSelfEncKey']}","apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}';
      String enrollResponse =
          await firstAtSignConnection.sendRequestToServer(enrollRequest);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');

      var otpRequest = 'otp:get';
      String otpResponse =
          await firstAtSignConnection.sendRequestToServer(otpRequest);
      otpResponse = otpResponse.replaceFirst('data:', '');
      otpResponse = otpResponse.trim();

      //send second enroll request with otp
      var secondEnrollRequest =
          'enroll:request:{"appName":"buzz","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"buzz":"rw"},"otp":"$otpResponse","encryptedDefaultEncryptedPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap['encryptedSelfEncKey']}","apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!},"encryptedAPKAMSymmetricKey": "${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}';
      String secondEnrollResponse =
          await secondAtSignConnection.sendRequestToServer(secondEnrollRequest);
      secondEnrollResponse = secondEnrollResponse.replaceFirst('data:', '');
      var enrollJson = jsonDecode(secondEnrollResponse);
      expect(enrollJson['enrollmentId'], isNotEmpty);
      expect(enrollJson['status'], 'pending');
      var secondEnrollId = enrollJson['enrollmentId'];

      // connect to the first client to approve the enroll request
      var approveResponse = await firstAtSignConnection.sendRequestToServer(
          'enroll:approve:{"enrollmentId":"$secondEnrollId"}');
      approveResponse = approveResponse.replaceFirst('data:', '');
      var approveJson = jsonDecode(approveResponse);
      expect(approveJson['status'], 'approved');
      expect(approveJson['enrollmentId'], secondEnrollId);

      // connect to the second client to do an apkam
      await secondAtSignConnection.authenticateConnection(
          authType: AuthType.pkam, enrollmentId: secondEnrollId);
      var encryptionPublicKey = encryptionPublicKeyMap[firstAtSign];

      //1. put encryption public key
      var keysPutPublicEncryptionKeyCommand =
          'keys:put:public:namespace:__global:keyType:rsa2048:keyName:encryption_$secondEnrollId $encryptionPublicKey';
      String publicKeyPutResponse = await secondAtSignConnection
          .sendRequestToServer(keysPutPublicEncryptionKeyCommand);
      expect(publicKeyPutResponse, 'data:-1');

      //2. put self symmetric key which is encrypted with encryption public key
      var aesKey = AES(Key.fromSecureRandom(32)).key.base64;

      var rsaPublicKey = RSAPublicKey.fromString(encryptionPublicKey!);
      var encryptedAESKey = rsaPublicKey.encrypt(aesKey);
      var selfSymmetricKeyCommand =
          'keys:put:self:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes256:encryptionKeyName:encryption_$secondEnrollId:keyName:myAESkey $encryptedAESKey';
      var selfKeyPutResponse = await secondAtSignConnection
          .sendRequestToServer(selfSymmetricKeyCommand);
      expect(selfKeyPutResponse, 'data:-1');

      //3. put encryption private key which is encrypted with self symmetric key
      var rsaPrivateKey = encryptionPrivateKeyMap[firstAtSign];
      var encryptedPrivateKey = Encrypter(AES(Key.fromBase64(aesKey)))
          .encrypt(rsaPrivateKey!, iv: IV(Uint8List(16)))
          .base64;
      var privateKeyCommand =
          'keys:put:private:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes:encryptionKeyName:myAESkey:keyName:myPrivateKey $encryptedPrivateKey';
      String privateKeyPutResponse =
          await secondAtSignConnection.sendRequestToServer(privateKeyCommand);
      expect(privateKeyPutResponse, 'data:-1');

      //4. test keys:get:public
      String getPublicKeysResponse =
          await secondAtSignConnection.sendRequestToServer('keys:get:public');
      getPublicKeysResponse = getPublicKeysResponse.replaceFirst('data:', '');
      var getPublicKeysResponseJson = jsonDecode(getPublicKeysResponse);
      expect(getPublicKeysResponseJson.length, greaterThanOrEqualTo(1));

      // 5. test keys:get:publicKey value
      var publicKeyGetCommand =
          'keys:get:keyName:public:encryption_$secondEnrollId.__public_keys.__global$firstAtSign';
      String getPublicKeyResponse =
          await secondAtSignConnection.sendRequestToServer(publicKeyGetCommand);
      getPublicKeyResponse = getPublicKeyResponse.replaceFirst('data:', '');
      var getPublicKeyResponseJson = jsonDecode(getPublicKeyResponse);

      expect(getPublicKeyResponseJson['value'], encryptionPublicKey);
      expect(getPublicKeyResponseJson['keyType'], 'rsa2048');
      expect(getPublicKeyResponseJson['enrollmentId'], secondEnrollId);

      //6. test keys:get:self
      String getSelfKeysResponse =
          await secondAtSignConnection.sendRequestToServer('keys:get:self');
      getSelfKeysResponse = getSelfKeysResponse.replaceFirst('data:', '');
      var getSelfKeysResponseJson = jsonDecode(getSelfKeysResponse);
      expect(getSelfKeysResponseJson.length, greaterThanOrEqualTo(1));

      // 7. test keys:get:selfKey value
      var selfKeyGetCommand =
          'keys:get:keyName:wavi.pixel.myaesKey.__self_keys.__global$firstAtSign';
      String getselfKeyResponse =
          await secondAtSignConnection.sendRequestToServer(selfKeyGetCommand);
      getselfKeyResponse = getselfKeyResponse.replaceFirst('data:', '');
      var getselfKeyResponseJson = jsonDecode(getselfKeyResponse);

      expect(getselfKeyResponseJson['value'], encryptedAESKey);
      expect(getselfKeyResponseJson['keyType'], 'aes256');
      expect(getselfKeyResponseJson['enrollmentId'], secondEnrollId);
      expect(getselfKeyResponseJson['encryptionKeyName'],
          'encryption_$secondEnrollId');

      //8. test keys:get:private
      var getPrivateKeysResponse =
          await secondAtSignConnection.sendRequestToServer('keys:get:private');
      getPrivateKeysResponse = getPrivateKeysResponse.replaceFirst('data:', '');
      var getPrivateKeysResponseJson = jsonDecode(getPrivateKeysResponse);
      expect(getPrivateKeysResponseJson.length, greaterThanOrEqualTo(1));

      // 9. test keys:get:private key value
      var privateKeyGetCommand =
          'keys:get:keyName:private:wavi.pixel.myPrivateKey.__private_keys.__global$firstAtSign';
      String getprivateKeyResponse = await secondAtSignConnection
          .sendRequestToServer(privateKeyGetCommand);
      getprivateKeyResponse = getprivateKeyResponse.replaceFirst('data:', '');
      var getprivateKeyResponseJson = jsonDecode(getprivateKeyResponse);

      expect(getprivateKeyResponseJson['value'], encryptedPrivateKey);
      expect(getprivateKeyResponseJson['keyType'], 'aes');
      expect(getprivateKeyResponseJson['enrollmentId'], secondEnrollId);
      expect(getprivateKeyResponseJson['encryptionKeyName'], 'myAESkey');

      // delete the public key and check if it is deleted
      var deletePublicKeyResponse =
          await secondAtSignConnection.sendRequestToServer(
              'keys:delete:keyName:public:encryption_$secondEnrollId.__public_keys.__global$firstAtSign');
      expect(deletePublicKeyResponse, 'data:-1');

      // delete the private key and check if it is deleted
      var deletePrivateKeyResponse =
          await secondAtSignConnection.sendRequestToServer(
              'keys:delete:keyName:private:wavi.pixel.myPrivateKey.__private_keys.__global$firstAtSign');
      expect(deletePrivateKeyResponse, 'data:-1');

      // delete the self key and check if it is deleted
      var deleteSelfKeyResponse = await secondAtSignConnection.sendRequestToServer(
          'keys:delete:keyName:wavi.pixel.myaesKey.__self_keys.__global$firstAtSign');
      expect(deleteSelfKeyResponse, 'data:-1');
    });

    test('check keys verb get operation - without authentication', () async {
      var getResponse =
          await firstAtSignConnection.sendRequestToServer('keys:get:self');
      expect(getResponse,
          'error:AT0401-Exception: Command cannot be executed without auth');
    });

    test('check keys verb put operation - without authentication', () async {
      var putCommand =
          'keys:put:public:namespace:__global:keyType:rsa2048:keyName:encryption_12344444 testPublicKeyValue';
      var putResponse =
          await firstAtSignConnection.sendRequestToServer(putCommand);
      expect(putResponse,
          'error:AT0401-Exception: Command cannot be executed without auth');
    });
  });
}
