// ignore_for_file: prefer_typing_uninitialized_variables

import 'dart:convert';
import 'dart:io';

import 'package:at_demo_data/at_demo_data.dart' as at_demos;
import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

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
      expect(enrollJsonMap['status'], 'success');
    });

    test('enroll request on unauthenticated connection without totp', () async {
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      enrollResponse = enrollResponse.replaceFirst('error:', '');
      expect(
          enrollResponse
              .contains('invalid totp. Cannot process enroll request'),
          true);
    });

    test('enroll request on unauthenticated connection invalid totp', () async {
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"totp":"1234","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      expect(
          enrollResponse
              .contains('invalid totp. Cannot process enroll request'),
          true);
    });

    // Purpose of the tests
    // 1. Do a pkam authentication
    // 2. Send an enroll request
    // 3 . Get an otp from the first client
    // 4. Send an enroll request with otp from the second client
    // 5. First client doesn't approve the enroll request
    // 6. Second client should get an exception as the enroll request is not approved
    test(
        'second enroll request using totp and client did not approved enrollment request',
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
          'enroll:request:{"appName":"buzz","deviceName":"pixel","namespaces":{"buzz":"rw"},"totp":"$totpResponse","apkamPublicKey":"$apkamPublicKey"}\n';
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
      expect(apkamEnrollIdResponse,
          'error:AT0401-Exception: enrollment id: $secondEnrollId is not approved\n');
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
      expect(enrollJsonMap['status'], 'success');

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
        'second enroll request using totp and client approves enrollment request',
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
      var secondEnrollRequest =
          'enroll:request:{"appName":"buzz","deviceName":"pixel","namespaces":{"buzz":"rw"},"totp":"$totpResponse","encryptedDefaultEncryptedPrivateKey":"$encryptedDefaultEncPrivateKey","encryptedDefaultSelfEncryptionKey":"$encryptedSelfEncKey","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
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
      var totpRequest = 'totp:get\n';
      await socket_writer(socketConnection1!, totpRequest);
      var totpResponse = await read();
      totpResponse = totpResponse.replaceFirst('data:', '');
      totpResponse = totpResponse.trim();
      socketConnection1?.close();
      // Connect to unauthenticated socket to send an enrollment request
      socketConnection2 =
          await secure_socket_connection(firstAtsignServer, firstAtsignPort);
      socket_listener(socketConnection2!);
      var secondEnrollRequest =
          'enroll:request:{"appName":"buzz","deviceName":"pixel","namespaces":{"buzz":"rw"},"totp":"$totpResponse","encryptedDefaultEncryptedPrivateKey":"$encryptedDefaultEncPrivateKey","encryptedDefaultSelfEncryptionKey":"$encryptedSelfEncKey","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
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
      expect(enrollJsonMap['status'], 'success');
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
      // Get totp
      await socket_writer(socketConnection1!, 'totp:get');
      var totp = (await read()).replaceAll('data:', '').trim();
      // send an enroll request
      socketConnection2 =
          await secure_socket_connection(firstAtsignServer, firstAtsignPort);
      socket_listener(socketConnection2!);
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"totp":"$totp","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
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
        expect(pkamResult.contains('$enrollmentId is not approved'), true);
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
}
