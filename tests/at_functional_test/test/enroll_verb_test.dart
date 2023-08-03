import 'dart:convert';
import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'at_demo_data.dart';
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

  group('A group of tests to verify apkam enroll requests', () {
    test('enroll request on CRAM authenticated connection', () async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      fromResponse = fromResponse.replaceAll('data:', '');
      var cramResponse = getDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'cram:$cramResponse');
      var cramResult = await read();
      expect(cramResult, 'data:success\n');
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
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
    //  3 . Get an otp from the first client
    //  4. Send an enroll request with otp from the second client
    //  5. First client doesn't approve the enroll request
    //  6. Second client should get an exception as the enroll request is not approved
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
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
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
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
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
      // connect to the first client to approve the enroll request
      await socket_writer(socketConnection1!,
          'enroll:approve:{"enrollmentId":"$secondEnrollId"}\n');
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
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollmentId:$secondEnrollId:$pkamDigest\n';
      await socket_writer(socketConnection2!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      expect(apkamEnrollIdResponse, 'data:success\n');
    });
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
}
