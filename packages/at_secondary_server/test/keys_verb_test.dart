import 'dart:convert';
import 'dart:typed_data';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/keys_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:crypton/crypton.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:encrypt/encrypt.dart';

import 'test_utils.dart';

void main() {
  AtSignLogger.root_level = 'WARNING';
  group('keys verb tests', () {
    late KeysVerbHandler keysVerbHandler;
    late LocalLookupVerbHandler localLookupVerbHandler;

    setUpAll(() async {
      await verbTestsSetUpAll();
    });

    setUp(() async {
      await verbTestsSetUp();
      keysVerbHandler = KeysVerbHandler(secondaryKeyStore);
      localLookupVerbHandler = LocalLookupVerbHandler(secondaryKeyStore);
    });

    tearDown(() async {
      await verbTestsTearDown();
    });

    test('keys verb  - put public key and check keys:get:public, llookup',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      var enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      var keysCommand =
          'keys:put:public:namespace:__global:keyType:rsa2048:keyName:encryption_$enrollId testPublicKeyValue';

      await keysVerbHandler.process(keysCommand, inboundConnection);

      expect(inboundConnection.lastWrittenData, "data:-1\n$alice@");
      expect(secondaryKeyStore.isKeyExists(keyName), true);
      expect(
          secondaryKeyStore.isKeyExists(
              'public:encryption_$enrollId.__public_keys.__global@alice'),
          true);
      var keysGetCommand = 'keys:get:public';
      await keysVerbHandler.process(keysGetCommand, inboundConnection);
      expect(inboundConnection.lastWrittenData,
          "data:[\"public:encryption_$enrollId.__public_keys.__global@alice\"]\n$alice@");
      // llookup of keys is not allowed
      var llookUpCommand =
          'llookup:public:encryption_$enrollId.__public_keys.__global@alice';
      await localLookupVerbHandler.process(llookUpCommand, inboundConnection);
      var llookupResultMap = decodeResponse(inboundConnection.lastWrittenData!);
      expect(llookupResultMap['value'], 'testPublicKeyValue');
      expect(llookupResultMap['keyType'], 'rsa2048');
      expect(llookupResultMap['enrollmentId'], enrollId);
    });

    test(
        'keys verb  - put public key and check keys:get:public for an emoji atsign',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice🛠';
      var enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'publicKeyTest',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollId.new.enrollments.__manage@alice🛠';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      var keysCommand =
          'keys:put:public:namespace:__global:keyType:rsa2048:keyName:encryption_$enrollId publicKeyTest';

      await keysVerbHandler.process(keysCommand, inboundConnection);

      expect(inboundConnection.lastWrittenData, "data:-1\n$aliceEmoji@");
      expect(secondaryKeyStore.isKeyExists(keyName), true);
      expect(
          secondaryKeyStore.isKeyExists(
              'public:encryption_$enrollId.__public_keys.__global@alice🛠'),
          true);
      var keysGetCommand = 'keys:get:public';
      await keysVerbHandler.process(keysGetCommand, inboundConnection);
      expect(inboundConnection.lastWrittenData,
          "data:[\"public:encryption_$enrollId.__public_keys.__global@alice🛠\"]\n$aliceEmoji@");
      // llookup of keys is not allowed
      var llookUpCommand =
          'llookup:public:encryption_$enrollId.__public_keys.__global@alice🛠';
      await localLookupVerbHandler.process(llookUpCommand, inboundConnection);
      var llookupResultMap = decodeResponse(inboundConnection.lastWrittenData!);
      expect(llookupResultMap['value'], 'publicKeyTest');
      expect(llookupResultMap['keyType'], 'rsa2048');
      expect(llookupResultMap['enrollmentId'], enrollId);
    }, timeout: Timeout(Duration(minutes: 5)));

    test('keys verb  - put self key and check keys:get, llookup', () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      var enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      var keysCommand =
          'keys:put:self:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes256:encryptionKeyName:encryption_$enrollId:keyName:mykey selfKeyValue';

      await keysVerbHandler.process(keysCommand, inboundConnection);

      expect(inboundConnection.lastWrittenData, "data:-1\n$alice@");
      expect(secondaryKeyStore.isKeyExists(keyName), true);
      expect(
          secondaryKeyStore
              .isKeyExists('wavi.pixel.mykey.__self_keys.__global@alice'),
          true);

      var keysGetCommand = 'keys:get:self';
      await keysVerbHandler.process(keysGetCommand, inboundConnection);
      expect(inboundConnection.lastWrittenData,
          "data:[\"wavi.pixel.mykey.__self_keys.__global@alice\"]\n$alice@");

      var llookUpCommand =
          'llookup:wavi.pixel.mykey.__self_keys.__global@alice';
      expect(
          () async => await localLookupVerbHandler.process(
              llookUpCommand, inboundConnection),
          throwsA(predicate((dynamic e) => e is UnAuthorizedException)));
    });

    test('keys verb  - put self key and check keys:get for an emoji atsign',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice🛠';
      var enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollId.new.enrollments.__manage@alice🛠';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      var keysCommand =
          'keys:put:self:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes256:encryptionKeyName:encryption_$enrollId:keyName:mykey selfKeyValue';

      await keysVerbHandler.process(keysCommand, inboundConnection);

      expect(inboundConnection.lastWrittenData, "data:-1\n$aliceEmoji@");
      expect(secondaryKeyStore.isKeyExists(keyName), true);
      expect(
          secondaryKeyStore
              .isKeyExists('wavi.pixel.mykey.__self_keys.__global@alice🛠'),
          true);

      var keysGetCommand = 'keys:get:self';
      await keysVerbHandler.process(keysGetCommand, inboundConnection);
      expect(inboundConnection.lastWrittenData,
          "data:[\"wavi.pixel.mykey.__self_keys.__global@alice🛠\"]\n$aliceEmoji@");

      var llookUpCommand =
          'llookup:wavi.pixel.mykey.__self_keys.__global@alice🛠';
      expect(
          () async => await localLookupVerbHandler.process(
              llookUpCommand, inboundConnection),
          throwsA(predicate((dynamic e) => e is UnAuthorizedException)));
    });

    test('keys verb  - put private key and check keys:get', () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      var enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      var keysCommand =
          'keys:put:private:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes:encryptionKeyName:mykey:keyName:secretKey abcd1234';

      await keysVerbHandler.process(keysCommand, inboundConnection);

      expect(inboundConnection.lastWrittenData, "data:-1\n$alice@");
      expect(secondaryKeyStore.isKeyExists(keyName), true);
      expect(
          secondaryKeyStore.isKeyExists(
              'private:wavi.pixel.secretKey.__private_keys.__global@alice'),
          true);
      var keysGetCommand = 'keys:get:private';
      await keysVerbHandler.process(keysGetCommand, inboundConnection);
      expect(inboundConnection.lastWrittenData,
          "data:[\"private:wavi.pixel.secretkey.__private_keys.__global@alice\"]\n$alice@");

      var llookUpCommand =
          'llookup:private:wavi.pixel.secretkey.__private_keys.__global@alice';
      expect(
          () async => await localLookupVerbHandler.process(
              llookUpCommand, inboundConnection),
          throwsA(predicate((dynamic e) => e is UnAuthorizedException)));
    });

    test('keys verb  - put private key and check keys:get for an emoji atsign',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice🛠';
      var enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollId.new.enrollments.__manage@alice🛠';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      var keysCommand =
          'keys:put:private:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes:encryptionKeyName:mykey:keyName:secretKey abcd1234';

      await keysVerbHandler.process(keysCommand, inboundConnection);

      expect(inboundConnection.lastWrittenData, "data:-1\n$aliceEmoji@");
      expect(secondaryKeyStore.isKeyExists(keyName), true);
      expect(
          secondaryKeyStore.isKeyExists(
              'private:wavi.pixel.secretKey.__private_keys.__global@alice🛠'),
          true);
      var keysGetCommand = 'keys:get:private';
      await keysVerbHandler.process(keysGetCommand, inboundConnection);
      expect(inboundConnection.lastWrittenData,
          "data:[\"private:wavi.pixel.secretkey.__private_keys.__global@alice🛠\"]\n$aliceEmoji@");

      var llookUpCommand =
          'llookup:private:wavi.pixel.secretkey.__private_keys.__global@alice🛠';
      expect(
          () async => await localLookupVerbHandler.process(
              llookUpCommand, inboundConnection),
          throwsA(predicate((dynamic e) => e is UnAuthorizedException)));
    });

    test('keys verb  - put public key and check getKeyName, delete key',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      var enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var enrollkeyName = '$enrollId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          enrollkeyName, AtData()..data = jsonEncode(enrollJson));

      var keysCommand =
          'keys:put:public:namespace:__global:keyType:rsa2048:keyName:encryption_$enrollId testPublicKeyValue';

      await keysVerbHandler.process(keysCommand, inboundConnection);

      expect(inboundConnection.lastWrittenData, "data:-1\n$alice@");
      expect(secondaryKeyStore.isKeyExists(enrollkeyName), true);
      expect(
          secondaryKeyStore.isKeyExists(
              'public:encryption_$enrollId.__public_keys.__global@alice'),
          true);
      var publicKeyName =
          'public:encryption_$enrollId.__public_keys.__global@alice';
      var keysGetCommand = 'keys:get:keyName:$publicKeyName';
      await keysVerbHandler.process(keysGetCommand, inboundConnection);
      var getKeysResponse = decodeResponse(inboundConnection.lastWrittenData!);
      expect(getKeysResponse['value'], 'testPublicKeyValue');
      expect(getKeysResponse['enrollmentId'], enrollId);
      expect(getKeysResponse['keyType'], 'rsa2048');
      var deleteKeyCommand = 'keys:delete:keyName:$publicKeyName';
      await keysVerbHandler.process(deleteKeyCommand, inboundConnection);
      expect(inboundConnection.lastWrittenData, "data:-1\n$alice@");
      expect(secondaryKeyStore.isKeyExists(publicKeyName), false);
    });

    test(
        'keys verb with emoji atsign- put public key and check getKeyName, delete key',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice🛠';
      var enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var enrollkeyName = '$enrollId.new.enrollments.__manage@alice🛠';
      await secondaryKeyStore.put(
          enrollkeyName, AtData()..data = jsonEncode(enrollJson));

      var keysCommand =
          'keys:put:public:namespace:__global:keyType:rsa2048:keyName:encryption_$enrollId testPublicKeyValue';

      await keysVerbHandler.process(keysCommand, inboundConnection);

      expect(inboundConnection.lastWrittenData, "data:-1\n$aliceEmoji@");
      expect(secondaryKeyStore.isKeyExists(enrollkeyName), true);
      expect(
          secondaryKeyStore.isKeyExists(
              'public:encryption_$enrollId.__public_keys.__global@alice🛠'),
          true);
      var publicKeyName =
          'public:encryption_$enrollId.__public_keys.__global@alice🛠';
      var keysGetCommand = 'keys:get:keyName:$publicKeyName';
      await keysVerbHandler.process(keysGetCommand, inboundConnection);
      var getKeysResponse = decodeResponse(inboundConnection.lastWrittenData!);
      expect(getKeysResponse['value'], 'testPublicKeyValue');
      expect(getKeysResponse['enrollmentId'], enrollId);
      expect(getKeysResponse['keyType'], 'rsa2048');
      var deleteKeyCommand = 'keys:delete:keyName:$publicKeyName';
      await keysVerbHandler.process(deleteKeyCommand, inboundConnection);
      expect(inboundConnection.lastWrittenData, "data:-1\n$aliceEmoji@");
      expect(secondaryKeyStore.isKeyExists(publicKeyName), false);
    });

    test('keys verb  - put self key and check getKeyName,delete key ',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      var enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var enrollKeyName = '$enrollId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          enrollKeyName, AtData()..data = jsonEncode(enrollJson));

      var keysCommand =
          'keys:put:self:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes256:encryptionKeyName:encryption_$enrollId:keyName:mykey selfKeyValue';

      await keysVerbHandler.process(keysCommand, inboundConnection);

      expect(inboundConnection.lastWrittenData, "data:-1\n$alice@");
      expect(secondaryKeyStore.isKeyExists(enrollKeyName), true);
      expect(
          secondaryKeyStore
              .isKeyExists('wavi.pixel.mykey.__self_keys.__global@alice'),
          true);
      var selfKeyName = 'wavi.pixel.mykey.__self_keys.__global@alice';
      var keysGetCommand = 'keys:get:keyName:$selfKeyName';
      await keysVerbHandler.process(keysGetCommand, inboundConnection);
      var getKeysResponse = decodeResponse(inboundConnection.lastWrittenData!);
      expect(getKeysResponse['value'], 'selfKeyValue');
      expect(getKeysResponse['enrollmentId'], enrollId);
      expect(getKeysResponse['keyType'], 'aes256');
      var deleteKeyCommand = 'keys:delete:keyName:$selfKeyName';
      await keysVerbHandler.process(deleteKeyCommand, inboundConnection);
      expect(inboundConnection.lastWrittenData, "data:-1\n$alice@");
      expect(secondaryKeyStore.isKeyExists(selfKeyName), false);
    });

    test(
        'keys verb with Emoji atsign - put self key and check getKeyName,delete key ',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice🛠';
      var enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var enrollKeyName = '$enrollId.new.enrollments.__manage@alice🛠';
      await secondaryKeyStore.put(
          enrollKeyName, AtData()..data = jsonEncode(enrollJson));

      var keysCommand =
          'keys:put:self:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes256:encryptionKeyName:encryption_$enrollId:keyName:mykey selfKeyValue';

      await keysVerbHandler.process(keysCommand, inboundConnection);

      expect(inboundConnection.lastWrittenData, "data:-1\n$aliceEmoji@");
      expect(secondaryKeyStore.isKeyExists(enrollKeyName), true);
      expect(
          secondaryKeyStore
              .isKeyExists('wavi.pixel.mykey.__self_keys.__global@alice🛠'),
          true);
      var selfKeyName = 'wavi.pixel.mykey.__self_keys.__global@alice🛠';
      var keysGetCommand = 'keys:get:keyName:$selfKeyName';
      await keysVerbHandler.process(keysGetCommand, inboundConnection);
      var getKeysResponse = decodeResponse(inboundConnection.lastWrittenData!);
      expect(getKeysResponse['value'], 'selfKeyValue');
      expect(getKeysResponse['enrollmentId'], enrollId);
      expect(getKeysResponse['keyType'], 'aes256');
      var deleteKeyCommand = 'keys:delete:keyName:$selfKeyName';
      await keysVerbHandler.process(deleteKeyCommand, inboundConnection);
      expect(inboundConnection.lastWrittenData, "data:-1\n$aliceEmoji@");
      expect(secondaryKeyStore.isKeyExists(selfKeyName), false);
    });

    test('keys verb  - put private key and check getKeyName, delete', () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      var enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      var keysCommand =
          'keys:put:private:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes256:encryptionKeyName:mykey:keyName:secretKey abcd1234';

      await keysVerbHandler.process(keysCommand, inboundConnection);

      expect(inboundConnection.lastWrittenData, "data:-1\n$alice@");
      expect(secondaryKeyStore.isKeyExists(keyName), true);
      expect(
          secondaryKeyStore.isKeyExists(
              'private:wavi.pixel.secretKey.__private_keys.__global@alice'),
          true);
      var privateKeyName =
          'private:wavi.pixel.secretKey.__private_keys.__global@alice';
      var keysGetCommand = 'keys:get:keyName:$privateKeyName';
      await keysVerbHandler.process(keysGetCommand, inboundConnection);
      var getKeysResponse = decodeResponse(inboundConnection.lastWrittenData!);
      expect(getKeysResponse['value'], 'abcd1234');
      expect(getKeysResponse['enrollmentId'], enrollId);
      expect(getKeysResponse['keyType'], 'aes256');
      expect(getKeysResponse['encryptionKeyName'], 'mykey');
      var deleteKeyCommand = 'keys:delete:keyName:$privateKeyName';
      await keysVerbHandler.process(deleteKeyCommand, inboundConnection);
      expect(inboundConnection.lastWrittenData, "data:-1\n$alice@");
      expect(secondaryKeyStore.isKeyExists(privateKeyName), false);
    });

    test(
        'keys verb with an emoji Atsign - put private key and check getKeyName, delete',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice🛠';
      var enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollId.new.enrollments.__manage@alice🛠';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      var keysCommand =
          'keys:put:private:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes256:encryptionKeyName:mykey:keyName:secretKey abcd1234';

      await keysVerbHandler.process(keysCommand, inboundConnection);

      expect(inboundConnection.lastWrittenData, "data:-1\n$aliceEmoji@");
      expect(secondaryKeyStore.isKeyExists(keyName), true);
      expect(
          secondaryKeyStore.isKeyExists(
              'private:wavi.pixel.secretKey.__private_keys.__global@alice🛠'),
          true);
      var privateKeyName =
          'private:wavi.pixel.secretKey.__private_keys.__global@alice🛠';
      var keysGetCommand = 'keys:get:keyName:$privateKeyName';
      await keysVerbHandler.process(keysGetCommand, inboundConnection);
      var getKeysResponse = decodeResponse(inboundConnection.lastWrittenData!);
      expect(getKeysResponse['value'], 'abcd1234');
      expect(getKeysResponse['enrollmentId'], enrollId);
      expect(getKeysResponse['keyType'], 'aes256');
      expect(getKeysResponse['encryptionKeyName'], 'mykey');
      var deleteKeyCommand = 'keys:delete:keyName:$privateKeyName';
      await keysVerbHandler.process(deleteKeyCommand, inboundConnection);
      expect(inboundConnection.lastWrittenData, "data:-1\n$aliceEmoji@");
      expect(secondaryKeyStore.isKeyExists(privateKeyName), false);
    });

    test(
        'keys verb with an emoji Atsign - put private key and check getKeyName, delete',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      AtSecondaryServerImpl.getInstance().currentAtSign = '@alice🛠';
      var enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollId.new.enrollments.__manage@alice🛠';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      var keysCommand =
          'keys:put:private:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes256:encryptionKeyName:mykey:keyName:secretKey abcd1234';

      await keysVerbHandler.process(keysCommand, inboundConnection);

      expect(inboundConnection.lastWrittenData, "data:-1\n$aliceEmoji@");
      expect(secondaryKeyStore.isKeyExists(keyName), true);
      expect(
          secondaryKeyStore.isKeyExists(
              'private:wavi.pixel.secretKey.__private_keys.__global@alice🛠'),
          true);
      var privateKeyName =
          'private:wavi.pixel.secretKey.__private_keys.__global@alice🛠';
      var keysGetCommand = 'keys:get:keyName:$privateKeyName';
      await keysVerbHandler.process(keysGetCommand, inboundConnection);
      var getKeysResponse = decodeResponse(inboundConnection.lastWrittenData!);
      expect(getKeysResponse['value'], 'abcd1234');
      expect(getKeysResponse['enrollmentId'], enrollId);
      expect(getKeysResponse['keyType'], 'aes256');
      expect(getKeysResponse['encryptionKeyName'], 'mykey');
      var deleteKeyCommand = 'keys:delete:keyName:$privateKeyName';
      await keysVerbHandler.process(deleteKeyCommand, inboundConnection);
      expect(inboundConnection.lastWrittenData, "data:-1\n$aliceEmoji@");
      expect(secondaryKeyStore.isKeyExists(privateKeyName), false);
    });

    test(
        'keys verb - keys:get non-existent key should throw an key not found exception',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      var enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      var privateKeyName =
          'private:wavi.pixel.secretKey123.__private_keys.__global@alice';
      var keysGetCommand = 'keys:get:keyName:$privateKeyName';
      expect(
          () async =>
              await keysVerbHandler.process(keysGetCommand, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is KeyNotFoundException &&
              e.message == 'key $privateKeyName not found in keystore')));
    });

    test(
        'keys verb  - put default self encryption key and verify keys:get:self',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      var enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      var encryptedSelfEncryptionKey =
          'N0bmvnW1k5oKL+/6X3HresMyG/z6yBmxzgtrn8CMEofWgxJo8RSBXIqvdNj9ZOHO';
      var valueJson = {};
      valueJson['value'] = encryptedSelfEncryptionKey;
      await secondaryKeyStore.put(
          '$enrollId.${AtConstants.defaultSelfEncryptionKey}.$enrollManageNamespace@alice',
          AtData()..data = jsonEncode(valueJson));

      var keysGetCommand = 'keys:get:self';
      await keysVerbHandler.process(keysGetCommand, inboundConnection);
      var keysList = decodeResponseAsList(inboundConnection.lastWrittenData!);
      expect(keysList, isNotEmpty);
      expect(keysList[0],
          '$enrollId.${AtConstants.defaultSelfEncryptionKey}.$enrollManageNamespace@alice');
    });

    test('keys verb invalid syntax - invalid operation', () {
      var verb = Keys();
      var command = 'keys:update:hello';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test(
        'keys verb without specifying the operation invalid syntax - invalid operation',
        () {
      var verb = Keys();
      var command =
          'keys:public:namespace:__global:keyType:rsa2048:keyName:encryption_1278383933 testPublicKeyValue';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test(
        'keys verb  - put default  encryption private key and verify keys:get:private',
        () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      var enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      var encryptionPrivateKey = RSAKeypair.fromRandom().privateKey.toString();
      var apkamSymmetricKeyEncrypter = Encrypter(AES(Key.fromSecureRandom(32)));

      var encryptedDefaultEncryptionPrivateKey = apkamSymmetricKeyEncrypter
          .encrypt(encryptionPrivateKey, iv: IV(Uint8List(16)))
          .base64;
      var valueJson = {};
      valueJson['value'] = encryptedDefaultEncryptionPrivateKey;
      await secondaryKeyStore.put(
          '$enrollId.${AtConstants.defaultEncryptionPrivateKey}.$enrollManageNamespace@alice',
          AtData()..data = jsonEncode(valueJson));

      var keysGetCommand = 'keys:get:private';
      await keysVerbHandler.process(keysGetCommand, inboundConnection);
      var keysList = decodeResponseAsList(inboundConnection.lastWrittenData!);
      expect(keysList, isNotEmpty);
      expect(keysList[0],
          '$enrollId.${AtConstants.defaultEncryptionPrivateKey}.$enrollManageNamespace@alice');
    });

    test('keys:put verb without auth', () {
      var command =
          'keys:put:public:namespace:__global:keyType:rsa2048:keyName:encryption_1278383933 testPublicKeyValue';
      expect(
          () async => await keysVerbHandler.process(command, inboundConnection),
          throwsA(predicate((dynamic e) => e is UnAuthenticatedException)));
    });

    test(
        'keys:get verb without an authentication - should throw an UnAuthenticatedException',
        () async {
      var command = 'keys:get:nonexistentKey';
      expect(
          () async => await keysVerbHandler.process(command, inboundConnection),
          throwsA(predicate((dynamic e) => e is UnAuthenticatedException)));
    });

    test(
        'keys:delete verb without an authentication - should throw an UnAuthenticatedException',
        () async {
      var command = 'keys:delete:nonexistentKey';
      expect(
          () async => await keysVerbHandler.process(command, inboundConnection),
          throwsA(predicate((dynamic e) => e is UnAuthenticatedException)));
    });

    test('keys verb on an authenticated connection without enrollmentId',
        () async {
      inboundConnection.metadata.isAuthenticated = true;
      var keysGetCommand = 'keys:get:self';
      expect(
          () async =>
              await keysVerbHandler.process(keysGetCommand, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is AtEnrollmentException &&
              e.message ==
                  'Keys verb cannot be accessed without an enrollmentId')));
    });

    test('keys verb on enrollment which is not approved', () async {
      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      var keysGetCommand = 'keys:get:self';
      var enrollId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'pending'}
      };
      var keyName = '$enrollId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));
      expect(
          () async =>
              await keysVerbHandler.process(keysGetCommand, inboundConnection),
          throwsA(predicate((dynamic e) =>
              e is AtEnrollmentException &&
              e.message ==
                  'Enrollment Id $enrollId is not approved. current state: pending')));
    });
  });
}
