import 'dart:convert';
import 'dart:io';

import 'package:at_demo_data/at_demo_data.dart' as at_demos;
import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/auth_utils.dart';
import 'package:at_functional_test/utils/encryption_util.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() {
  OutboundConnectionFactory firstAtSignConnection = OutboundConnectionFactory();
  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  String secondAtSign =
      ConfigUtil.getYaml()!['secondAtSignServer']['secondAtSignName'];

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
  });

  group('A group of tests to verify apkam enroll requests', () {
    test(
        'A test to verify enroll request on CRAM authenticated connection is auto approved',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      String deviceName = "pixel-${Uuid().v4().hashCode}";
      // send an enroll request with the keys from the setEncryptionKeys method
      String enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"$deviceName","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap['encryptedSelfEncKey']}","apkamPublicKey":"${at_demos.pkamPublicKeyMap[firstAtSign]!}"}\n';
      String enrollResponse =
          (await firstAtSignConnection.sendRequestToServer(enrollRequest))
              .replaceAll('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');
      // Fetch the enrollment request details
      String enrollFetch =
          'enroll:fetch:{"enrollmentId":"${enrollJsonMap['enrollmentId']}"}';
      String enrollFetchResponse =
          (await firstAtSignConnection.sendRequestToServer(enrollFetch))
              .replaceAll('data:', '');
      Map<dynamic, dynamic> enrollMap = jsonDecode(enrollFetchResponse);
      print(enrollMap);
      expect(enrollMap['appName'], 'wavi');
      expect(enrollMap['deviceName'], deviceName);
      expect(
          enrollMap['namespace'], {'wavi': 'rw', '__manage': 'rw', '*': 'rw'});
    });

    test(
        'A test to verify denying of enroll request on an unauthenticated connection throws error',
        () async {
      var denyEnrollCommand =
          'enroll:deny:{"enrollmentId":"fa8e3cbf-b7d0-4674-a66d-d889914e2d02"}';
      String denyEnrollResponse =
          (await firstAtSignConnection.sendRequestToServer(denyEnrollCommand))
              .replaceAll('error:', '');
      expect(
          denyEnrollResponse
              .contains('Cannot deny enrollment without authentication'),
          true);
    });

    test(
        'A test to verify approving an enroll request on an unauthenticated connection throws error',
        () async {
      String approveEnrollCommand =
          'enroll:approve:{"enrollmentId":"fa8e3cbf-b7d0-4674-a66d-d889914e2d02"}';
      String approveEnrollResponse = (await firstAtSignConnection
              .sendRequestToServer(approveEnrollCommand))
          .replaceAll('error:', '');
      expect(
          approveEnrollResponse
              .contains('Cannot approve enrollment without authentication'),
          true);
    });

    test(
        'A test to verify approving of an invalid enrollmentId on an authenticated connection throws error',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      var dummyEnrollmentId = 'feay891281821899090eye';
      var approveEnrollCommand =
          'enroll:approve:{"enrollmentId":"$dummyEnrollmentId","encryptedDefaultEncryptionPrivateKey": "dummy_encrypted_default_encryption_private_key","encryptedDefaultSelfEncryptionKey":"dummy_encrypted_default_self_encryption_key"}';
      var approveEnrollResponse = (await firstAtSignConnection
              .sendRequestToServer(approveEnrollCommand))
          .replaceAll('error:', '');
      expect(approveEnrollResponse,
          'AT0028:enrollment_id: $dummyEnrollmentId is expired or invalid');
    });

    test(
        'A test to verify denial of an invalid enrollmentId on an authenticated connection should throw an error',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      String dummyEnrollmentId = 'feay891281821899090eye';
      String denyEnrollCommand =
          'enroll:deny:{"enrollmentId":"$dummyEnrollmentId"}';
      String denyEnrollResponse =
          (await firstAtSignConnection.sendRequestToServer(denyEnrollCommand))
              .replaceFirst('error:', '');
      expect(denyEnrollResponse,
          'AT0028:enrollment_id: $dummyEnrollmentId is expired or invalid');
    });

    test('enroll request on unauthenticated connection without otp', () async {
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}"}\n';
      String enrollResponse =
          (await firstAtSignConnection.sendRequestToServer(enrollRequest))
              .replaceFirst('error:', '');
      expect(
          enrollResponse.contains('invalid otp. Cannot process enroll request'),
          true);
    });

    test(
        'Submit an enroll request on unauthenticated connection with invalid otp',
        () async {
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"otp":"1234","apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey": "dummy_encrypted_symm_key"}\n';
      String enrollResponse =
          (await firstAtSignConnection.sendRequestToServer(enrollRequest))
              .replaceFirst('data:', '');
      expect(
          enrollResponse.contains('invalid otp. Cannot process enroll request'),
          true);
    });

    // Purpose of the tests
    // 1. Do a pkam authentication
    // 2. Send an enroll request
    // 3 . Get an otp from the first client
    // 4. Send an enroll request with otp from the second client
    // 5. First client doesn't approve the enroll request
    // 6. Second client should get an exception as the enroll request is not approved
    test('second enroll request using otp and client denied enrollment request',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      // send an enroll request with the keys from the setEncryptionKeys method
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap['encryptedSelfEncKey']}","apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}';
      String enrollResponse =
          await firstAtSignConnection.sendRequestToServer(enrollRequest);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');

      String otpResponse =
          (await firstAtSignConnection.sendRequestToServer('otp:get'))
              .replaceAll('data:', '')
              .trim();
      // connect to the second client
      OutboundConnectionFactory socketConnection2 =
          await OutboundConnectionFactory().initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      //send second enroll request with otp
      var apkamPublicKey = pkamPublicKeyMap[firstAtSign];
      var secondEnrollRequest =
          'enroll:request:{"appName":"buzz","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"otp":"$otpResponse","apkamPublicKey":"$apkamPublicKey","encryptedAPKAMSymmetricKey": "${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}\n';

      var secondEnrollResponse =
          (await socketConnection2.sendRequestToServer(secondEnrollRequest))
              .replaceFirst('data:', '');
      var enrollJson = jsonDecode(secondEnrollResponse);
      expect(enrollJson['enrollmentId'], isNotEmpty);
      expect(enrollJson['status'], 'pending');

      var secondEnrollId = enrollJson['enrollmentId'];
      // deny the enroll request from the first client
      var denyEnrollCommand = 'enroll:deny:{"enrollmentId":"$secondEnrollId"}';
      String denyEnrollResponse =
          (await firstAtSignConnection.sendRequestToServer(denyEnrollCommand))
              .replaceFirst('data:', '');
      var approveJson = jsonDecode(denyEnrollResponse);
      expect(approveJson['status'], 'denied');
      expect(approveJson['enrollmentId'], secondEnrollId);
      // now do the apkam using the enrollment id
      String apkamAuthResponse = await socketConnection2.authenticateConnection(
          authType: AuthType.apkam, enrollmentId: secondEnrollId);
      expect(apkamAuthResponse,
          'error:AT0025:enrollment_id: $secondEnrollId is denied');
    });

    // enroll request with only first client
    // Purpose of the test
    // 1. Do a cram authentication
    // 2. Encrypt the default encryption private key and self encryption key with the apkam symmetric key
    // 3. Send an enroll request with above encrypted keys
    // 4. Assert that the enroll request is successful
    // 5. Disconnect the first client
    // 6. Connect to the second client
    // 7. Send an apkam request with the enrollment id from step 4
    // 8. Assert that the apkam request is successful
    // 9. Assert that the scan verb returns the key with __manage namespace
    // 10. Assert that the enroll:list verb returns the enrollment key
    // 11. Assert that the llookup verb on the enrollment key fails
    // 12. Assert that the keys:get:self verb returns the default self encryption key
    // 13. Assert that the keys:get:private verb returns the default encryption private key
    // 14. Assert that the keys:get:selfKeyName verb returns the default self encryption key
    // 15. Assert that the keys:get:privateKeyName verb returns the default encryption private key
    test('enroll request on CRAM authenticated connection and encryption keys',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      // send an enroll request with the keys from the setEncryptionKeys method
      String enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap['encryptedSelfEncKey']}","apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}';
      String enrollResponse =
          (await firstAtSignConnection.sendRequestToServer(enrollRequest))
              .replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      var enrollmentId = enrollJsonMap['enrollmentId'];
      expect(enrollmentId, isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');
      // destroy the first connection
      firstAtSignConnection.close();

      // connect to the second client with the above enrollment ID
      OutboundConnectionFactory socketConnection2 =
          await OutboundConnectionFactory().initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      await socketConnection2.authenticateConnection(
          authType: AuthType.pkam, enrollmentId: enrollmentId);

      // check if scan verb returns apkam namespace
      String scanResponse = await socketConnection2.sendRequestToServer('scan');
      // assert that scan doesn't return key with __manage namespace
      expect(scanResponse.contains('__manage'), true);

      // enroll:list
      String enrollListResponse =
          await socketConnection2.sendRequestToServer('enroll:list');
      // enrollment key to be checked
      var enrollmentKey = '$enrollmentId.new.enrollments.__manage$firstAtSign';
      expect(enrollListResponse.contains(enrollmentKey), true);

      // llookup of the enrollment key should fail
      String llookupResponse = (await socketConnection2
              .sendRequestToServer('llookup:$enrollmentKey'))
          .replaceFirst('error:', '');
      Map llookupResponseMap = jsonDecode(llookupResponse);
      expect(llookupResponseMap['errorCode'], 'AT0009');
      expect(llookupResponseMap['errorDescription'],
          'UnAuthorized client in request : Connection with enrollment ID $enrollmentId is not authorized to llookup key: $enrollmentKey');

      // keys:get:self should return default self encryption key
      var selfKey = '$enrollmentId.default_self_enc_key.__manage$firstAtSign';
      String selfKeyResponse =
          await socketConnection2.sendRequestToServer('keys:get:self');
      expect(selfKeyResponse.contains(selfKey), true);

      // keys:get:private should return private encryption key
      var privateKey =
          '$enrollmentId.default_enc_private_key.__manage$firstAtSign';
      String privateKeyResponse =
          await socketConnection2.sendRequestToServer('keys:get:private');
      expect(privateKeyResponse.contains(privateKey), true);

      // keys:get:keyName should return the enrollment key with __manage namespace
      String selfKeyGetResponse = await socketConnection2
          .sendRequestToServer('keys:get:keyName:$selfKey');
      expect(
          selfKeyGetResponse
              .contains('${apkamEncryptedKeysMap['encryptedSelfEncKey']}'),
          true);

      // keys:get:keyName should return the enrollment key with __manage namespace
      String privateKeyGetResponse = await socketConnection2
          .sendRequestToServer('keys:get:keyName:$privateKey');
      expect(
          privateKeyGetResponse.contains(
              '${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}'),
          true);
    });

    test(
        'enroll request on APKAM authenticated connection and verify enroll:list',
        () async {
      int randomNumber = Uuid().v4().hashCode;
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.pkam);
      // send an enroll request with the keys from the setEncryptionKeys method
      String enrollRequest =
          'enroll:request:{"appName":"atmosphere-$randomNumber","deviceName":"pixel-$randomNumber","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap['encryptedSelfEncKey']}","apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey":"dummy_apkam_$randomNumber"}';
      String enrollResponse =
          (await firstAtSignConnection.sendRequestToServer(enrollRequest))
              .replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      var enrollmentId = enrollJsonMap['enrollmentId'];
      expect(enrollmentId, isNotEmpty);
      expect(enrollJsonMap['status'], 'pending');
      // enroll:list
      String enrollListResponse =
          await firstAtSignConnection.sendRequestToServer('enroll:list');
      enrollListResponse = enrollListResponse.replaceAll('data:', '');
      var enrollListResponseMap = jsonDecode(enrollListResponse);
      expect(
          enrollListResponseMap[
              '$enrollmentId.new.enrollments.__manage$firstAtSign']['appName'],
          'atmosphere-$randomNumber');
      expect(
          enrollListResponseMap[
                  '$enrollmentId.new.enrollments.__manage$firstAtSign']
              ['deviceName'],
          'pixel-$randomNumber');
      expect(
          enrollListResponseMap[
                  '$enrollmentId.new.enrollments.__manage$firstAtSign']
              ['namespace']['wavi'],
          'rw');
      expect(
          enrollListResponseMap[
                  '$enrollmentId.new.enrollments.__manage$firstAtSign']
              ['encryptedAPKAMSymmetricKey'],
          'dummy_apkam_$randomNumber');
    });

    // Purpose of the tests
    // 1. Do a pkam authentication
    // 2. Send an enroll request
    //  3 . Get an otp from the first client
    //  4. Send an enroll request with otp from the second client
    //  5. First client approves the enroll request
    test(
        'second enroll request using otp and client approves enrollment request',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap['encryptedSelfEncKey']}","apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}';
      String enrollResponse =
          (await firstAtSignConnection.sendRequestToServer(enrollRequest))
              .replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');

      String otpResponse =
          (await firstAtSignConnection.sendRequestToServer('otp:get'))
              .replaceFirst('data:', '')
              .trim();
      // connect to the second client
      OutboundConnectionFactory socketConnection2 =
          await OutboundConnectionFactory().initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      //send second enroll request with otp
      String secondEnrollRequest =
          'enroll:request:{"appName":"buzz","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"otp":"$otpResponse","apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey": "${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}';
      String secondEnrollResponse =
          (await socketConnection2.sendRequestToServer(secondEnrollRequest))
              .replaceFirst('data:', '');
      var enrollJson = jsonDecode(secondEnrollResponse);
      expect(enrollJson['enrollmentId'], isNotEmpty);
      expect(enrollJson['status'], 'pending');
      var secondEnrollId = enrollJson['enrollmentId'];

      // connect to the first client to approve the enroll request
      String approveResponse = (await firstAtSignConnection.sendRequestToServer(
              'enroll:approve:{"enrollmentId":"$secondEnrollId","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey": "${apkamEncryptedKeysMap['encryptedSelfEncKey']}"}'))
          .replaceFirst('data:', '');
      var approveJson = jsonDecode(approveResponse);
      expect(approveJson['status'], 'approved');
      expect(approveJson['enrollmentId'], secondEnrollId);

      // close the first connection
      await firstAtSignConnection.close();
      // connect to the second client to do an apkam
      await socketConnection2.authenticateConnection(
          authType: AuthType.apkam, enrollmentId: secondEnrollId);

      // keys:get:self should return default self encryption key
      var selfKey = '$secondEnrollId.default_self_enc_key.__manage$firstAtSign';
      String selfKeyResponse =
          await socketConnection2.sendRequestToServer('keys:get:self');
      expect(selfKeyResponse.contains(selfKey), true);

      // keys:get:private should return private encryption key
      var privateKey =
          '$secondEnrollId.default_enc_private_key.__manage$firstAtSign';
      String privateKeyResponse =
          await socketConnection2.sendRequestToServer('keys:get:private');
      expect(privateKeyResponse.contains(privateKey), true);
    });

    test(
        'A test to verify pending enrollment is stored and written on to a monitor connection',
        () async {
      String deviceName = 'pixel-${Uuid().v4().hashCode}';
      var timeStamp = DateTime.now().toUtc().millisecondsSinceEpoch;
      // Fetch notification from this timestamp
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      // Get a TOTP
      var otpResponse =
          await firstAtSignConnection.sendRequestToServer('otp:get');
      otpResponse = otpResponse.replaceFirst('data:', '');
      otpResponse = otpResponse.trim();
      await firstAtSignConnection.close();
      // Connect to unauthenticated socket to send an enrollment request
      firstAtSignConnection = await OutboundConnectionFactory()
          .initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      var secondEnrollRequest =
          'enroll:request:{"appName":"buzz","deviceName": "$deviceName","namespaces":{"buzz":"rw"},"otp":"$otpResponse","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap['encryptedSelfEncKey']}","apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey":"${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}';
      var secondEnrollResponse =
          await firstAtSignConnection.sendRequestToServer(secondEnrollRequest);
      secondEnrollResponse = secondEnrollResponse.replaceFirst('data:', '');
      var enrollJson = jsonDecode(secondEnrollResponse);
      expect(enrollJson['enrollmentId'], isNotEmpty);
      expect(enrollJson['status'], 'pending');

      SecureSocket monitorSocket =
          await SecureSocket.connect(firstAtSignHost, firstAtSignPort);
      monitorSocket.listen(expectAsync1((data) {
        String serverResponse = utf8.decode(data);
        serverResponse = serverResponse.trim();
        // From response starts with "data:_"
        if (serverResponse.startsWith('data:_')) {
          serverResponse = serverResponse.replaceAll('data:', '');
          serverResponse =
              serverResponse.substring(0, serverResponse.indexOf('\n'));
          var cramSecret = AuthenticationUtils.getCRAMDigest(
              firstAtSign, serverResponse.trim());
          monitorSocket.write('cram:$cramSecret\n');
        }
        // CRAM Response starts-with "data:success"
        else if (serverResponse.startsWith('data:success')) {
          monitorSocket.write('monitor:selfNotifications:$timeStamp\n');
        }
        // Response on monitor starts with "notification:"
        else if (serverResponse.startsWith('notification:')) {
          expect(
              serverResponse.contains(
                  '${enrollJson['enrollmentId']}.new.enrollments.__manage'),
              true);
          Map notificationValue = jsonDecode(jsonDecode(
              serverResponse.replaceAll('notification: ', ''))['value']);
          expect(notificationValue['appName'], 'buzz');
          expect(notificationValue['deviceName'], deviceName);
          expect(notificationValue['namespace'], {'buzz': 'rw'});
          // TODO remove encryptedApkamSymmetricKey and use encryptedAPKAMSymmetricKey constant name in future
          expect(notificationValue['encryptedApkamSymmetricKey'],
              apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']);
          expect(notificationValue['encryptedAPKAMSymmetricKey'],
              apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']);
          monitorSocket.close();
        }
        /* Setting count to 4 to wait until server returns 4 responses
      1. On creating a connection, server returns "@"
      2. On sending from request, server returns from challenge
      3. On sending a cram request, server returns "data:success"
      4. On sending monitor request, server returns enrollment request
        */
      }, count: 4));
      monitorSocket.write('from:${firstAtSign.toString().trim()}\n');
    });

    test('A test to verify enrolled client can do legacy pkam auth', () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      // send an enroll request with the keys from the setEncryptionKeys method
      String enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap['encryptedSelfEncKey']}","apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}';
      String enrollResponse =
          (await firstAtSignConnection.sendRequestToServer(enrollRequest))
              .replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      String enrollmentId = enrollJsonMap['enrollmentId'];
      expect(enrollmentId, isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');
      await firstAtSignConnection.close();
      // PKAM Auth
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.pkam);
    });

    test('A test to verify pkam public key is stored in __pkams namespace',
        () async {
      String deviceName = 'pixel-${Uuid().v4().hashCode}';
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      // Get otp
      String otp = (await firstAtSignConnection.sendRequestToServer('otp:get'))
          .replaceAll('data:', '')
          .trim();
      // send an enroll request
      OutboundConnectionFactory socketConnection2 =
          await OutboundConnectionFactory().initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"$deviceName","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey": "${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}';
      String enrollResponse =
          (await socketConnection2.sendRequestToServer(enrollRequest))
              .replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      var enrollmentId = enrollJsonMap['enrollmentId'];
      expect(enrollmentId, isNotEmpty);
      expect(enrollJsonMap['status'], 'pending');
      // Approve enrollment
      String approveEnrollment =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey": "${apkamEncryptedKeysMap['encryptedSelfEncKey']}"}';
      String enrollmentResponse =
          await firstAtSignConnection.sendRequestToServer(approveEnrollment);
      enrollmentResponse = enrollmentResponse.replaceAll('data:', '');
      expect(jsonDecode(enrollmentResponse)['status'], 'approved');
      String llookupResponse = await firstAtSignConnection.sendRequestToServer(
          'llookup:public:wavi.$deviceName.pkam.__pkams.__public_keys@alice🛠');
      llookupResponse = llookupResponse.replaceAll('data:', '');
      var apkamPublicKey = jsonDecode(llookupResponse)['apkamPublicKey'];
      expect(apkamPublicKey, apkamPublicKeyMap[firstAtSign]!);
    });

    test(
        'A test to verify exception is thrown when an enrollment request with existing appName and deviceName is submitted',
        () async {
      String deviceName = 'pixel-${Uuid().v4().hashCode}';
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      // send an enroll request with the keys from the setEncryptionKeys method
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"$deviceName","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap['encryptedSelfEncKey']}","apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}';
      String enrollResponse =
          await firstAtSignConnection.sendRequestToServer(enrollRequest);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');

      await firstAtSignConnection.sendRequestToServer('otp:put:ABC123');

      // connect to the second client
      OutboundConnectionFactory socketConnection2 =
          await OutboundConnectionFactory().initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      //send second enroll request with otp
      var apkamPublicKey = pkamPublicKeyMap[firstAtSign];
      var secondEnrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"$deviceName","namespaces":{"buzz":"rw"},"otp":"ABC123","apkamPublicKey":"$apkamPublicKey","encryptedAPKAMSymmetricKey": "${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}\n';
      var secondEnrollResponse =
          (await socketConnection2.sendRequestToServer(secondEnrollRequest))
              .replaceAll('error:', '');
      expect(secondEnrollResponse,
          'AT0011-Exception: Another enrollment with id ${enrollJsonMap['enrollmentId']} exists with the app name: wavi and device name: $deviceName in approved state');
    });

    group('A group of tests related to APKAM revoke operation', () {
      test(
          'A test to verify enrollment revoke operation on own connection results in error',
          () async {
        // Send an enrollment request on the authenticated connection
        await firstAtSignConnection.authenticateConnection(
            authType: AuthType.cram);
        String enrollRequest =
            'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}"}';
        String enrollmentResponse =
            await firstAtSignConnection.sendRequestToServer(enrollRequest);
        String enrollmentId = jsonDecode(
            enrollmentResponse.replaceAll('data:', ''))['enrollmentId'];

        //Create a new connection to login using the APKAM
        OutboundConnectionFactory socketConnection2 =
            await OutboundConnectionFactory().initiateConnectionWithListener(
                firstAtSign, firstAtSignHost, firstAtSignPort);
        String authResponse = await socketConnection2.authenticateConnection(
            authType: AuthType.apkam, enrollmentId: enrollmentId);
        expect(authResponse.trim(), 'data:success');
        await socketConnection2.close();

        // Revoke the enrollment
        String revokeEnrollmentCommand =
            'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
        String revokeEnrollmentResponse = await firstAtSignConnection
            .sendRequestToServer(revokeEnrollmentCommand);
        var revokeEnrollmentMap =
            jsonDecode(revokeEnrollmentResponse.replaceAll('error:', ''));
        expect(revokeEnrollmentMap['errorCode'], 'AT0031');
        expect(revokeEnrollmentMap['errorDescription'],
            'Cannot revoke self enrollment : Current client cannot revoke its own enrollment');
      });

      test(
          'A test to verify enrollment revoke on own enrollment with force flag',
          () async {
        // Send an enrollment request on the authenticated connection
        await firstAtSignConnection.authenticateConnection(
            authType: AuthType.cram);
        String enrollRequest =
            'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}"}';
        String enrollmentResponse =
            await firstAtSignConnection.sendRequestToServer(enrollRequest);
        String enrollmentId = jsonDecode(
            enrollmentResponse.replaceAll('data:', ''))['enrollmentId'];

        //Create a new connection to login using the APKAM
        OutboundConnectionFactory socketConnection2 =
            await OutboundConnectionFactory().initiateConnectionWithListener(
                firstAtSign, firstAtSignHost, firstAtSignPort);
        String authResponse = await socketConnection2.authenticateConnection(
            authType: AuthType.apkam, enrollmentId: enrollmentId);
        expect(authResponse.trim(), 'data:success');
        await socketConnection2.close();

        // Revoke the enrollment
        String revokeEnrollmentCommand =
            'enroll:revoke:force:{"enrollmentId":"$enrollmentId"}';
        String revokeEnrollmentResponse = await firstAtSignConnection
            .sendRequestToServer(revokeEnrollmentCommand);
        var revokeEnrollmentMap =
            jsonDecode(revokeEnrollmentResponse.replaceAll('data:', ''));
        expect(revokeEnrollmentMap['status'], 'revoked');
        expect(revokeEnrollmentMap['enrollmentId'], enrollmentId);
        expect(revokeEnrollmentMap['message'],
            "Enrollment is revoked. Closing the connection in 10 seconds");

        socketConnection2 = await OutboundConnectionFactory()
            .initiateConnectionWithListener(
                firstAtSign, firstAtSignHost, firstAtSignPort);
        String pkamResult = await socketConnection2.authenticateConnection(
            authType: AuthType.apkam, enrollmentId: enrollmentId);
        socketConnection2.close();
        assert(pkamResult.contains('enrollment_id: $enrollmentId is revoked'));
      });

      test(
          'A test to verify revoke operation cannot be performed on an unauthenticated connection',
          () async {
        // Send an enrollment request on the authenticated connection
        await firstAtSignConnection.authenticateConnection(
            authType: AuthType.cram);
        String enrollRequest =
            'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}';
        var enrollmentResponse =
            await firstAtSignConnection.sendRequestToServer(enrollRequest);
        String enrollmentId = jsonDecode(
            enrollmentResponse.replaceAll('data:', ''))['enrollmentId'];

        OutboundConnectionFactory socketConnection2 =
            await OutboundConnectionFactory().initiateConnectionWithListener(
                firstAtSign, firstAtSignHost, firstAtSignPort);
        String revokeEnrollmentCommand =
            'enroll:revoke:{"enrollmentid":"$enrollmentId"}';
        String revokeEnrollmentResponse = await socketConnection2
            .sendRequestToServer(revokeEnrollmentCommand);
        expect(revokeEnrollmentResponse.trim(),
            'error:AT0401-Exception: Cannot revoke enrollment without authentication');
      });
    });
  });

  group('A group of negative tests on enroll verb', () {
    late String enrollmentId;
    late String enrollmentResponse;

    setUp(() async {
      await firstAtSignConnection.authenticateConnection();
      // Get TOTP from server
      String otp = (await firstAtSignConnection.sendRequestToServer('otp:get'))
          .replaceFirst('data:', '')
          .trim();
      // Close the connection and create a new connection and send an enrollment
      // request on an unauthenticated connection.
      OutboundConnectionFactory unauthenticatedConnection =
          await OutboundConnectionFactory().initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      String enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey" : "${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}';
      enrollmentResponse =
          await unauthenticatedConnection.sendRequestToServer(enrollRequest);
      enrollmentResponse = enrollmentResponse.replaceAll('data:', '');
      enrollmentId = jsonDecode(enrollmentResponse)['enrollmentId'];
      await unauthenticatedConnection.close();
    });

    test(
        'A test to verify error is returned when pending enrollment is revoked',
        () async {
      // Revoke enrollment on an authenticate connection
      enrollmentResponse = (await firstAtSignConnection.sendRequestToServer(
              'enroll:revoke:{"enrollmentId":"$enrollmentId"}'))
          .replaceFirst('error:', '');
      expect(jsonDecode(enrollmentResponse)['errorCode'], 'AT0011');
      expect(jsonDecode(enrollmentResponse)['errorDescription'],
          'Internal server exception : Failed to revoke enrollment id: $enrollmentId. Cannot revoke a pending enrollment. Only approved enrollments can be revoked');
    });

    test(
        'A test to verify error is returned when denied enrollment is approved',
        () async {
      // Deny enrollment on an authenticate connection
      enrollmentResponse = (await firstAtSignConnection.sendRequestToServer(
              'enroll:deny:{"enrollmentId":"$enrollmentId"}'))
          .replaceFirst('data:', '');

      expect(jsonDecode(enrollmentResponse)['status'], 'denied');
      expect(jsonDecode(enrollmentResponse)['enrollmentId'], enrollmentId);
      // Approve enrollment
      enrollmentResponse = (await firstAtSignConnection.sendRequestToServer(
              'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey": "${apkamEncryptedKeysMap['encryptedSelfEncKey']}"}'))
          .replaceAll('error:', '');
      expect(
          jsonDecode(enrollmentResponse)['errorDescription'],
          'Internal server exception : Failed to approve enrollment id: $enrollmentId. Cannot approve a denied enrollment. '
          'Only pending enrollments can be approved');
    });

    test('A test to verify error is returned when denied enrollment is revoked',
        () async {
      // Deny enrollment on an authenticate connection
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.pkam);
      enrollmentResponse = (await firstAtSignConnection.sendRequestToServer(
              'enroll:deny:{"enrollmentId":"$enrollmentId"}'))
          .replaceAll('data:', '');
      expect(jsonDecode(enrollmentResponse)['status'], 'denied');
      expect(jsonDecode(enrollmentResponse)['enrollmentId'], enrollmentId);
      // Revoke enrollment
      enrollmentResponse = (await firstAtSignConnection.sendRequestToServer(
              'enroll:revoke:{"enrollmentId":"$enrollmentId"}'))
          .replaceAll('error:', '');
      expect(
          jsonDecode(enrollmentResponse)['errorDescription'],
          'Internal server exception : Failed to revoke enrollment id: $enrollmentId. Cannot revoke a denied enrollment. '
          'Only approved enrollments can be revoked');
    });

    test('A test to verify revoked enrollment cannot be approved', () async {
      // Approve enrollment
      await firstAtSignConnection.authenticateConnection();
      enrollmentResponse = (await firstAtSignConnection.sendRequestToServer(
              'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey": "${apkamEncryptedKeysMap['encryptedSelfEncKey']}"}'))
          .replaceAll('data:', '');
      expect(jsonDecode(enrollmentResponse)['status'], 'approved');
      expect(jsonDecode(enrollmentResponse)['enrollmentId'], enrollmentId);
      // Revoke enrollment
      enrollmentResponse = (await firstAtSignConnection.sendRequestToServer(
              'enroll:revoke:{"enrollmentId":"$enrollmentId"}'))
          .replaceAll('data:', '');
      expect(jsonDecode(enrollmentResponse)['status'], 'revoked');
      expect(jsonDecode(enrollmentResponse)['enrollmentId'], enrollmentId);
      // Approve a revoked enrollment
      enrollmentResponse = (await firstAtSignConnection.sendRequestToServer(
              'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey": "${apkamEncryptedKeysMap['encryptedSelfEncKey']}"}'))
          .replaceAll('error:', '');
      expect(
          jsonDecode(enrollmentResponse)['errorDescription'],
          'Internal server exception : Failed to approve enrollment id: $enrollmentId. Cannot approve a revoked enrollment. '
          'Only pending enrollments can be approved');
    });
  });

  group('A group of test related to Rate limiting enrollment requests', () {
    String otp = '';
    setUp(() async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      String configResponse = await firstAtSignConnection
          .sendRequestToServer('config:set:maxRequestsPerTimeFrame=1');
      expect(configResponse.trim(), 'data:ok');
      configResponse = await firstAtSignConnection
          .sendRequestToServer('config:set:timeFrameInMills=100');
      expect(configResponse.trim(), 'data:ok');
    });

    test(
        'A test to verify exception is thrown when request exceed the configured limit',
        () async {
      OutboundConnectionFactory unAuthenticatedConnection =
          await OutboundConnectionFactory().initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      otp = await firstAtSignConnection.sendRequestToServer('otp:get');
      otp = otp.replaceAll('data:', '').trim();
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey" : "${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}';
      String enrollmentResponse =
          await unAuthenticatedConnection.sendRequestToServer(enrollRequest);
      Map enrollmentResponseMap =
          jsonDecode(enrollmentResponse.replaceAll('data:', ''));
      expect(enrollmentResponseMap['status'], 'pending');
      expect(enrollmentResponseMap['enrollmentId'], isNotNull);

      otp = await firstAtSignConnection.sendRequestToServer('otp:get');
      otp = otp.replaceAll('data:', '').trim();
      enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey" : "${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}\n';
      enrollmentResponse =
          (await unAuthenticatedConnection.sendRequestToServer(enrollRequest))
              .replaceAll('error:', '');
      expect(
          enrollmentResponse.contains(
              'Enrollment requests have exceeded the limit within the specified time frame'),
          true);
    });

    test('A test to verify request is successful after the time window',
        () async {
      OutboundConnectionFactory unAuthenticatedConnection =
          await OutboundConnectionFactory().initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);

      otp = await firstAtSignConnection.sendRequestToServer('otp:get');
      otp = otp.replaceAll('data:', '').trim();
      String enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey" : "${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}';
      String enrollmentResponse =
          (await unAuthenticatedConnection.sendRequestToServer(enrollRequest))
              .replaceAll('data:', '');

      Map enrollmentResponseMap = jsonDecode(enrollmentResponse);
      expect(enrollmentResponseMap['status'], 'pending');
      expect(enrollmentResponseMap['enrollmentId'], isNotNull);

      otp = await firstAtSignConnection.sendRequestToServer('otp:get');
      otp = otp.replaceAll('data:', '').trim();
      enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey" : "${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}';
      enrollmentResponse =
          (await unAuthenticatedConnection.sendRequestToServer(enrollRequest))
              .replaceAll('error:', '');
      expect(
          enrollmentResponse.contains(
              'Enrollment requests have exceeded the limit within the specified time frame'),
          true);
      await Future.delayed(Duration(milliseconds: 110));
      enrollmentResponse =
          (await unAuthenticatedConnection.sendRequestToServer(enrollRequest))
              .replaceAll('data:', '');
      enrollmentResponseMap = jsonDecode(enrollmentResponse);
      expect(enrollmentResponseMap['status'], 'pending');
      expect(enrollmentResponseMap['enrollmentId'], isNotNull);
    });

    test('A test to verify rate limit is per connection', () async {
      OutboundConnectionFactory unAuthenticatedConnection =
          await OutboundConnectionFactory().initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);

      otp = await firstAtSignConnection.sendRequestToServer('otp:get');
      otp = otp.replaceAll('data:', '').trim();
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey" : "${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}';
      String enrollmentResponse =
          (await unAuthenticatedConnection.sendRequestToServer(enrollRequest))
              .replaceAll('data:', '');

      Map enrollmentResponseMap = jsonDecode(enrollmentResponse);
      expect(enrollmentResponseMap['status'], 'pending');
      expect(enrollmentResponseMap['enrollmentId'], isNotNull);

      otp = await firstAtSignConnection.sendRequestToServer('otp:get');
      otp = otp.replaceAll('data:', '').trim();
      enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey" : "${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}';
      enrollmentResponse =
          (await unAuthenticatedConnection.sendRequestToServer(enrollRequest))
              .replaceAll('error:', '');
      expect(
          enrollmentResponse.contains(
              'Enrollment requests have exceeded the limit within the specified time frame'),
          true);
      OutboundConnectionFactory secondUnAuthenticatedConnection2 =
          await OutboundConnectionFactory().initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);

      otp = await firstAtSignConnection.sendRequestToServer('otp:get');
      otp = otp.replaceAll('data:', '').trim();
      enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey" : "${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}';
      enrollmentResponse = await secondUnAuthenticatedConnection2
          .sendRequestToServer(enrollRequest);
      enrollmentResponseMap =
          jsonDecode(enrollmentResponse.replaceAll('data:', ''));
      expect(enrollmentResponseMap['status'], 'pending');
      expect(enrollmentResponseMap['enrollmentId'], isNotNull);
    });

    tearDown(() async {
      await firstAtSignConnection
          .sendRequestToServer('config:reset:maxRequestsAllowed');
      await firstAtSignConnection
          .sendRequestToServer('config:reset:timeWindowInMills');
    });
  });

  group('A group of tests related to fetching latest commit id', () {
    String enrollmentResponse;
    late String enrollmentId;
    setUp(() async {
      // Get TOTP from server
      await firstAtSignConnection.authenticateConnection();
      String otp = await firstAtSignConnection.sendRequestToServer('otp:get');
      otp = otp.replaceFirst('data:', '');
      await firstAtSignConnection.close();
      // Close the connection and create a new connection and send an enrollment request on an
      // unauthenticated connection.
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      String enrollRequest =
          'enroll:request:{"appName":"my-first-app","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw","buzz":"r"},"otp":"$otp","apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey" : "${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}';
      enrollmentResponse =
          await firstAtSignConnection.sendRequestToServer(enrollRequest);
      enrollmentResponse = enrollmentResponse.replaceAll('data:', '');
      enrollmentId = jsonDecode(enrollmentResponse)['enrollmentId'];
      enrollmentId = enrollmentId.trim();
      await firstAtSignConnection.close();
    });

    /// The purpose of the test is to fetch the latestCommitId among the enrolled namespaces
    /// When 3 keys are inserted into server:
    /// key1.wavi@alice - CommitId: 1
    /// key2.buzz@alice - CommitId: 2
    /// key3.atmosphere@alice - CommitId: 3
    /// and if only 'wavi' and 'buzz' are enrolled, return commitId: 2
    test(
        'A test to verify stats verb returns highest commitId among enrolled namespace',
        () async {
      String randomId = Uuid().v4();
      String enrollRequest =
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap["encryptedDefaultEncPrivateKey"]}","encryptedDefaultSelfEncryptionKey": "${apkamEncryptedKeysMap["encryptedSelfEncKey"]}"}';
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      await firstAtSignConnection.authenticateConnection();
      await firstAtSignConnection.sendRequestToServer(enrollRequest);
      await firstAtSignConnection.sendRequestToServer('stats:3');

      await firstAtSignConnection.sendRequestToServer(
          'update:$secondAtSign:phone-$randomId.wavi$firstAtSign random-value');
      String commitIdOfLastEnrolledKey =
          await firstAtSignConnection.sendRequestToServer(
              'update:$secondAtSign:mobile-$randomId.buzz$firstAtSign random-value');
      commitIdOfLastEnrolledKey =
          commitIdOfLastEnrolledKey.replaceAll('data:', '').trim();
      // Key which has un-enrolled namespace
      firstAtSignConnection.sendRequestToServer(
          'update:$secondAtSign:contact-$randomId.atmosphere$firstAtSign random-value');

      await firstAtSignConnection.close();
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.apkam, enrollmentId: enrollmentId);

      String lastCommitIdAmongEnrolledNamespace =
          await firstAtSignConnection.sendRequestToServer('stats:3');
      lastCommitIdAmongEnrolledNamespace = jsonDecode(
              lastCommitIdAmongEnrolledNamespace.replaceAll('data:', ''))[0]
          ['value'];
      expect(
          int.parse(lastCommitIdAmongEnrolledNamespace) >=
              int.parse(commitIdOfLastEnrolledKey),
          true);
    });
  });

  group('Group of tests to validate listing of enrollments', () {
    List<String> enrollmentIds = [];

    /// The setUpAll() will create five random enrollment requests and store each
    /// of the enrollmentId's in [enrollmentIds]
    ///
    /// Each of the tests in this group will approve/deny/revoke a certain
    /// enrollmentId present in [enrollmentIds] and will validate through
    /// enroll:list using appropriate filter, such that the enrollment requests
    /// with specified enrollment status are returned
    setUpAll(() async {
      // create five enrollment requests
      for (int i = 0; i < 5; i++) {
        await firstAtSignConnection.initiateConnectionWithListener(
            firstAtSign, firstAtSignHost, firstAtSignPort);
        await firstAtSignConnection.authenticateConnection();
        String otp = await firstAtSignConnection.sendRequestToServer('otp:get');
        otp = otp.replaceFirst('data:', '');
        await firstAtSignConnection.close();
        // Close the connection and create a new connection and send an
        // enrollment request on an unauthenticated connection.
        await firstAtSignConnection.initiateConnectionWithListener(
            firstAtSign, firstAtSignHost, firstAtSignPort);
        String enrollRequest =
            'enroll:request:{"appName":"test_app-${Uuid().v4().hashCode}","deviceName":"test_device","namespaces":{"filter_test":"rw"},"otp":"$otp","apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey" : "${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}';
        String enrollmentResponse =
            await firstAtSignConnection.sendRequestToServer(enrollRequest);
        enrollmentResponse = enrollmentResponse.replaceAll('data:', '');
        String enrollmentId = jsonDecode(enrollmentResponse)['enrollmentId'];
        enrollmentIds.add(enrollmentId.trim());
        await firstAtSignConnection.close();
      }
    });

    Map<String, dynamic> readServerResponseAndConvertToMap(String data) {
      data = data.replaceFirst('data:', '');
      return jsonDecode(data);
    }

    test('validate filtering of enrollment requests - case approved', () async {
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      await firstAtSignConnection.authenticateConnection();
      String enrollListApprovedCommand =
          'enroll:list:{"enrollmentStatusFilter":["approved"]}';

      // approve first and second enrollment request in enrollmentIds list
      await firstAtSignConnection.sendRequestToServer(
          'enroll:approve:{"enrollmentId":"${enrollmentIds[0]}","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap["encryptedDefaultEncPrivateKey"]}","encryptedDefaultSelfEncryptionKey": "${apkamEncryptedKeysMap["encryptedSelfEncKey"]}"}');
      await firstAtSignConnection.sendRequestToServer(
          'enroll:approve:{"enrollmentId":"${enrollmentIds[1]}","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap["encryptedDefaultEncPrivateKey"]}","encryptedDefaultSelfEncryptionKey": "${apkamEncryptedKeysMap["encryptedSelfEncKey"]}"}');

      // again, fetch approved enrollment requests
      Map<String, dynamic> enrollmentRequestsMap =
          readServerResponseAndConvertToMap(await firstAtSignConnection
              .sendRequestToServer(enrollListApprovedCommand));

      assert(enrollmentRequestsMap.toString().contains(enrollmentIds[0]));
      assert(enrollmentRequestsMap.toString().contains(enrollmentIds[1]));
      enrollmentRequestsMap.forEach((key, value) {
        expect(value['status'], 'approved');
      });
    });

    test('validate filtering of enrollment requests - case revoked', () async {
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      await firstAtSignConnection.authenticateConnection();
      String enrollListRevokedCommand =
          'enroll:list:{"enrollmentStatusFilter":["revoked"]}';

      // approve and then revoke third enrollment request in enrollmentIds list
      await firstAtSignConnection.sendRequestToServer(
          'enroll:approve:{"enrollmentId":"${enrollmentIds[2]}","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap["encryptedDefaultEncPrivateKey"]}","encryptedDefaultSelfEncryptionKey": "${apkamEncryptedKeysMap["encryptedSelfEncKey"]}"}');
      // authenticate using enrollmentIds[2]
      OutboundConnectionFactory tempSocketConnection =
          await OutboundConnectionFactory().initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      String authResponse = await tempSocketConnection.authenticateConnection(
          authType: AuthType.apkam, enrollmentId: enrollmentIds[2]);
      expect(authResponse.trim(), 'data:success');
      // get number of inbound connections before revoke
      var inboundConnectionResult =
          await firstAtSignConnection.sendRequestToServer("stats:1");
      inboundConnectionResult =
          inboundConnectionResult.replaceFirst('data:', '');
      int numberOfInboundConnectionsBeforeRevoke =
          int.parse(jsonDecode(inboundConnectionResult)[0]['value']);
      await firstAtSignConnection.sendRequestToServer(
          'enroll:revoke:{"enrollmentId":"${enrollmentIds[2]}"}');
      // get number of inbound connections after revoke
      inboundConnectionResult =
          await firstAtSignConnection.sendRequestToServer("stats:1");
      inboundConnectionResult =
          inboundConnectionResult.replaceFirst('data:', '');
      int numberOfInboundConnectionsAfterRevoke =
          int.parse(jsonDecode(inboundConnectionResult)[0]['value']);
      expect(numberOfInboundConnectionsAfterRevoke,
          numberOfInboundConnectionsBeforeRevoke - 1);

      // again, fetch revoked enrollment requests
      Map<String, dynamic> enrollmentRequestsMap =
          readServerResponseAndConvertToMap(await firstAtSignConnection
              .sendRequestToServer(enrollListRevokedCommand));
      assert(enrollmentRequestsMap.toString().contains(enrollmentIds[2]));
      enrollmentRequestsMap.forEach((key, value) {
        expect(value['status'], 'revoked');
      });
    });

    test('validate filtering of enrollment requests - case denied', () async {
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      await firstAtSignConnection.authenticateConnection();
      String enrollListDeniedCommand =
          'enroll:list:{"enrollmentStatusFilter":["denied"]}';

      // deny fourth and fifth enrollment request in enrollmentIds list
      await firstAtSignConnection.sendRequestToServer(
          'enroll:deny:{"enrollmentId":"${enrollmentIds[3]}"}');
      await firstAtSignConnection.sendRequestToServer(
          'enroll:deny:{"enrollmentId":"${enrollmentIds[4]}"}');

      // again, fetch denied enrollment requests
      Map<String, dynamic> enrollmentRequestsMap =
          readServerResponseAndConvertToMap(await firstAtSignConnection
              .sendRequestToServer(enrollListDeniedCommand));
      assert(enrollmentRequestsMap.toString().contains(enrollmentIds[3]));
      assert(enrollmentRequestsMap.toString().contains(enrollmentIds[4]));
      enrollmentRequestsMap.forEach((key, value) {
        expect(value['status'], 'denied');
      });
    });

    test('validate filtering of enrollment requests - case pending', () async {
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      await firstAtSignConnection.authenticateConnection();
      String enrollListDeniedCommand =
          'enroll:list:{"enrollmentStatusFilter":["pending"]}';
      // fetch pending enrollment requests
      Map<String, dynamic> enrollmentRequestsMap =
          readServerResponseAndConvertToMap(await firstAtSignConnection
              .sendRequestToServer(enrollListDeniedCommand));

      enrollmentRequestsMap.forEach((key, value) {
        expect(value['status'], 'pending');
      });
    });
  });

  group(
      'A group of tests validating client authorizations for enrollment operations',
      () {
    test(
        'A test to assert that an authenticated connection without namespace authorization cannot approve-deny requests for that namespace',
        () async {
      // Fetch OTP.
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      String otp = await firstAtSignConnection.sendRequestToServer('otp:get');
      otp = otp.replaceAll('data:', '');

      // Submit an enrollment request from an un-authenticated connection
      OutboundConnectionFactory unAuthenticatedConnection =
          OutboundConnectionFactory();
      await unAuthenticatedConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      String enrollmentResponse =
          await unAuthenticatedConnection.sendRequestToServer(
              'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw","__manage":"rw"},"otp":"$otp","apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey":"${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}');
      enrollmentResponse = enrollmentResponse.replaceAll('data:', '');
      String enrollmentId = jsonDecode(enrollmentResponse)['enrollmentId'];
      expect(jsonDecode(enrollmentResponse)['status'], 'pending');

      // Approve enrollment with a PKAM Authenticated connection
      String approveEnrollmentResponse =
          await firstAtSignConnection.sendRequestToServer(
              'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap['encryptedSelfEncKey']}"}');
      approveEnrollmentResponse =
          approveEnrollmentResponse.replaceAll('data:', '');
      expect(jsonDecode(approveEnrollmentResponse)['status'], 'approved');
      firstAtSignConnection.close();

      // Perform APKAM authentication with approved enrollment-id
      OutboundConnectionFactory enrollmentAuthenticatedConnection =
          OutboundConnectionFactory();
      await enrollmentAuthenticatedConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      String authResponse =
          await enrollmentAuthenticatedConnection.authenticateConnection(
              authType: AuthType.apkam, enrollmentId: enrollmentId);
      expect(authResponse, 'data:success');

      // Fetch OTP and submit another enrollment request
      otp = await enrollmentAuthenticatedConnection
          .sendRequestToServer('otp:get');
      otp = otp.replaceAll('data:', '');

      await unAuthenticatedConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      enrollmentResponse = await unAuthenticatedConnection.sendRequestToServer(
          'enroll:request:{"appName":"buzz","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"buzz":"rw"},"otp":"$otp","apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey":"${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}');
      enrollmentResponse = enrollmentResponse.replaceAll('data:', '');
      String secondEnrollmentId =
          jsonDecode(enrollmentResponse)['enrollmentId'];
      expect(jsonDecode(enrollmentResponse)['status'], 'pending');

      // Approve enrollment with APKAM authenticated connection
      var response = await enrollmentAuthenticatedConnection.sendRequestToServer(
          'enroll:approve:{"enrollmentId":"$secondEnrollmentId","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap['encryptedSelfEncKey']}"}');
      response = response.replaceAll('error:', '');
      expect(jsonDecode(response)['errorDescription'],
          'Internal server exception : Failed to approve enrollment id: $secondEnrollmentId. Client is not authorized for namespaces in the enrollment request');

      // Authenticate the connection again with APKAM
      await enrollmentAuthenticatedConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      authResponse =
          await enrollmentAuthenticatedConnection.authenticateConnection(
              authType: AuthType.apkam, enrollmentId: enrollmentId);
      expect(authResponse, 'data:success');
      // Deny enrollment with APKAM authenticated connection
      response = await enrollmentAuthenticatedConnection.sendRequestToServer(
          'enroll:deny:{"enrollmentId":"$secondEnrollmentId"}');
      response = response.replaceAll('error:', '');
      expect(jsonDecode(response)['errorDescription'],
          'Internal server exception : Failed to deny enrollment id: $secondEnrollmentId. Client is not authorized for namespaces in the enrollment request');
    });

    test(
        'A test to assert that an authenticated connection without namespace authorization cannot revoke request for that namespace',
        () async {
      // Fetch OTP.
      await firstAtSignConnection.authenticateConnection();
      String otp = await firstAtSignConnection.sendRequestToServer('otp:get');
      otp = otp.replaceAll('data:', '');

      // Submit an enrollment request from an un-authenticated connection
      OutboundConnectionFactory unAuthenticatedConnection =
          OutboundConnectionFactory();
      await unAuthenticatedConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      String enrollmentResponse =
          await unAuthenticatedConnection.sendRequestToServer(
              'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw","__manage":"rw"},"otp":"$otp","apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey":"${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}');
      enrollmentResponse = enrollmentResponse.replaceAll('data:', '');
      String enrollmentId = jsonDecode(enrollmentResponse)['enrollmentId'];
      expect(jsonDecode(enrollmentResponse)['status'], 'pending');

      // Approve enrollment with a PKAM Authenticated connection
      String approveEnrollmentResponse =
          await firstAtSignConnection.sendRequestToServer(
              'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap['encryptedSelfEncKey']}"}');
      approveEnrollmentResponse =
          approveEnrollmentResponse.replaceAll('data:', '');
      expect(jsonDecode(approveEnrollmentResponse)['status'], 'approved');

      // Perform APKAM authentication with approved enrollment-id
      OutboundConnectionFactory enrollmentAuthenticatedConnection =
          OutboundConnectionFactory();
      await enrollmentAuthenticatedConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      String authResponse =
          await enrollmentAuthenticatedConnection.authenticateConnection(
              authType: AuthType.apkam, enrollmentId: enrollmentId);
      expect(authResponse, 'data:success');

      // Fetch OTP and submit another enrollment request
      otp = await enrollmentAuthenticatedConnection
          .sendRequestToServer('otp:get');
      otp = otp.replaceAll('data:', '');

      await unAuthenticatedConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      enrollmentResponse = await unAuthenticatedConnection.sendRequestToServer(
          'enroll:request:{"appName":"buzz","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"buzz":"rw"},"otp":"$otp","apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey":"${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}');
      enrollmentResponse = enrollmentResponse.replaceAll('data:', '');
      enrollmentId = jsonDecode(enrollmentResponse)['enrollmentId'];
      expect(jsonDecode(enrollmentResponse)['status'], 'pending');

      // Approve enrollment with PKAM authenticated connection
      var response = await firstAtSignConnection.sendRequestToServer(
          'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap['encryptedSelfEncKey']}"}');
      response = response.replaceAll('data:', '');
      expect(jsonDecode(response)['status'], 'approved');

      // Revoke enrollment with APKAM authenticated connection
      response = await enrollmentAuthenticatedConnection.sendRequestToServer(
          'enroll:revoke:{"enrollmentId":"$enrollmentId"}');
      response = response.replaceAll('error:', '');
      expect(jsonDecode(response)['errorDescription'],
          'Internal server exception : Failed to revoke enrollment id: $enrollmentId. Client is not authorized for namespaces in the enrollment request');
    });
  });

  group('tests to validate enroll delete',() {
    test('negative test - delete an approved enrollment', () async {
      // Send an enrollment request on the authenticated connection
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      String enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}';
      var enrollmentResponse =
          await firstAtSignConnection.sendRequestToServer(enrollRequest);
      String enrollmentId = jsonDecode(
          enrollmentResponse.replaceAll('data:', ''))['enrollmentId'];
      // try to delete the above enrollment through a cram authenticated connection
      String deleteEnrollmentCommand =
          'enroll:delete:{"enrollmentId":"$enrollmentId"}';
      String revokeEnrollmentResponse = await firstAtSignConnection
          .sendRequestToServer(deleteEnrollmentCommand);
      revokeEnrollmentResponse =
          revokeEnrollmentResponse.replaceFirst('error:', '');
      Map jsonDecodedResponse = jsonDecode(revokeEnrollmentResponse);
      expect(jsonDecodedResponse['errorCode'], 'AT0011');
      expect(
          jsonDecodedResponse['errorDescription'],
          'Internal server exception : Failed to delete enrollment id: '
          '$enrollmentId | Cause: Cannot delete approved enrollments. '
          'Only denied enrollments can be deleted');
    });

    test('negative test - delete an pending enrollment', () async {
      // Send an enrollment request on the authenticated connection
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      String otp = await firstAtSignConnection.sendRequestToServer('otp:get');
      otp = otp.replaceFirst('data:', '');
      await firstAtSignConnection.close();

      // Submit an enrollment request from an un-authenticated connection
      OutboundConnectionFactory unAuthenticatedConnection =
          OutboundConnectionFactory();
      await unAuthenticatedConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      String enrollRequest =
          'enroll:request:{"appName":"wavi","otp":"$otp","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap['encryptedSelfEncKey']}","apkamPublicKey":"${at_demos.pkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey":"${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}';
      var enrollmentResponse =
          await unAuthenticatedConnection.sendRequestToServer(enrollRequest);
      Map jsonDecodedResponse =
          jsonDecode(enrollmentResponse.replaceAll('data:', ''));
      String? enrollmentId = jsonDecodedResponse['enrollmentId'];
      expect(jsonDecodedResponse['status'], 'pending');
      assert(enrollmentId != null);
      await unAuthenticatedConnection.close();

      // create a cram  authenticated connection and delete the pending enrollment
      OutboundConnectionFactory secondAuthenticatedConnection =
          OutboundConnectionFactory();
      await secondAuthenticatedConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      await secondAuthenticatedConnection.authenticateConnection(
          authType: AuthType.cram);
      String deleteEnrollmentCommand =
          'enroll:delete:{"enrollmentId":"$enrollmentId"}';
      String revokeEnrollmentResponse = await secondAuthenticatedConnection
          .sendRequestToServer(deleteEnrollmentCommand);
      revokeEnrollmentResponse =
          revokeEnrollmentResponse.replaceFirst('error:', '');
      jsonDecodedResponse = jsonDecode(revokeEnrollmentResponse);
      expect(jsonDecodedResponse['errorCode'], 'AT0011');
      expect(
          jsonDecodedResponse['errorDescription'],
          'Internal server exception : Failed to delete enrollment id: '
          '$enrollmentId | Cause: Cannot delete pending enrollments. '
          'Only denied enrollments can be deleted');
    });

    test('negative test - delete an revoked enrollment', () async {
      // Send an enrollment request on the authenticated connection
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      String otp = await firstAtSignConnection.sendRequestToServer('otp:get');
      otp = otp.replaceFirst('data:', '');
      await firstAtSignConnection.close();

      // Submit an enrollment request from an un-authenticated connection
      OutboundConnectionFactory unAuthenticatedConnection =
      OutboundConnectionFactory();
      await unAuthenticatedConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      String enrollRequest =
          'enroll:request:{"appName":"wavi","otp":"$otp","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap['encryptedSelfEncKey']}","apkamPublicKey":"${at_demos.pkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey":"${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}';
      var enrollmentResponse =
      await unAuthenticatedConnection.sendRequestToServer(enrollRequest);
      Map jsonDecodedResponse =
      jsonDecode(enrollmentResponse.replaceAll('data:', ''));
      String? enrollmentId = jsonDecodedResponse['enrollmentId'];
      expect(jsonDecodedResponse['status'], 'pending');
      assert(enrollmentId != null);
      await unAuthenticatedConnection.close();

      // create a new cram authenticated connection
      OutboundConnectionFactory secondAuthenticatedConnection =
      OutboundConnectionFactory();
      await secondAuthenticatedConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      await secondAuthenticatedConnection.authenticateConnection(
          authType: AuthType.cram);

      // approve then revoke the above created enrollment
      String approveCommand = 'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap['encryptedDefaultEncryptionPrivateKey']}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap['encryptedSelfEncKey']}","apkamPublicKey":"${at_demos.pkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey":"${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}';
      enrollmentResponse = await secondAuthenticatedConnection.sendRequestToServer(approveCommand);
      String revokeCommand = 'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
      enrollmentResponse = await secondAuthenticatedConnection.sendRequestToServer(revokeCommand);
      jsonDecodedResponse = jsonDecode(enrollmentResponse.replaceFirst('data:', ""));
      expect(jsonDecodedResponse['status'], 'revoked');

      // now try to delete the revoked enrollment
      String deleteEnrollmentCommand =
          'enroll:delete:{"enrollmentId":"$enrollmentId"}';
      String revokeEnrollmentResponse = await secondAuthenticatedConnection
          .sendRequestToServer(deleteEnrollmentCommand);
      revokeEnrollmentResponse =
          revokeEnrollmentResponse.replaceFirst('error:', '');
      jsonDecodedResponse = jsonDecode(revokeEnrollmentResponse);
      expect(jsonDecodedResponse['errorCode'], 'AT0011');
      expect(
          jsonDecodedResponse['errorDescription'],
          'Internal server exception : Failed to delete enrollment id: '
              '$enrollmentId | Cause: Cannot delete revoked enrollments. '
              'Only denied enrollments can be deleted');
    });

    test(
        'A test to verify delete operation cannot be performed on an unauthenticated connection',
        () async {
      // using a dummy enrollId as the enrollId will NOT be validated for this test
      String enrollmentId = '023409340293-2342397-23423984729';
      OutboundConnectionFactory socketConnection2 =
          await OutboundConnectionFactory().initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      String deleteEnrollmentCommand =
          'enroll:delete:{"enrollmentId":"$enrollmentId"}';
      String revokeEnrollmentResponse =
          await socketConnection2.sendRequestToServer(deleteEnrollmentCommand);
      expect(revokeEnrollmentResponse.trim(),
          'error:AT0401-Exception: Cannot delete enrollment without authentication');
    });
  }, skip: true);
}
