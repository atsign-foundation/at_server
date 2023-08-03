import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/keys_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

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
        'namespaces': {'name': 'wavi', 'access': 'rw'},
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
        'namespaces': {'name': 'wavi', 'access': 'rw'},
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
        'namespaces': {'name': 'wavi', 'access': 'rw'},
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
        'namespaces': {'name': 'wavi', 'access': 'rw'},
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
        'namespaces': {'name': 'wavi', 'access': 'rw'},
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
        'namespaces': {'name': 'wavi', 'access': 'rw'},
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
        'namespaces': {'name': 'wavi', 'access': 'rw'},
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
        'namespaces': {'name': 'wavi', 'access': 'rw'},
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
        'namespaces': {'name': 'wavi', 'access': 'rw'},
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
        'namespaces': {'name': 'wavi', 'access': 'rw'},
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
        'namespaces': {'name': 'wavi', 'access': 'rw'},
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
        'namespaces': {'name': 'wavi', 'access': 'rw'},
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
        'namespaces': {'name': 'wavi', 'access': 'rw'},
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
        'namespaces': {'name': 'wavi', 'access': 'rw'},
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
        'namespaces': {'name': 'wavi', 'access': 'rw'},
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
          '$enrollId.$defaultSelfEncryptionKey.$enrollManageNamespace@alice',
          AtData()..data = jsonEncode(valueJson));

      var keysGetCommand = 'keys:get:self';
      await keysVerbHandler.process(keysGetCommand, inboundConnection);
      var keysList = decodeResponseAsList(inboundConnection.lastWrittenData!);
      expect(keysList, isNotEmpty);
      expect(keysList[0],
          '$enrollId.$defaultSelfEncryptionKey.$enrollManageNamespace@alice');
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
        'namespaces': {'name': 'wavi', 'access': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));

      var encryptedDefaultEncryptionPrivateKey =
          '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'
          'gryzmuA';
      var valueJson = {};
      valueJson['value'] = encryptedDefaultEncryptionPrivateKey;
      await secondaryKeyStore.put(
          '$enrollId.$defaultEncryptionPrivateKey.$enrollManageNamespace@alice',
          AtData()..data = jsonEncode(valueJson));

      var keysGetCommand = 'keys:get:private';
      await keysVerbHandler.process(keysGetCommand, inboundConnection);
      var keysList = decodeResponseAsList(inboundConnection.lastWrittenData!);
      expect(keysList, isNotEmpty);
      expect(keysList[0],
          '$enrollId.$defaultEncryptionPrivateKey.$enrollManageNamespace@alice');
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
  });
}
