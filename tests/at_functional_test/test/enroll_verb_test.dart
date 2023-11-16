// ignore_for_file: prefer_typing_uninitialized_variables

import 'dart:convert';
import 'dart:io';

import 'package:at_demo_data/at_demo_data.dart' as at_demos;
import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'at_demo_data.dart';
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

Future<void> _connect() async {
  // socket connection for first atsign
  socketConnection1 =
      await secure_socket_connection(firstAtsignServer, firstAtsignPort);
  socket_listener(socketConnection1!);
}

Future<void> encryptKeys() async {
  aliceDefaultEncKey = at_demos.encryptionPrivateKeyMap[firstAtsign];
  aliceSelfEncKey = at_demos.aesKeyMap[firstAtsign];
  aliceApkamSymmetricKey = at_demos.apkamSymmetricKeyMap[firstAtsign];
  encryptedDefaultEncPrivateKey =
      EncryptionUtil.encryptValue(aliceDefaultEncKey!, aliceApkamSymmetricKey!);
  encryptedSelfEncKey =
      EncryptionUtil.encryptValue(aliceSelfEncKey!, aliceApkamSymmetricKey);
}

var firstAtsign =
    ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
var secondAtSign =
    ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'];

void main() {
  //Establish the client socket connection
  setUp(() async {
    await _connect();
    await encryptKeys();
  });

  group('A group of tests to verify apkam enroll requests', () {
    test('enroll request on CRAM authenticated connection', () async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      fromResponse = fromResponse.replaceAll('data:', '');
      var cramResponse = getDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'cram:$cramResponse');
      var cramResult = await read();
      expect(cramResult, 'data:success\n');

      // send an enroll request with the keys from the setEncryptionKeys method
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptedPrivateKey":"$encryptedDefaultEncPrivateKey","encryptedDefaultSelfEncryptionKey":"$encryptedSelfEncKey","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';

      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');
    });

    test(
        'denial of enroll request on an unauthenticated connection should throw an error',
        () async {
      var denyEnrollCommand =
          'enroll:deny:{"enrollmentId":"fa8e3cbf-b7d0-4674-a66d-d889914e2d02"}\n';
      await socket_writer(socketConnection1!, denyEnrollCommand);
      var denyEnrollResponse = await read();
      denyEnrollResponse = denyEnrollResponse.replaceFirst('error:', '');
      expect(
          denyEnrollResponse
              .contains('Cannot deny enrollment without authentication'),
          true);
    });

    test(
        'approval of an enroll request on an unauthenticated connection should throw an error',
        () async {
      var approveEnrollCommand =
          'enroll:approve:{"enrollmentId":"fa8e3cbf-b7d0-4674-a66d-d889914e2d02"}\n';
      await socket_writer(socketConnection1!, approveEnrollCommand);
      var approveEnrollResponse = await read();
      approveEnrollResponse = approveEnrollResponse.replaceFirst('error:', '');
      expect(
          approveEnrollResponse
              .contains('Cannot approve enrollment without authentication'),
          true);
    });

    test(
        'Approval of an invalid enrollmentId on an authenticated connection should throw an error',
        () async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      fromResponse = fromResponse.replaceAll('data:', '');
      var cramResponse = getDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'cram:$cramResponse');
      var cramResult = await read();
      expect(cramResult, 'data:success\n');
      var dummyEnrollmentId = 'feay891281821899090eye';
      var approveEnrollCommand =
          'enroll:approve:{"enrollmentId":"$dummyEnrollmentId"}\n';
      await socket_writer(socketConnection1!, approveEnrollCommand);
      var approveEnrollResponse = await read();
      approveEnrollResponse = approveEnrollResponse.replaceFirst('error:', '');
      expect(approveEnrollResponse,
          'AT0028:enrollment_id: $dummyEnrollmentId is expired or invalid\n');
    });

    test(
        'Denial of an invalid enrollmentId on an authenticated connection should throw an error',
        () async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      fromResponse = fromResponse.replaceAll('data:', '');
      var cramResponse = getDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'cram:$cramResponse');
      var cramResult = await read();
      expect(cramResult, 'data:success\n');
      var dummyEnrollmentId = 'feay891281821899090eye';
      var denyEnrollCommand =
          'enroll:deny:{"enrollmentId":"$dummyEnrollmentId"}\n';
      await socket_writer(socketConnection1!, denyEnrollCommand);
      var denyEnrollResponse = await read();
      denyEnrollResponse = denyEnrollResponse.replaceFirst('error:', '');
      expect(denyEnrollResponse,
          'AT0028:enrollment_id: $dummyEnrollmentId is expired or invalid\n');
    });

    test('enroll request on unauthenticated connection without otp', () async {
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      enrollResponse = enrollResponse.replaceFirst('error:', '');
      expect(
          enrollResponse.contains('invalid otp. Cannot process enroll request'),
          true);
    });

    test('enroll request on unauthenticated connection invalid otp', () async {
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"otp":"1234","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      enrollResponse = enrollResponse.replaceFirst('data:', '');
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
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      fromResponse = fromResponse.replaceAll('data:', '');
      var cramSecret = getDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'cram:$cramSecret');
      var cramResponse = await read();
      expect(cramResponse, 'data:success\n');

      // send an enroll request with the keys from the setEncryptionKeys method
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
      var apkamPublicKey = pkamPublicKeyMap[firstAtsign];
      var secondEnrollRequest =
          'enroll:request:{"appName":"buzz","deviceName":"pixel","namespaces":{"buzz":"rw"},"otp":"$otpResponse","apkamPublicKey":"$apkamPublicKey"}\n';
      await socket_writer(socketConnection2!, secondEnrollRequest);
      var secondEnrollResponse = await read();
      secondEnrollResponse = secondEnrollResponse.replaceFirst('data:', '');
      var enrollJson = jsonDecode(secondEnrollResponse);
      expect(enrollJson['enrollmentId'], isNotEmpty);
      expect(enrollJson['status'], 'pending');

      var secondEnrollId = enrollJson['enrollmentId'];
      // deny the enroll request from the first client
      var denyEnrollCommand =
          'enroll:deny:{"enrollmentId":"$secondEnrollId"}\n';
      await socket_writer(socketConnection1!, denyEnrollCommand);
      var denyEnrollResponse = await read();
      denyEnrollResponse = denyEnrollResponse.replaceFirst('data:', '');
      var approveJson = jsonDecode(denyEnrollResponse);
      expect(approveJson['status'], 'denied');
      expect(approveJson['enrollmentId'], secondEnrollId);
      // now do the apkam using the enrollment id
      await socket_writer(socketConnection2!, 'from:$firstAtsign');
      fromResponse = await read();
      fromResponse = fromResponse.replaceAll('data:', '');
      var pkamResponse = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollmentId:$secondEnrollId:$pkamResponse\n';
      await socket_writer(socketConnection2!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      print(apkamEnrollIdResponse);
      expect(apkamEnrollIdResponse,
          'error:AT0025:enrollment_id: $secondEnrollId is denied\n');
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
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      fromResponse = fromResponse.replaceAll('data:', '');
      var cramResponse = getDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'cram:$cramResponse');
      var cramResult = await read();
      expect(cramResult, 'data:success\n');

      // send an enroll request with the keys from the setEncryptionKeys method
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptedPrivateKey":"$encryptedDefaultEncPrivateKey","encryptedDefaultSelfEncryptionKey":"$encryptedSelfEncKey","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';

      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      var enrollmentId = enrollJsonMap['enrollmentId'];
      expect(enrollmentId, isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');

      // destroy the first connection
      socketConnection1!.close();

      // connect to the second client with the above enrollment ID
      socketConnection2 =
          await secure_socket_connection(firstAtsignServer, firstAtsignPort);
      socket_listener(socketConnection2!);
      await socket_writer(socketConnection2!, 'from:$firstAtsign');
      fromResponse = await read();
      fromResponse = fromResponse.replaceAll('data:', '');
      // now do the apkam using the enrollment id
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollmentId:$enrollmentId:$pkamDigest\n';
      await socket_writer(socketConnection2!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      expect(apkamEnrollIdResponse, 'data:success\n');

      // check if scan verb returns apkam namespace
      await socket_writer(socketConnection2!, 'scan\n');
      var scanResponse = await read();
      // assert that scan doesn't return key with __manage namespace
      expect(scanResponse.contains('__manage'), true);

      // enroll:list
      await socket_writer(socketConnection2!, 'enroll:list\n');
      var enrollListResponse = await read();
      // enrollment key to be checked
      var enrollmentKey = '$enrollmentId.new.enrollments.__manage$firstAtsign';
      expect(enrollListResponse.contains(enrollmentKey), true);

      // llookup of the enrollment key should fail
      await socket_writer(socketConnection2!, 'llookup:$enrollmentKey\n');
      var llookupResponse = await read();
      expect(
          llookupResponse.contains(
              'AT0009-UnAuthorized client in request : Enrollment Id: $enrollmentId is not authorized for local lookup operation on the key: $enrollmentKey'),
          true);

      // keys:get:self should return default self encryption key
      var selfKey = '$enrollmentId.default_self_enc_key.__manage$firstAtsign';
      await socket_writer(socketConnection2!, 'keys:get:self\n');
      var selfKeyResponse = await read();
      expect(selfKeyResponse.contains(selfKey), true);

      // keys:get:private should return private encryption key
      var privateKey =
          '$enrollmentId.default_enc_private_key.__manage$firstAtsign';
      await socket_writer(socketConnection2!, 'keys:get:private\n');
      var privateKeyResponse = await read();
      expect(privateKeyResponse.contains(privateKey), true);

      // keys:get:keyName should return the enrollment key with __manage namespace
      await socket_writer(socketConnection2!, 'keys:get:keyName:$selfKey\n');
      var selfKeyGetResponse = await read();
      expect(selfKeyGetResponse.contains('$encryptedSelfEncKey'), true);

      // keys:get:keyName should return the enrollment key with __manage namespace
      await socket_writer(socketConnection2!, 'keys:get:keyName:$privateKey\n');
      var privateKeyGetResponse = await read();
      expect(privateKeyGetResponse.contains('$encryptedDefaultEncPrivateKey'),
          true);
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
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      fromResponse = fromResponse.replaceAll('data:', '');
      var cramSecret = getDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'cram:$cramSecret');
      var cramResult = await read();
      expect(cramResult, 'data:success\n');

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

      // close the first connection
      socketConnection1!.close();

      // connect to the second client to do an apkam
      await socket_writer(socketConnection2!, 'from:$firstAtsign');
      fromResponse = await read();
      fromResponse = fromResponse.replaceAll('data:', '');
      // now do the apkam using the enrollment id
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollmentId:$secondEnrollId:$pkamDigest\n';
      await socket_writer(socketConnection2!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      expect(apkamEnrollIdResponse, 'data:success\n');

      // keys:get:self should return default self encryption key
      var selfKey = '$secondEnrollId.default_self_enc_key.__manage$firstAtsign';
      await socket_writer(socketConnection2!, 'keys:get:self\n');
      var selfKeyResponse = await read();
      expect(selfKeyResponse.contains(selfKey), true);

      // keys:get:private should return private encryption key
      var privateKey =
          '$secondEnrollId.default_enc_private_key.__manage$firstAtsign';
      await socket_writer(socketConnection2!, 'keys:get:private\n');
      var privateKeyResponse = await read();
      expect(privateKeyResponse.contains(privateKey), true);
    });

    test(
        'A test to verify pending enrollment is stored and written on to a monitor connection',
        () async {
      // Fetch notification from this timestamp
      var timeStamp = DateTime.now().toUtc().millisecondsSinceEpoch;
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      fromResponse = fromResponse.replaceAll('data:', '');
      var cramSecret = getDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'cram:$cramSecret');
      var cramResult = await read();
      expect(cramResult, 'data:success\n');
      // Get a TOTP
      var otpRequest = 'otp:get\n';
      await socket_writer(socketConnection1!, otpRequest);
      var otpResponse = await read();
      otpResponse = otpResponse.replaceFirst('data:', '');
      otpResponse = otpResponse.trim();
      socketConnection1?.close();
      // Connect to unauthenticated socket to send an enrollment request
      socketConnection2 =
          await secure_socket_connection(firstAtsignServer, firstAtsignPort);
      socket_listener(socketConnection2!);
      var secondEnrollRequest =
          'enroll:request:{"appName":"buzz","deviceName":"pixel","namespaces":{"buzz":"rw"},"otp":"$otpResponse","encryptedDefaultEncryptedPrivateKey":"$encryptedDefaultEncPrivateKey","encryptedDefaultSelfEncryptionKey":"$encryptedSelfEncKey","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(socketConnection2!, secondEnrollRequest);
      var secondEnrollResponse = await read();
      secondEnrollResponse = secondEnrollResponse.replaceFirst('data:', '');
      var enrollJson = jsonDecode(secondEnrollResponse);
      expect(enrollJson['enrollmentId'], isNotEmpty);
      expect(enrollJson['status'], 'pending');

      var monitorSocket =
          await secure_socket_connection(firstAtsignServer, firstAtsignPort);

      monitorSocket.listen(expectAsync1((data) {
        String serverResponse = utf8.decode(data);
        serverResponse = serverResponse.trim();
        // From response starts with "data:_"
        if (serverResponse.startsWith('data:_')) {
          serverResponse = serverResponse.replaceAll('data:', '');
          serverResponse =
              serverResponse.substring(0, serverResponse.indexOf('\n'));
          var cramSecret = getDigest(firstAtsign, serverResponse.trim());
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
          monitorSocket.close();
        }
        /* Setting count to 4 to wait until server returns 4 responses
      1. On creating a connection, server returns "@"
      2. On sending from request, server returns from challenge
      3. On sending a cram request, server returns "data:success"
      4. On sending monitor request, server returns enrollment request
        */
      }, count: 4));
      monitorSocket.write('from:${firstAtsign.toString().trim()}\n');
    });

    test('A test to verify enrolled client can do legacy pkam auth', () async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      fromResponse = fromResponse.replaceAll('data:', '');
      var cramResponse = getDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'cram:$cramResponse');
      var cramResult = await read();
      expect(cramResult, 'data:success\n');
      // send an enroll request with the keys from the setEncryptionKeys method
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptedPrivateKey":"$encryptedDefaultEncPrivateKey","encryptedDefaultSelfEncryptionKey":"$encryptedSelfEncKey","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      var enrollmentId = enrollJsonMap['enrollmentId'];
      expect(enrollmentId, isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');
      socketConnection1?.close();
      // PKAM Auth
      socketConnection1 =
          await secure_socket_connection(firstAtsignServer, firstAtsignPort);
      socket_listener(socketConnection1!);
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      fromResponse = await read();
      fromResponse = fromResponse.replaceAll('data:', '');
      var pkamResponse = generatePKAMDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'pkam:$pkamResponse');
      var pkamResult = await read();
      expect(pkamResult, 'data:success\n');
    });

    test('A test to verify pkam public key is stored in __pkams namespace',
        () async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      fromResponse = fromResponse.replaceAll('data:', '');
      var cramResponse = getDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'cram:$cramResponse');
      var cramResult = await read();
      expect(cramResult, 'data:success\n');
      // Get otp
      await socket_writer(socketConnection1!, 'otp:get');
      var otp = (await read()).replaceAll('data:', '').trim();
      // send an enroll request
      socketConnection2 =
          await secure_socket_connection(firstAtsignServer, firstAtsignPort);
      socket_listener(socketConnection2!);
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(socketConnection2!, enrollRequest);
      var enrollResponse = await read();
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      var enrollmentId = enrollJsonMap['enrollmentId'];
      expect(enrollmentId, isNotEmpty);
      expect(enrollJsonMap['status'], 'pending');
      // Approve enrollment
      String approveEnrollment =
          'enroll:approve:{"enrollmentId":"$enrollmentId"}';
      await socket_writer(socketConnection1!, approveEnrollment);
      var enrollmentResponse = await read();
      enrollmentResponse = enrollmentResponse.replaceAll('data:', '');
      expect(jsonDecode(enrollmentResponse)['status'], 'approved');
      await socket_writer(socketConnection1!,
          'llookup:public:wavi.pixel.pkam.__pkams.__public_keys@alice🛠');
      var llookupResponse = await read();
      llookupResponse = llookupResponse.replaceAll('data:', '');
      var apkamPublicKey = jsonDecode(llookupResponse)['apkamPublicKey'];
      expect(apkamPublicKey, pkamPublicKeyMap[firstAtsign]!);
    });

    group('A group of tests related to APKAM revoke operation', () {
      test('A test to verify enrollment revoke operation', () async {
        // Send an enrollment request on the authenticated connection
        await socket_writer(socketConnection1!, 'from:$firstAtsign');
        var fromResponse = await read();
        fromResponse = fromResponse.replaceAll('data:', '');
        String cramResponse = getDigest(firstAtsign, fromResponse);
        await socket_writer(socketConnection1!, 'cram:$cramResponse');
        var pkamResult = await read();
        expect(pkamResult, 'data:success\n');
        String enrollRequest =
            'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}';
        await socket_writer(socketConnection1!, enrollRequest);
        var enrollmentResponse = await read();
        String enrollmentId = jsonDecode(
            enrollmentResponse.replaceAll('data:', ''))['enrollmentId'];
        //Create a new connection to login using the APKAM
        socketConnection2 =
            await secure_socket_connection(firstAtsignServer, firstAtsignPort);
        socket_listener(socketConnection2!);
        await socket_writer(socketConnection2!, 'from:$firstAtsign');
        fromResponse = await read();
        fromResponse = fromResponse.replaceAll('data:', '');
        String pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
        String pkamCommand = 'pkam:enrollmentId:$enrollmentId:$pkamDigest';
        await socket_writer(socketConnection2!, pkamCommand);
        pkamResult = await read();
        expect(pkamResult, 'data:success\n');
        socketConnection2?.close();

        // Revoke the enrollment
        String revokeEnrollmentCommand =
            'enroll:revoke:{"enrollmentId":"$enrollmentId"}';
        await socket_writer(socketConnection1!, revokeEnrollmentCommand);
        var revokeEnrollmentResponse = await read();
        var revokeEnrollmentMap =
            jsonDecode(revokeEnrollmentResponse.replaceAll('data:', ''));
        expect(revokeEnrollmentMap['status'], 'revoked');
        expect(revokeEnrollmentMap['enrollmentId'], enrollmentId);

        socketConnection2 =
            await secure_socket_connection(firstAtsignServer, firstAtsignPort);
        socket_listener(socketConnection2!);
        await socket_writer(socketConnection2!, 'from:$firstAtsign');
        fromResponse = await read();
        fromResponse = fromResponse.replaceAll('data:', '');
        pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
        pkamCommand = 'pkam:enrollmentId:$enrollmentId:$pkamDigest';
        await socket_writer(socketConnection2!, pkamCommand);
        pkamResult = await read();
        socketConnection2?.close();
        print(pkamResult);
        assert(pkamResult.contains('enrollment_id: $enrollmentId is revoked'));
      });

      test(
          'A test to verify revoke operation cannot be performed on an unauthenticated connection',
          () async {
        // Send an enrollment request on the authenticated connection
        await socket_writer(socketConnection1!, 'from:$firstAtsign');
        var fromResponse = await read();
        fromResponse = fromResponse.replaceAll('data:', '');
        var cramResponse = getDigest(firstAtsign, fromResponse);
        await socket_writer(socketConnection1!, 'cram:$cramResponse');
        var pkamResult = await read();
        expect(pkamResult, 'data:success\n');
        String enrollRequest =
            'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}';
        await socket_writer(socketConnection1!, enrollRequest);
        var enrollmentResponse = await read();
        String enrollmentId = jsonDecode(
            enrollmentResponse.replaceAll('data:', ''))['enrollmentId'];

        socketConnection2 =
            await secure_socket_connection(firstAtsignServer, firstAtsignPort);
        socket_listener(socketConnection2!);
        String revokeEnrollmentCommand =
            'enroll:revoke:enrollmentid:$enrollmentId';
        await socket_writer(socketConnection2!, revokeEnrollmentCommand);
        var revokeEnrollmentResponse = await read();
        expect(revokeEnrollmentResponse.trim(),
            'error:AT0401-Exception: Cannot revoke enrollment without authentication');
      });
    });
  });

  group('A group of negative tests on enroll verb', () {
    late String enrollmentId;
    late String enrollmentResponse;
    setUp(() async {
      // Get TOTP from server
      String otp = await _getOTPFromServer(firstAtsign);
      await socketConnection1?.close();
      // Close the connection and create a new connection and send an enrollment request on an
      // unauthenticated connection.
      await _connect();
      String enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}';
      await socket_writer(socketConnection1!, enrollRequest);
      enrollmentResponse = await read();
      enrollmentResponse = enrollmentResponse.replaceAll('data:', '');
      enrollmentId = jsonDecode(enrollmentResponse)['enrollmentId'];
      socketConnection1?.close();
    });
    test(
        'A test to verify error is returned when pending enrollment is revoked',
        () async {
      // Revoke enrollment on an authenticate connection
      await _connect();
      await prepare(socketConnection1!, firstAtsign);
      await socket_writer(
          socketConnection1!, 'enroll:revoke:{"enrollmentId":"$enrollmentId"}');
      enrollmentResponse = (await read()).replaceAll('error:', '');
      expect(jsonDecode(enrollmentResponse)['errorDescription'],
          'Internal server exception : Cannot revoke a pending enrollment. Only approved enrollments can be revoked');
    });

    test(
        'A test to verify error is returned when denied enrollment is approved',
        () async {
      // Deny enrollment on an authenticate connection
      await _connect();
      await prepare(socketConnection1!, firstAtsign);
      await socket_writer(
          socketConnection1!, 'enroll:deny:{"enrollmentId":"$enrollmentId"}');
      enrollmentResponse = (await read()).replaceAll('data:', '');
      expect(jsonDecode(enrollmentResponse)['status'], 'denied');
      expect(jsonDecode(enrollmentResponse)['enrollmentId'], enrollmentId);
      // Approve enrollment
      await socket_writer(socketConnection1!,
          'enroll:approve:{"enrollmentId":"$enrollmentId"}');
      enrollmentResponse = (await read()).replaceAll('error:', '');
      expect(
          jsonDecode(enrollmentResponse)['errorDescription'],
          'Internal server exception : Cannot approve a denied enrollment. '
          'Only pending enrollments can be approved');
    });

    test('A test to verify error is returned when denied enrollment is revoked',
        () async {
      // Deny enrollment on an authenticate connection
      await _connect();
      await prepare(socketConnection1!, firstAtsign);
      await socket_writer(
          socketConnection1!, 'enroll:deny:{"enrollmentId":"$enrollmentId"}');
      enrollmentResponse = (await read()).replaceAll('data:', '');
      expect(jsonDecode(enrollmentResponse)['status'], 'denied');
      expect(jsonDecode(enrollmentResponse)['enrollmentId'], enrollmentId);
      // Revoke enrollment
      await socket_writer(
          socketConnection1!, 'enroll:revoke:{"enrollmentId":"$enrollmentId"}');
      enrollmentResponse = (await read()).replaceAll('error:', '');
      expect(
          jsonDecode(enrollmentResponse)['errorDescription'],
          'Internal server exception : Cannot revoke a denied enrollment. '
          'Only approved enrollments can be revoked');
    });

    test('A test to verify revoked enrollment cannot be approved', () async {
      // Approve enrollment
      await _connect();
      await prepare(socketConnection1!, firstAtsign);
      await socket_writer(socketConnection1!,
          'enroll:approve:{"enrollmentId":"$enrollmentId"}');
      enrollmentResponse = (await read()).replaceAll('data:', '');
      expect(jsonDecode(enrollmentResponse)['status'], 'approved');
      expect(jsonDecode(enrollmentResponse)['enrollmentId'], enrollmentId);
      // Revoke enrollment
      await socket_writer(
          socketConnection1!, 'enroll:revoke:{"enrollmentId":"$enrollmentId"}');
      enrollmentResponse = (await read()).replaceAll('data:', '');
      expect(jsonDecode(enrollmentResponse)['status'], 'revoked');
      expect(jsonDecode(enrollmentResponse)['enrollmentId'], enrollmentId);
      // Approve a revoked enrollment
      await socket_writer(socketConnection1!,
          'enroll:approve:{"enrollmentId":"$enrollmentId"}');
      enrollmentResponse = (await read()).replaceAll('error:', '');
      expect(
          jsonDecode(enrollmentResponse)['errorDescription'],
          'Internal server exception : Cannot approve a revoked enrollment. '
          'Only pending enrollments can be approved');
    });
  });

  group('A group of test related to Rate limiting enrollment requests', () {
    String otp = '';
    setUp(() async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      fromResponse = fromResponse.replaceAll('data:', '');
      var cramResponse = getDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'cram:$cramResponse');
      var cramResult = await read();
      expect(cramResult, 'data:success\n');
      await socket_writer(
          socketConnection1!, 'config:set:maxRequestsPerTimeFrame=1\n');
      var configResponse = await read();
      expect(configResponse.trim(), 'data:ok');
      await socket_writer(
          socketConnection1!, 'config:set:timeFrameInMills=100\n');
      configResponse = await read();
      expect(configResponse.trim(), 'data:ok');
    });

    test(
        'A test to verify exception is thrown when request exceed the configured limit',
        () async {
      SecureSocket unAuthenticatedConnection =
          await secure_socket_connection(firstAtsignServer, firstAtsignPort);
      socket_listener(unAuthenticatedConnection);
      await socket_writer(socketConnection1!, 'otp:get');
      otp = await read();
      otp = otp.replaceAll('data:', '').trim();
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(unAuthenticatedConnection, enrollRequest);
      var enrollmentResponse =
          jsonDecode((await read()).replaceAll('data:', ''));
      expect(enrollmentResponse['status'], 'pending');
      expect(enrollmentResponse['enrollmentId'], isNotNull);

      await socket_writer(socketConnection1!, 'otp:get');
      otp = await read();
      otp = otp.replaceAll('data:', '').trim();
      enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(unAuthenticatedConnection, enrollRequest);
      enrollmentResponse = await read()
        ..replaceAll('error:', '');
      expect(
          enrollmentResponse.contains(
              'Enrollment requests have exceeded the limit within the specified time frame'),
          true);
    });

    test('A test to verify request is successful after the time window',
        () async {
      SecureSocket unAuthenticatedConnection =
          await secure_socket_connection(firstAtsignServer, firstAtsignPort);
      socket_listener(unAuthenticatedConnection);

      await socket_writer(socketConnection1!, 'otp:get');
      otp = await read();
      otp = otp.replaceAll('data:', '').trim();
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(unAuthenticatedConnection, enrollRequest);
      var enrollmentResponse =
          jsonDecode((await read()).replaceAll('data:', ''));
      expect(enrollmentResponse['status'], 'pending');
      expect(enrollmentResponse['enrollmentId'], isNotNull);

      await socket_writer(socketConnection1!, 'otp:get');
      otp = await read();
      otp = otp.replaceAll('data:', '').trim();
      enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(unAuthenticatedConnection, enrollRequest);
      enrollmentResponse = await read()
        ..replaceAll('error:', '');
      expect(
          enrollmentResponse.contains(
              'Enrollment requests have exceeded the limit within the specified time frame'),
          true);
      await Future.delayed(Duration(milliseconds: 110));
      await socket_writer(unAuthenticatedConnection, enrollRequest);
      enrollmentResponse = jsonDecode((await read()).replaceAll('data:', ''));
      expect(enrollmentResponse['status'], 'pending');
      expect(enrollmentResponse['enrollmentId'], isNotNull);
    });

    test('A test to verify rate limit is per connection', () async {
      SecureSocket unAuthenticatedConnection =
          await secure_socket_connection(firstAtsignServer, firstAtsignPort);
      socket_listener(unAuthenticatedConnection);

      await socket_writer(socketConnection1!, 'otp:get');
      otp = await read();
      otp = otp.replaceAll('data:', '').trim();
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(unAuthenticatedConnection, enrollRequest);
      var enrollmentResponse =
          jsonDecode((await read()).replaceAll('data:', ''));
      expect(enrollmentResponse['status'], 'pending');
      expect(enrollmentResponse['enrollmentId'], isNotNull);

      await socket_writer(socketConnection1!, 'otp:get');
      otp = await read();
      otp = otp.replaceAll('data:', '').trim();
      enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(unAuthenticatedConnection, enrollRequest);
      enrollmentResponse = await read()
        ..replaceAll('error:', '');
      expect(
          enrollmentResponse.contains(
              'Enrollment requests have exceeded the limit within the specified time frame'),
          true);
      SecureSocket secondUnAuthenticatedConnection2 =
          await secure_socket_connection(firstAtsignServer, firstAtsignPort);
      socket_listener(secondUnAuthenticatedConnection2);

      await socket_writer(socketConnection1!, 'otp:get');
      otp = await read();
      otp = otp.replaceAll('data:', '').trim();
      enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(secondUnAuthenticatedConnection2, enrollRequest);
      enrollmentResponse = jsonDecode((await read()).replaceAll('data:', ''));
      expect(enrollmentResponse['status'], 'pending');
      expect(enrollmentResponse['enrollmentId'], isNotNull);
    });

    tearDown(() async {
      socket_writer(socketConnection1!, 'config:reset:maxRequestsAllowed');
      await read();
      socket_writer(socketConnection1!, 'config:reset:timeWindowInMills');
      await read();
    });
  });

  group('A group of tests related to fetching latest commit id', () {
    String enrollmentResponse;
    late String enrollmentId;
    setUp(() async {
      // Get TOTP from server
      String otp = await _getOTPFromServer(firstAtsign);
      await socketConnection1?.close();
      // Close the connection and create a new connection and send an enrollment request on an
      // unauthenticated connection.
      await _connect();
      String enrollRequest =
          'enroll:request:{"appName":"my-first-app","deviceName":"pixel","namespaces":{"wavi":"rw","buzz":"r"},"otp":"$otp","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}';
      await socket_writer(socketConnection1!, enrollRequest);
      enrollmentResponse = await read();
      enrollmentResponse = enrollmentResponse.replaceAll('data:', '');
      enrollmentId = jsonDecode(enrollmentResponse)['enrollmentId'];
      enrollmentId = enrollmentId.trim();
      socketConnection1?.close();
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
      String enrollRequest = 'enroll:approve:{"enrollmentId":"$enrollmentId"}';
      await _connect();
      await prepare(socketConnection1!, firstAtsign);
      socket_writer(socketConnection1!, enrollRequest);
      await read();
      socket_writer(socketConnection1!, 'stats:3');
      await read();

      socket_writer(socketConnection1!,
          'update:$secondAtSign:phone-$randomId.wavi$firstAtsign random-value');
      await read();
      socket_writer(socketConnection1!,
          'update:$secondAtSign:mobile-$randomId.buzz$firstAtsign random-value');
      String commitIdOfLastEnrolledKey =
          (await read()).replaceAll('data:', '').trim();
      print('CommitId of last enrolled key: $commitIdOfLastEnrolledKey');
      // Key which has un-enrolled namespace
      socket_writer(socketConnection1!,
          'update:$secondAtSign:contact-$randomId.atmosphere$firstAtsign random-value');
      await read();
      socket_writer(socketConnection1!, 'stats:3');
      await read();
      socketConnection1?.close();
      await _connect();
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      String response = (await read()).replaceAll('data:', '').trim();
      String digest = generatePKAMDigest(firstAtsign, response);
      await socket_writer(
          socketConnection1!, 'pkam:enrollmentId:$enrollmentId:$digest');
      response = (await read()).replaceAll('data:', '');
      await socket_writer(socketConnection1!, 'stats:3');
      String lastCommitIdAmongEnrolledNamespace =
          jsonDecode((await read()).replaceAll('data:', ''))[0]['value'];
      print('CommitId from the stats:3 verb: $lastCommitIdAmongEnrolledNamespace');
      expect(
          int.parse(lastCommitIdAmongEnrolledNamespace) >=
              int.parse(commitIdOfLastEnrolledKey),
          true);
    });
  });
}

Future<String> _getOTPFromServer(String atSign) async {
  await socket_writer(socketConnection1!, 'from:$atSign');
  var fromResponse = await read();
  fromResponse = fromResponse.replaceAll('data:', '');
  var pkamDigest = generatePKAMDigest(atSign, fromResponse);
  await socket_writer(socketConnection1!, 'pkam:$pkamDigest');
  // Calling read to remove the PKAM request from the queue
  await read();
  await socket_writer(socketConnection1!, 'otp:get');
  String otp = await read();
  otp = otp.replaceAll('data:', '').trim();
  return otp;
}
