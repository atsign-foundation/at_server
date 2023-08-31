import 'dart:convert';
import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';
import 'package:at_demo_data/at_demo_data.dart' as at_demos;

import 'at_demo_data.dart';
import 'encryption_util.dart';
import 'functional_test_commons.dart';
import 'pkam_utils.dart';

Socket? socketConnection1;
Socket? socketConnection2;
var firstAtsignServer =
    ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
var firstAtsignPort =
    ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

var aliceDefaultEncKey;
var aliceSelfEncKey;
var aliceApkamSymmetricKey;
var encryptedDefaultEncPrivateKey;
var encryptedSelfEncKey;

Future<void> _connect() async {
  // socket connection for first atsign
  socketConnection1 =
      await secure_socket_connection(firstAtsignServer, firstAtsignPort);
  socket_listener(socketConnection1!);
}

Future<void> encryptKeys() async {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  aliceDefaultEncKey = at_demos.encryptionPrivateKeyMap[firstAtsign];
  aliceSelfEncKey = at_demos.aesKeyMap[firstAtsign];
  aliceApkamSymmetricKey = at_demos.apkamSymmetricKeyMap[firstAtsign];
  encryptedDefaultEncPrivateKey =
      EncryptionUtil.encryptValue(aliceDefaultEncKey!, aliceApkamSymmetricKey!);
  encryptedSelfEncKey =
      EncryptionUtil.encryptValue(aliceSelfEncKey!, aliceApkamSymmetricKey);
}

void main() {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];

  //Establish the client socket connection
  setUp(() async {
    await _connect();
  });

  group('A group of tests to verify apkam enroll namespace access', () {
    //  1. Cram authenticate and send the enroll request for wavi namespace
    //  2. pkam using the enroll id
    //  3. Create a public key with atmosphere namespace
    //  4. Assert update and llookup can be performed on  atmosphere namespace since cram auth connection gets access to *:rw
    test(
        'enroll request on cram authenticated connection for wavi namespace and create a key in atmosphere namespace',
        () async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      print('from verb response : $fromResponse');
      fromResponse = fromResponse.replaceAll('data:', '');
      var cramDigest = getDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'cram:$cramDigest');
      var cramResult = await read();
      expect(cramResult, 'data:success\n');
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');

      var enrollmentId = enrollJsonMap['enrollmentId'];

      // now do the apkam using the enrollment id
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollmentId:$enrollmentId:$pkamDigest\n';

      await socket_writer(socketConnection1!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      print(apkamEnrollIdResponse);
      expect(apkamEnrollIdResponse, 'data:success\n');

      await socket_writer(socketConnection1!,
          'update:twitter.atmosphere$firstAtsign twitterid');
      var updateResponse = await read();
      expect(
          updateResponse.startsWith('data:') &&
              (!updateResponse.contains('Invalid syntax')) &&
              (!updateResponse.contains('null')),
          true);
      await socket_writer(
          socketConnection1!, 'llookup:twitter.atmosphere$firstAtsign');
      var llookupResponse = await read();
      expect(llookupResponse, 'data:twitterid\n');
    });

    //  1. Cram authenticate and send the enroll request for wavi namespace
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
      var cramDigest = getDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'cram:$cramDigest');
      var cramResult = await read();
      expect(cramResult, 'data:success\n');
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');

      var enrollmentId = enrollJsonMap['enrollmentId'];

      // now do the apkam using the enrollment id
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollmentId:$enrollmentId:$pkamDigest\n';

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

    // Prerequisite - create a atmosphere key
    //  1. Cram authenticate and send the enroll request for wavi namespace
    //  2. pkam using the enroll id
    //  3. Do a llookup for a self atmosphere key
    //  4. Llookup should be successful since the enrollment gets access to *:rw
    test(
        'enroll request on authenticated connection for wavi namespace and llookup for a self atmosphere key',
        () async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      print('from verb response : $fromResponse');
      fromResponse = fromResponse.replaceAll('data:', '');
      var cramDigest = getDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'cram:$cramDigest');
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
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');

      var enrollmentId = enrollJsonMap['enrollmentId'];

      // now do the apkam using the enrollment id
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollmentId:$enrollmentId:$pkamDigest\n';

      await socket_writer(socketConnection1!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      expect(apkamEnrollIdResponse, 'data:success\n');

      await socket_writer(socketConnection1!, 'llookup:$atmosphereKey');
      var llookupResponse = await read();
      expect(llookupResponse, 'data:atmospherevalue\n');
    });

    // Prerequisite - create a public atmosphere key
    //  1. Authenticate and send the enroll request for wavi namespace
    //  2. pkam using the enroll id
    //  3. Do a llookup for a public atmosphere key
    //  4. Assert that the llookup returns a value without an exception
    test(
        'enroll request on authenticated connection for wavi namespace and llookup for a public atmosphere key',
        () async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      print('from verb response : $fromResponse');
      fromResponse = fromResponse.replaceAll('data:', '');
      var cramDigest = getDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'cram:$cramDigest');
      var cramResult = await read();
      expect(cramResult, 'data:success\n');

      // Before creating a enroll request with wavi namespace
      // create a atmosphere key
      String atmosphereKey = 'public:secondcontact.atmosphere$firstAtsign';
      await socket_writer(
          socketConnection1!, 'update:$atmosphereKey atmospherevalue');
      var updateResponse = await read();
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));

      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');

      var enrollmentId = enrollJsonMap['enrollmentId'];

      // now do the apkam using the enrollment id
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollmentId:$enrollmentId:$pkamDigest\n';

      await socket_writer(socketConnection1!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      expect(apkamEnrollIdResponse, 'data:success\n');

      await socket_writer(socketConnection1!, 'llookup:$atmosphereKey');
      var llookupResponse = await read();
      print(llookupResponse);
      expect(llookupResponse, 'data:atmospherevalue\n');
    });

    // Prerequisite - create a wavi key
    //  1. Cram authenticate and send the enroll request for wavi namespace
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
      var cramDigest = getDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'cram:$cramDigest');
      var cramResult = await read();
      expect(cramResult, 'data:success\n');

      // Before creating a enroll request with wavi namespace
      // create a atmosphere key
      String waviKey = 'firstname.wavi$firstAtsign';
      String waviValue = 'wavivalue';
      await socket_writer(socketConnection1!, 'update:$waviKey $waviValue');
      var updateResponse = await read();
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));

      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');

      var enrollmentId = enrollJsonMap['enrollmentId'];

      // now do the apkam using the enrollment id
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollmentId:$enrollmentId:$pkamDigest\n';

      await socket_writer(socketConnection1!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      expect(apkamEnrollIdResponse, 'data:success\n');

      await socket_writer(socketConnection1!, 'llookup:$waviKey');
      var llookupResponse = await read();
      print(llookupResponse);
      expect(llookupResponse, 'data:$waviValue\n');
    });

    //  1. Cram authenticate and send the enroll request for wavi namespace
    //  2. pkam using the enroll id
    //  3. Already there is a atmosphere key in server
    //  4. Do a scan
    //  5. Assert that the scan returns keys from atmosphere namespace since it has access to *:rw
    test(
        'enroll request on cram authenticated connection for wavi namespace and scan displays atmosphere key',
        () async {
      await socket_writer(socketConnection1!, 'from:$firstAtsign');
      var fromResponse = await read();
      print('from verb response : $fromResponse');
      fromResponse = fromResponse.replaceAll('data:', '');
      var cramDigest = getDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'cram:$cramDigest');
      var cramResult = await read();
      expect(cramResult, 'data:success\n');

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
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');

      var enrollmentId = enrollJsonMap['enrollmentId'];

      // now do the apkam using the enrollment id
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollmentId:$enrollmentId:$pkamDigest\n';

      await socket_writer(socketConnection1!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      expect(apkamEnrollIdResponse, 'data:success\n');

      await socket_writer(socketConnection1!, 'scan');
      var scanResponse = await read();
      expect(scanResponse.contains(atmosphereKey), true);
    });

    // 1. Do a cram authentication
    // 2. Send an enroll request with wavi-rw access
    // 3. Get an otp from the first client
    // 4. Send an enroll request with otp from the second client for buzz
    // 5. First client approves the enroll request
    // 6. Second client should have access only to buzz namespace and not to wavi namespace
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

      // update wavi key
      String waviKey = 'phone.wavi$firstAtsign';
      await socket_writer(socketConnection1!, 'update:$waviKey waviValue');
      await read();

      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"encryptedDefaultEncryptedPrivateKey":"$encryptedDefaultEncPrivateKey","encryptedDefaultSelfEncryptionKey":"$encryptedSelfEncKey","apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      print('enrollJsonMap: $enrollJsonMap');
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
      var apkamResponse = await read();
      expect(apkamResponse, 'data:success\n');

      // update buzz key
      String buzzKey = 'email.buzz$firstAtsign';
      await socket_writer(
          socketConnection2!, 'update:$buzzKey test@atsign.com');
      await read();

      // llookup on wavi key should fail
      await socket_writer(socketConnection2!, 'llookup:$waviKey');
      var llookupResponse = await read();
      expect(llookupResponse,
          startsWith('error:AT0009-UnAuthorized client in request'));

      // delete on wavi key should fail
      await socket_writer(socketConnection2!, 'delete:$waviKey');
      var deleteResponse = await read();
      expect(deleteResponse,
          startsWith('error:AT0009-UnAuthorized client in request'));

      // llookup on buzz key should succeed
      await socket_writer(socketConnection2!, 'llookup:$buzzKey');
      llookupResponse = await read();
      print(llookupResponse);
      expect(llookupResponse, 'data:test@atsign.com\n');

      // delete on buzz key should pass
      await socket_writer(socketConnection2!, 'delete:$buzzKey');
      deleteResponse = await read();
      print(deleteResponse);
      assert((deleteResponse.startsWith('data:')) &&
          (!deleteResponse.contains('Invalid syntax')) &&
          (!deleteResponse.contains('null')));
    });

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
      var cramDigest = getDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'cram:$cramDigest');
      var cramResult = await read();
      expect(cramResult, 'data:success\n');

      String waviKey = 'lastname.wavi$firstAtsign';
      String value = 'checkingValue';
      await socket_writer(socketConnection1!, 'update:$waviKey $value');
      var updateResponse = await read();
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));

      // enroll request with wavi namespace
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');

      var enrollmentId = enrollJsonMap['enrollmentId'];

      // now do the apkam using the enrollment id
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollmentId:$enrollmentId:$pkamDigest\n';

      await socket_writer(socketConnection1!, apkamEnrollId);
      var apkamEnrollIdResponse = await read();
      expect(apkamEnrollIdResponse, 'data:success\n');

      await socket_writer(socketConnection1!, 'scan');
      var scanResponse = await read();
      print(scanResponse);
      expect((scanResponse.contains(waviKey)), true);
    });

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
      var cramDigest = getDigest(firstAtsign, fromResponse);
      await socket_writer(socketConnection1!, 'cram:$cramDigest');
      var cramResult = await read();
      expect(cramResult, 'data:success\n');

      // create a wavi key
      String waviKey = 'public:email.wavi$firstAtsign';
      await socket_writer(socketConnection1!, 'update:$waviKey twitterid');
      var updateResponse = await read();
      print(updateResponse);
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));

      // enroll request with wavi namespace
      var enrollRequest =
          'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
      await socket_writer(socketConnection1!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');

      var enrollmentId = enrollJsonMap['enrollmentId'];

      // now do the apkam using the enrollment id
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      var apkamEnrollId = 'pkam:enrollmentId:$enrollmentId:$pkamDigest\n';

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
  });

  tearDown(() {
    //Closing the socket connection
    clear();
    socketConnection1!.destroy();
  });
}
