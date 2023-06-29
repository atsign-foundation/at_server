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
    test('enroll request on authenticated connection', () async {
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
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'success');
    });

    test('enroll request on unauthenticated connection without totp', () async {
      var enrollRequest =
          'enroll:request:appName:wavi:deviceName:pixel:namespaces:[wavi,rw]:apkamPublicKey:${pkamPublicKeyMap[firstAtsign]!}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['status'], 'exception');
      expect(enrollJsonMap['reason'],
          'Exception: invalid totp. Cannot process enroll request');
    });

    test('enroll request on unauthenticated connection invalid totp', () async {
      var enrollRequest =
          'enroll:request:appName:wavi:deviceName:pixel:namespaces:[wavi,rw]:totp:1234:apkamPublicKey:${pkamPublicKeyMap[firstAtsign]!}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['status'], 'exception');
      expect(enrollJsonMap['reason'],
          'Exception: invalid totp. Cannot process enroll request');
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
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'success');

      var totpRequest = 'totp:get\n';
      await socket_writer(socketConnection1!, totpRequest);
      var totpResponse = await read();
      totpResponse = totpResponse.replaceFirst('data:', '');
      print(totpResponse);
      totpResponse = totpResponse.trim();

      // connect to the second client
      socketConnection2 =
          await secure_socket_connection(firstAtsignServer, firstAtsignPort);
      socket_listener(socketConnection2!);

      //send second enroll request with totp
      var apkamPublicKey = pkamPublicKeyMap[firstAtsign];
      var secondEnrollRequest =
          'enroll:request:appName:buzz:deviceName:pixel:namespaces:[buzz,rw]:totp:$totpResponse:apkamPublicKey:$apkamPublicKey\n';
      print(secondEnrollRequest);
      await socket_writer(socketConnection2!, secondEnrollRequest);

      var secondEnrollResponse = await read();
      print(secondEnrollResponse);
      secondEnrollResponse = secondEnrollResponse.replaceFirst('data:', '');
      var enrollJson = jsonDecode(secondEnrollResponse);
      expect(enrollJson['enrollmentId'], isNotEmpty);
      expect(enrollJson['status'], 'pending');

      var secondEnrollId = enrollJson['enrollmentId'];

      // deny the enroll request from the first client
      var denyEnrollCommand = 'enroll:deny:enrollmentId:$secondEnrollId\n';
      await socket_writer(socketConnection1!, denyEnrollCommand);
      var denyEnrollResponse = await read();
      print(denyEnrollResponse);
      denyEnrollResponse = denyEnrollResponse.replaceFirst('data:', '');
      var approveJson = jsonDecode(denyEnrollResponse);
      expect(approveJson['status'], 'denied');
      expect(approveJson['enrollmentId'], secondEnrollId);

      // now do the apkam using the enrollment id
      await socket_writer(socketConnection2!, 'from:$firstAtsign');
      fromResponse = await read();
      fromResponse = fromResponse.replaceAll('data:', '');
      pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollApprovalId:$secondEnrollId:$pkamDigest\n';

      await socket_writer(socketConnection2!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      print(apkamEnrollIdResponse);
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
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'success');

      var totpRequest = 'totp:get\n';
      await socket_writer(socketConnection1!, totpRequest);
      var totpResponse = await read();
      totpResponse = totpResponse.replaceFirst('data:', '');
      print(totpResponse);
      totpResponse = totpResponse.trim();

      // connect to the second client
      socketConnection2 =
          await secure_socket_connection(firstAtsignServer, firstAtsignPort);
      socket_listener(socketConnection2!);
      //send second enroll request with totp
      var apkamPublicKey = pkamPublicKeyMap[firstAtsign];
      var secondEnrollRequest =
          'enroll:request:appName:buzz:deviceName:pixel:namespaces:[buzz,rw]:totp:$totpResponse:apkamPublicKey:$apkamPublicKey\n';
      print(secondEnrollRequest);
      await socket_writer(socketConnection2!, secondEnrollRequest);

      var secondEnrollResponse = await read();
      print(secondEnrollResponse);
      secondEnrollResponse = secondEnrollResponse.replaceFirst('data:', '');
      var enrollJson = jsonDecode(secondEnrollResponse);
      expect(enrollJson['enrollmentId'], isNotEmpty);
      expect(enrollJson['status'], 'pending');
      var secondEnrollId = enrollJson['enrollmentId'];

      // connect to the first client to approve the enroll request
      await socket_writer(
          socketConnection1!, 'enroll:approve:enrollmentId:$secondEnrollId\n');
      var approveResponse = await read();
      print(approveResponse);
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
    });

    // Purpose of the tests
    //  1. Authenticate and send the enroll request for wavi namespace
    //  2. pkam using the enroll id
    //  3. Create a public key with atmosphere namespace
    //  4. Assert that key with atmosphere namespace throws an exception
    test(
        'enroll request on authenticated connection for wavi namespace and creating a atmosphere key should fail',
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
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'success');

      var enrollmentId = enrollJsonMap['enrollmentId'];

      // now do the apkam using the enrollment id
      pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollApprovalId:$enrollmentId:$pkamDigest\n';

      await socket_writer(socketConnection1!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      print(apkamEnrollIdResponse);
      expect(apkamEnrollIdResponse, 'data:success\n');

      await socket_writer(socketConnection1!,
          'update:public:twitter.atmosphere$firstAtsign twitterid');
      var updateResponse = await read();
      print(updateResponse);
      expect(
          updateResponse.contains(
              'error:AT0009-UnAuthorized client in request : Enrollment Id: $enrollmentId is not authorized for update operation'),
          true);
    });

    // Purpose of the tests
    //  1. Authenticate and send the enroll request for wavi namespace
    //  2. pkam using the enroll id
    //  3. Create a public key with wavi namespace
    //  4. Assert that wavi key is created without an exception
    test(
        'enroll request on authenticated connection for wavi namespace and creating a wavi key',
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
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'success');

      var enrollmentId = enrollJsonMap['enrollmentId'];

      // now do the apkam using the enrollment id
      pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollApprovalId:$enrollmentId:$pkamDigest\n';

      await socket_writer(socketConnection1!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      expect(apkamEnrollIdResponse, 'data:success\n');

      await socket_writer(socketConnection1!,
          'update:public:lastname.wavi$firstAtsign twitterid');
      var updateResponse = await read();
      print(updateResponse);
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));
    });

    // Purpose of the tests
    // Prerequisite - create a atmosphere key
    //  1. Authenticate and send the enroll request for wavi namespace
    //  2. pkam using the enroll id
    //  3. Do a llookup for the atmosphere key
    //  4. Assert that the llookup throws an exception
    test(
        'enroll request on authenticated connection for wavi namespace and llookup for a atmosphere key',
        () async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      print('from verb response : $fromResponse');
      fromResponse = fromResponse.replaceAll('data:', '');
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'pkam:$pkamDigest');
      var pkamResult = await read();
      expect(pkamResult, 'data:success\n');

      // Before creating a enroll request with wavi namespace
      // create a atmosphere key
      String atmosphereKey = 'firstcontact.atmosphere$firstAtsign';
      await socket_writer(
          socketConnection1!, 'update:$atmosphereKey atmospherevalue');
      var updateResponse = await read();
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));

      var enrollRequest =
          'enroll:request:appName:wavi:deviceName:pixel:namespaces:[wavi,rw]:apkamPublicKey:${pkamPublicKeyMap[firstAtsign]!}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'success');

      var enrollmentId = enrollJsonMap['enrollmentId'];

      // now do the apkam using the enrollment id
      pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollApprovalId:$enrollmentId:$pkamDigest\n';

      await socket_writer(socketConnection1!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      expect(apkamEnrollIdResponse, 'data:success\n');

      await socket_writer(socketConnection1!, 'llookup:$atmosphereKey');
      var llookupResponse = await read();
      print(llookupResponse);
      expect(llookupResponse,
          'error:AT0009-UnAuthorized client in request : Enrollment Id: $enrollmentId is not authorized for local lookup operation\n');
    });

    // Purpose of the tests
    // Prerequisite - create a public atmosphere key
    //  1. Authenticate and send the enroll request for wavi namespace
    //  2. pkam using the enroll id
    //  3. Do a llookup for the atmosphere key
    //  4. Assert that the llookup returns a value without an exception
    test(
        'enroll request on authenticated connection for wavi namespace and llookup for a atmosphere key',
        () async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      print('from verb response : $fromResponse');
      fromResponse = fromResponse.replaceAll('data:', '');
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'pkam:$pkamDigest');
      var pkamResult = await read();
      expect(pkamResult, 'data:success\n');

      // Before creating a enroll request with wavi namespace
      // create a atmosphere key
      String atmosphereKey = 'public:secondcontact.atmosphere$firstAtsign';
      await socket_writer(
          socketConnection1!, 'update:$atmosphereKey atmospherevalue');
      var updateResponse = await read();
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));

      var enrollRequest =
          'enroll:request:appName:wavi:deviceName:pixel:namespaces:[wavi,rw]:apkamPublicKey:${pkamPublicKeyMap[firstAtsign]!}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'success');

      var enrollmentId = enrollJsonMap['enrollmentId'];

      // now do the apkam using the enrollment id
      pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollApprovalId:$enrollmentId:$pkamDigest\n';

      await socket_writer(socketConnection1!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      expect(apkamEnrollIdResponse, 'data:success\n');

      await socket_writer(socketConnection1!, 'llookup:$atmosphereKey');
      var llookupResponse = await read();
      print(llookupResponse);
      expect(llookupResponse, 'data:atmospherevalue\n');
    });

    // Purpose of the tests
    // Prerequisite - create a wavi key
    //  1. Authenticate and send the enroll request for wavi namespace
    //  2. pkam using the enroll id
    //  4. Do a llookup for the wavi key
    //  5. Assert that the llookup returns correct value and does not throw an exception
    test(
        'enroll request on authenticated connection for wavi namespace and llookup for a wavi key',
        () async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      print('from verb response : $fromResponse');
      fromResponse = fromResponse.replaceAll('data:', '');
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'pkam:$pkamDigest');
      var pkamResult = await read();
      expect(pkamResult, 'data:success\n');

      // Before creating a enroll request with wavi namespace
      // create a atmosphere key
      String waviKey = 'firstname.wavi$firstAtsign';
      String waviValue = 'wavivalue';
      await socket_writer(socketConnection1!, 'update:$waviKey $waviValue');
      var updateResponse = await read();
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));

      var enrollRequest =
          'enroll:request:appName:wavi:deviceName:pixel:namespaces:[wavi,rw]:apkamPublicKey:${pkamPublicKeyMap[firstAtsign]!}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'success');

      var enrollmentId = enrollJsonMap['enrollmentId'];

      // now do the apkam using the enrollment id
      pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollApprovalId:$enrollmentId:$pkamDigest\n';

      await socket_writer(socketConnection1!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      expect(apkamEnrollIdResponse, 'data:success\n');

      await socket_writer(socketConnection1!, 'llookup:$waviKey');
      var llookupResponse = await read();
      print(llookupResponse);
      expect(llookupResponse, 'data:$waviValue\n');
    });

    // Purpose of the tests
    //  1. Authenticate and send the enroll request for wavi namespace
    //  2. pkam using the enroll id
    //  3. Already there is a atmosphere key in server
    //  4. Do a scan
    //  5. Assert that the scan verb doesn't return the atmosphere key
    test(
        'enroll request on authenticated connection for wavi namespace and scan should not display atmosphere key',
        () async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      print('from verb response : $fromResponse');
      fromResponse = fromResponse.replaceAll('data:', '');
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'pkam:$pkamDigest');
      var pkamResult = await read();
      expect(pkamResult, 'data:success\n');

      // Before creating a enroll request with wavi namespace
      // create a atmosphere key
      String atmosphereKey = 'filename.atmosphere$firstAtsign';
      await socket_writer(
          socketConnection1!, 'update:$atmosphereKey atmospherevalue');
      var updateResponse = await read();
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));

      // enroll request with wavi namespace
      var enrollRequest =
          'enroll:request:appName:wavi:deviceName:pixel:namespaces:[wavi,rw]:apkamPublicKey:${pkamPublicKeyMap[firstAtsign]!}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'success');

      var enrollmentId = enrollJsonMap['enrollmentId'];

      // now do the apkam using the enrollment id
      pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollApprovalId:$enrollmentId:$pkamDigest\n';

      await socket_writer(socketConnection1!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      expect(apkamEnrollIdResponse, 'data:success\n');

      await socket_writer(socketConnection1!, 'scan');
      var scanResponse = await read();
      print(scanResponse);
      expect(!(scanResponse.contains(atmosphereKey)), true);
    });

    // Purpose of the tests
    //  Pre-requisite - create a wavi key
    //  1. Authenticate and send the enroll request for wavi namespace
    //  2. pkam using the enroll id
    //  4. Do a scan
    //  5. Assert that the scan verb returns the wavi key
    test(
        'enroll request on authenticated connection for wavi namespace and scan should display wavi key',
        () async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      print('from verb response : $fromResponse');
      fromResponse = fromResponse.replaceAll('data:', '');
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'pkam:$pkamDigest');
      var pkamResult = await read();
      expect(pkamResult, 'data:success\n');

      // Before creating a enroll request with wavi namespace
      // create a atmosphere key
      String waviKey = 'lastname.wavi$firstAtsign';
      String value = 'checkingValue';
      await socket_writer(socketConnection1!, 'update:$waviKey $value');
      var updateResponse = await read();
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));

      // enroll request with wavi namespace
      var enrollRequest =
          'enroll:request:appName:wavi:deviceName:pixel:namespaces:[wavi,rw]:apkamPublicKey:${pkamPublicKeyMap[firstAtsign]!}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'success');

      var enrollmentId = enrollJsonMap['enrollmentId'];

      // now do the apkam using the enrollment id
      pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollApprovalId:$enrollmentId:$pkamDigest\n';

      await socket_writer(socketConnection1!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      expect(apkamEnrollIdResponse, 'data:success\n');

      await socket_writer(socketConnection1!, 'scan');
      var scanResponse = await read();
      print(scanResponse);
      expect((scanResponse.contains(waviKey)), true);
    });

    // Purpose of the tests
    //  Pre-requisite - create a public atmosphere key
    //  1. Authenticate and send the enroll request for wavi namespace
    //  2. pkam using the enroll id
    //  4. Do a scan
    //  5. Assert that the scan verb returns the public atmosphere key
    test(
        'enroll request on authenticated connection for wavi namespace and scan should display the public atmosphere key',
        () async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      print('from verb response : $fromResponse');
      fromResponse = fromResponse.replaceAll('data:', '');
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'pkam:$pkamDigest');
      var pkamResult = await read();
      expect(pkamResult, 'data:success\n');

      // Before creating a enroll request with wavi namespace
      // create a atmosphere key
      String atmosphereKey = 'group.atmosphere$firstAtsign';
      String value = 'checkingValue';
      await socket_writer(
          socketConnection1!, 'update:public:$atmosphereKey $value');
      var updateResponse = await read();
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));

      // enroll request with wavi namespace
      var enrollRequest =
          'enroll:request:appName:wavi:deviceName:pixel:namespaces:[wavi,rw]:apkamPublicKey:${pkamPublicKeyMap[firstAtsign]!}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'success');

      var enrollmentId = enrollJsonMap['enrollmentId'];

      // now do the apkam using the enrollment id
      pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollApprovalId:$enrollmentId:$pkamDigest\n';

      await socket_writer(socketConnection1!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      expect(apkamEnrollIdResponse, 'data:success\n');

      await socket_writer(socketConnection1!, 'scan');
      var scanResponse = await read();
      print(scanResponse);
      expect((scanResponse.contains('public:$atmosphereKey')), true);
    });

    // Purpose of the tests
    //  Pre-requisite - create a wavi key
    //  1. Authenticate and send the enroll request for wavi namespace
    //  2. pkam using the enroll id
    //  3. Delete the created wavi key
    //  4. Assert that wavi key is deleted without an exception
    test(
        'enroll request on authenticated connection for wavi namespace and delete a wavi key',
        () async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      print('from verb response : $fromResponse');
      fromResponse = fromResponse.replaceAll('data:', '');
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'pkam:$pkamDigest');
      var pkamResult = await read();
      expect(pkamResult, 'data:success\n');

      // create a wavi key
      String waviKey = 'public:email.wavi$firstAtsign';
      await socket_writer(socketConnection1!, 'update:$waviKey twitterid');
      var updateResponse = await read();
      print(updateResponse);
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));

      // enroll request with wavi namespace
      var enrollRequest =
          'enroll:request:appName:wavi:deviceName:pixel:namespaces:[wavi,rw]:apkamPublicKey:${pkamPublicKeyMap[firstAtsign]!}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'success');

      var enrollmentId = enrollJsonMap['enrollmentId'];

      // now do the apkam using the enrollment id
      pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollApprovalId:$enrollmentId:$pkamDigest\n';

      await socket_writer(socketConnection1!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      expect(apkamEnrollIdResponse, 'data:success\n');

      // delete the wavi key
      await socket_writer(socketConnection1!, 'delete:$waviKey');
      var deleteResponse = await read();
      print(deleteResponse);
      assert((!deleteResponse.contains('Invalid syntax')) &&
          (!deleteResponse.contains('null')));
    });

    // Purpose of the tests
    //  Pre-requisite - create a atmosphere key
    //  1. Authenticate and send the enroll request for wavi namespace
    //  2. pkam using the enroll id
    //  3. Delete the created atmosphere key
    //  4. Assert that deletion of the created key throws an exception
    test(
        'enroll request on authenticated connection for wavi namespace and delete a atmosphere key',
        () async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      print('from verb response : $fromResponse');
      fromResponse = fromResponse.replaceAll('data:', '');
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'pkam:$pkamDigest');
      var pkamResult = await read();
      expect(pkamResult, 'data:success\n');

      // create a wavi key
      String atmosphereKey = 'files.atmosphere$firstAtsign';
      await socket_writer(
          socketConnection1!, 'update:$atmosphereKey atmospherevalue');
      var updateResponse = await read();
      print(updateResponse);
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));

      // enroll request with wavi namespace
      var enrollRequest =
          'enroll:request:appName:wavi:deviceName:pixel:namespaces:[wavi,rw]:apkamPublicKey:${pkamPublicKeyMap[firstAtsign]!}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'success');

      var enrollmentId = enrollJsonMap['enrollmentId'];

      // now do the apkam using the enrollment id
      pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollApprovalId:$enrollmentId:$pkamDigest\n';

      await socket_writer(socketConnection1!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      expect(apkamEnrollIdResponse, 'data:success\n');

      // delete the wavi key
      await socket_writer(socketConnection1!, 'delete:$atmosphereKey');
      var deleteResponse = await read();
      print(deleteResponse);
      expect(deleteResponse,
          'error:AT0009-UnAuthorized client in request : Enrollment Id: $enrollmentId is not authorized for delete operation\n');
    });

    tearDown(() {
      //Closing the socket connection
      clear();
      socketConnection1!.destroy();
    });
  });
}
