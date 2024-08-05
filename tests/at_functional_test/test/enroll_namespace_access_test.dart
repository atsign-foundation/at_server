import 'dart:convert';

import 'package:at_demo_data/at_demo_data.dart' as at_demos;
import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
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

  group('A group of tests to verify apkam enroll namespace access', () {
    //  1. Cram authenticate and send the enroll request for wavi namespace
    //     - When CRAM authenticated, send PKAM Public key in enrollment request->APKAM public key to
    //       to preserve backward compatibility.
    //  2. pkam using the enroll id
    //  3. Create a public key with atmosphere namespace
    //  4. Assert update and llookup can be performed on  atmosphere namespace since cram auth connection gets access to *:rw
    test(
        'enroll request on cram authenticated connection for wavi namespace and create a key in atmosphere namespace',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      var enrollRequest =
          'enroll:request:{"appName":"wavi-${Uuid().v4().hashCode}","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}\n';
      String enrollResponse =
          (await firstAtSignConnection.sendRequestToServer(enrollRequest))
              .replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');
      var enrollmentId = enrollJsonMap['enrollmentId'];
      // close the connection and authenticate with APKAM
      await firstAtSignConnection.close();
      // now do the APKAM using the enrollment id
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.pkam, enrollmentId: enrollmentId);
      String updateResponse = await firstAtSignConnection.sendRequestToServer(
          'update:twitter.atmosphere$firstAtSign twitterid');
      expect(
          updateResponse.startsWith('data:') &&
              (!updateResponse.contains('Invalid syntax')) &&
              (!updateResponse.contains('null')),
          true);
      String llookupResponse = await firstAtSignConnection
          .sendRequestToServer('llookup:twitter.atmosphere$firstAtSign');
      expect(llookupResponse, 'data:twitterid');
    });

    //  1. Cram authenticate and send the enroll request for wavi namespace
    //  2. pkam using the enroll id
    //  3. Create a public key with wavi namespace
    //  4. Assert that wavi key is created without an exception
    test(
        'enroll request on authenticated connection for wavi namespace and creating a wavi key',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      var enrollRequest =
          'enroll:request:{"appName":"wavi-${Uuid().v4().hashCode}","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}\n';
      String enrollResponse =
          await firstAtSignConnection.sendRequestToServer(enrollRequest);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');
      String enrollmentId = enrollJsonMap['enrollmentId'];
      // Close the connection and create a new connection and authenticate with APKAM
      await firstAtSignConnection.close();
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      // now do the apkam using the enrollment id
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.pkam, enrollmentId: enrollmentId);

      String updateResponse = await firstAtSignConnection.sendRequestToServer(
          'update:public:lastname.wavi$firstAtSign twitterid');
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));
    });

    //  1. Cram authenticate and send the enroll request for buzz namespace with read and write access
    //  2. pkam using the enroll id
    //  3. Create a key with at_contact.buzz
    //  4. Assert that buzz key is created without an exception
    //  5. Do a llookup of the key and assert that value is returned
    test(
        'enroll request on authenticated connection for buzz namespace and creating a at_contact.buzz key',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      var enrollRequest =
          'enroll:request:{"appName":"buzz-${Uuid().v4().hashCode}","deviceName":"pixel","namespaces":{"buzz":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}\n';
      String enrollResponse =
          await firstAtSignConnection.sendRequestToServer(enrollRequest);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');
      String enrollmentId = enrollJsonMap['enrollmentId'];
      // Close the connection and create a new connection and authenticate with APKAM
      await firstAtSignConnection.close();
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      // now do the apkam using the enrollment id
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.pkam, enrollmentId: enrollmentId);
      String atContactBuzzKey =
          'atconnections.bob.alice.at_contact.buzz$firstAtSign';
      String updateResponse = await firstAtSignConnection
          .sendRequestToServer('update:$atContactBuzzKey bob');
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));
      String llookupResponse = await firstAtSignConnection
          .sendRequestToServer('llookup:$atContactBuzzKey');
      expect(llookupResponse, 'data:bob');
    });

    //  1. Cram authenticate and send the enroll request for buzz namespace with read and write access
    //  2. pkam using the enroll id
    //  3. Create a key with at_contact.buzz
    //  4. Assert that buzz key is created without an exception
    //  5. Delete the key and assert that it is successful
    test(
        'enroll request on authenticated connection for buzz namespace and deleting a at_contact.buzz key',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      var enrollRequest =
          'enroll:request:{"appName":"buzz-${Uuid().v4().hashCode}","deviceName":"pixel","namespaces":{"buzz":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}\n';
      String enrollResponse =
          await firstAtSignConnection.sendRequestToServer(enrollRequest);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');
      String enrollmentId = enrollJsonMap['enrollmentId'];
      // Close the connection and create a new connection and authenticate with APKAM
      await firstAtSignConnection.close();
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      // now do the apkam using the enrollment id
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.pkam, enrollmentId: enrollmentId);
      String atContactBuzzKey =
          'atconnections.bob.alice.at_contact.buzz$firstAtSign';
      String deleteResponse = await firstAtSignConnection
          .sendRequestToServer('delete:$atContactBuzzKey');
      assert((!deleteResponse.contains('Invalid syntax')) &&
          (!deleteResponse.contains('null')));
    });

    // key - @aquamarine659:5ea9cc57-8281-4ba6-a30e-d4cb8c3c67e8_53979647-2908-48bf-a0f8-331f7da6e59b.buzzkey.atbuzz@scrapbookgemini
    //  1. Cram authenticate and send the enroll request for buzz namespace with read and write access
    //  2. pkam using the enroll id
    //  3. Create a key with buzzkey.buzz
    //  4. Assert that buzz key is created without an exception
    //  5. Do a llookup of the key and assert that value is returned
    test(
        'enroll request on authenticated connection for buzz namespace and creating a buzzkey',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      var enrollRequest =
          'enroll:request:{"appName":"buzz-${Uuid().v4().hashCode}","deviceName":"pixel","namespaces":{"buzz":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}\n';
      String enrollResponse =
          await firstAtSignConnection.sendRequestToServer(enrollRequest);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');
      String enrollmentId = enrollJsonMap['enrollmentId'];
      // Close the connection and create a new connection and authenticate with APKAM
      await firstAtSignConnection.close();
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      // now do the apkam using the enrollment id
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.pkam, enrollmentId: enrollmentId);
      String atContactBuzzKey =
          '$firstAtSign:123buzzkey.buzz$firstAtSign';
      String updateResponse = await firstAtSignConnection
          .sendRequestToServer('update:$atContactBuzzKey buzzkey');
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));
      String llookupResponse = await firstAtSignConnection
          .sendRequestToServer('llookup:$atContactBuzzKey');
      expect(llookupResponse, 'data:buzzkey');
    });

    // Prerequisite - create a atmosphere key
    //  1. Cram authenticate and send the enroll request for wavi namespace
    //  2. pkam using the enroll id
    //  3. Do a llookup for a self atmosphere key
    //  4. Llookup should be successful since the enrollment gets access to *:rw
    try {
      test(
          'enroll request on authenticated connection for wavi namespace and llookup for a self atmosphere key',
          () async {
        await firstAtSignConnection.authenticateConnection(
            authType: AuthType.cram);
        // Before creating a enroll request with wavi namespace
        // create a atmosphere key
        String atmosphereKey = 'firstcontact.atmosphere$firstAtSign';
        String updateResponse = await firstAtSignConnection
            .sendRequestToServer('update:$atmosphereKey atmospherevalue');
        assert((!updateResponse.contains('Invalid syntax')) &&
            (!updateResponse.contains('null')));

        var enrollRequest =
            'enroll:request:{"appName":"wavi-${Uuid().v4().hashCode}","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}\n';
        String enrollResponse =
            (await firstAtSignConnection.sendRequestToServer(enrollRequest))
                .replaceAll('data:', '');
        var enrollJsonMap = jsonDecode(enrollResponse);
        expect(enrollJsonMap['enrollmentId'], isNotEmpty);
        expect(enrollJsonMap['status'], 'approved');
        String enrollmentId = enrollJsonMap['enrollmentId'];
        // Close the connection
        await firstAtSignConnection.close();
        // now do the apkam using the enrollment id
        await firstAtSignConnection.initiateConnectionWithListener(
            firstAtSign, firstAtSignHost, firstAtSignPort);
        await firstAtSignConnection.authenticateConnection(
            authType: AuthType.pkam, enrollmentId: enrollmentId);
        String llookupResponse = await firstAtSignConnection
            .sendRequestToServer('llookup:$atmosphereKey');
        expect(llookupResponse, 'data:atmospherevalue');
      });
    } catch (e, s) {
      print(s);
    }

    // Prerequisite - create a public atmosphere key
    //  1. Authenticate and send the enroll request for wavi namespace
    //  2. pkam using the enroll id
    //  3. Do a llookup for a public atmosphere key
    //  4. Assert that the llookup returns a value without an exception
    test(
        'enroll request on authenticated connection for wavi namespace and llookup for a public atmosphere key',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      // Before creating a enroll request with wavi namespace
      // create a atmosphere key
      String atmosphereKey = 'public:secondcontact.atmosphere$firstAtSign';
      String updateResponse = await firstAtSignConnection
          .sendRequestToServer('update:$atmosphereKey atmospherevalue');
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));

      var enrollRequest =
          'enroll:request:{"appName":"wavi-${Uuid().v4().hashCode}","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}\n';
      String enrollResponse =
          (await firstAtSignConnection.sendRequestToServer(enrollRequest))
              .replaceAll('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');

      String enrollmentId = enrollJsonMap['enrollmentId'];
      await firstAtSignConnection.close();
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      // now do the apkam using the enrollment id
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.pkam, enrollmentId: enrollmentId);

      String llookupResponse = await firstAtSignConnection
          .sendRequestToServer('llookup:$atmosphereKey');
      expect(llookupResponse, 'data:atmospherevalue');
    });

    // Prerequisite - create a wavi key
    //  1. Cram authenticate and send the enroll request for wavi namespace
    //  2. pkam using the enroll id
    //  4. Do a llookup for the wavi key
    //  5. Assert that the llookup returns correct value and does not throw an exception
    test(
        'enroll request on authenticated connection for wavi namespace and llookup for a wavi key',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      // Before creating a enroll request with wavi namespace
      // create a atmosphere key
      String waviKey = 'firstname.wavi$firstAtSign';
      String waviValue = 'wavivalue';
      String updateResponse = await firstAtSignConnection
          .sendRequestToServer('update:$waviKey $waviValue');
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));

      var enrollRequest =
          'enroll:request:{"appName":"wavi-${Uuid().v4().hashCode}","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}\n';
      String enrollResponse =
          (await firstAtSignConnection.sendRequestToServer(enrollRequest))
              .replaceAll('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');

      String enrollmentId = enrollJsonMap['enrollmentId'];
      //Close the connection and authenticate with APKAM
      await firstAtSignConnection.close();
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.pkam, enrollmentId: enrollmentId);

      String llookupResponse =
          await firstAtSignConnection.sendRequestToServer('llookup:$waviKey');
      expect(llookupResponse, 'data:$waviValue');
    });

    //  1. Cram authenticate and send the enroll request for wavi namespace
    //  2. pkam using the enroll id
    //  3. Already there is a atmosphere key in server
    //  4. Do a scan
    //  5. Assert that the scan returns keys from atmosphere namespace since it has access to *:rw
    test(
        'enroll request on cram authenticated connection for wavi namespace and scan displays atmosphere key',
        () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      // Before creating a enroll request with wavi namespace
      // create a atmosphere key
      String atmosphereKey = 'filename.atmosphere$firstAtSign';
      String updateResponse = await firstAtSignConnection
          .sendRequestToServer('update:$atmosphereKey atmospherevalue');
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));

      // enroll request with wavi namespace
      var enrollRequest =
          'enroll:request:{"appName":"wavi-${Uuid().v4().hashCode}","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}\n';
      String enrollResponse =
          (await firstAtSignConnection.sendRequestToServer(enrollRequest))
              .replaceAll('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');

      String enrollmentId = enrollJsonMap['enrollmentId'];
      // Close the connection
      await firstAtSignConnection.close();
      // now do the apkam using the enrollment id
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.pkam, enrollmentId: enrollmentId);

      String scanResponse =
          await firstAtSignConnection.sendRequestToServer('scan');
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
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      // update wavi key
      String waviKey = 'phone.wavi$firstAtSign';
      await firstAtSignConnection
          .sendRequestToServer('update:$waviKey waviValue');

      var enrollRequest =
          'enroll:request:{"appName":"wavi-${Uuid().v4().hashCode}","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}\n';
      String enrollResponse =
          (await firstAtSignConnection.sendRequestToServer(enrollRequest))
              .replaceAll('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      print('enrollJsonMap: $enrollJsonMap');
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');

      String otpResponse =
          await firstAtSignConnection.sendRequestToServer('otp:get');
      otpResponse = otpResponse.replaceFirst('data:', '');
      otpResponse = otpResponse.trim();

      // connect to the second client
      OutboundConnectionFactory secondConnection =
          await OutboundConnectionFactory().initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);

      //send second enroll request with otp
      var secondEnrollRequest =
          'enroll:request:{"appName":"buzz","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"buzz":"rw"},"otp":"$otpResponse","apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey" : "${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}\n';
      var secondEnrollResponse =
          (await secondConnection.sendRequestToServer(secondEnrollRequest))
              .replaceAll('data:', '');
      var enrollJson = jsonDecode(secondEnrollResponse);
      expect(enrollJson['enrollmentId'], isNotEmpty);
      expect(enrollJson['status'], 'pending');
      String secondEnrollmentId = enrollJson['enrollmentId'];

      // connect to the first client to approve the enroll request
      var approveResponse = (await firstAtSignConnection.sendRequestToServer(
              'enroll:approve:{"enrollmentId":"$secondEnrollmentId","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap["encryptedDefaultEncPrivateKey"]}","encryptedDefaultSelfEncryptionKey": "${apkamEncryptedKeysMap["encryptedSelfEncKey"]}"}'))
          .replaceAll('data:', '');
      var approveJson = jsonDecode(approveResponse);
      expect(approveJson['status'], 'approved');
      expect(approveJson['enrollmentId'], secondEnrollmentId);

      // close the first connection
      firstAtSignConnection.close();
      // connect to the second client to do an apkam
      await secondConnection.authenticateConnection(
          authType: AuthType.apkam, enrollmentId: secondEnrollmentId);
      // update buzz key
      String buzzKey = 'email.buzz$firstAtSign';
      await secondConnection
          .sendRequestToServer('update:$buzzKey test@atsign.com');
      // llookup on wavi key should fail
      String llookupResponse =
          (await secondConnection.sendRequestToServer('llookup:$waviKey'))
              .replaceAll('error:', '');
      Map llookupResponseMap = jsonDecode(llookupResponse);
      expect(llookupResponseMap['errorCode'], 'AT0009');
      expect(llookupResponseMap['errorDescription'],
          'UnAuthorized client in request : Connection with enrollment ID $secondEnrollmentId is not authorized to llookup key: $waviKey');

      // delete on wavi key should fail
      String deleteResponse =
          (await secondConnection.sendRequestToServer('delete:$waviKey'))
              .replaceAll('error:', '');
      Map deleteResponseMap = jsonDecode(deleteResponse);
      expect(deleteResponseMap['errorCode'], 'AT0009');
      expect(deleteResponseMap['errorDescription'],
          'UnAuthorized client in request : Connection with enrollment ID $secondEnrollmentId is not authorized to delete key: $waviKey');

      // llookup on buzz key should succeed
      llookupResponse =
          await secondConnection.sendRequestToServer('llookup:$buzzKey');
      expect(llookupResponse, 'data:test@atsign.com');

      // delete on buzz key should pass
      deleteResponse =
          await secondConnection.sendRequestToServer('delete:$buzzKey');
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
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);

      String waviKey = 'lastname.wavi$firstAtSign';
      String value = 'checkingValue';
      String updateResponse = await firstAtSignConnection
          .sendRequestToServer('update:$waviKey $value');
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));

      // enroll request with wavi namespace
      String enrollRequest =
          'enroll:request:{"appName":"wavi-${Uuid().v4().hashCode}","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}\n';
      String enrollResponse =
          await firstAtSignConnection.sendRequestToServer(enrollRequest);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');

      String enrollmentId = enrollJsonMap['enrollmentId'];
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.pkam, enrollmentId: enrollmentId);
      String scanResponse =
          await firstAtSignConnection.sendRequestToServer('scan');
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
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);

      // create a wavi key
      String waviKey = 'public:email.wavi$firstAtSign';
      String updateResponse = await firstAtSignConnection
          .sendRequestToServer('update:$waviKey twitterid');
      assert((!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));
      // enroll request with wavi namespace
      String enrollRequest =
          'enroll:request:{"appName":"wavi-${Uuid().v4().hashCode}","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}';
      String enrollResponse =
          (await firstAtSignConnection.sendRequestToServer(enrollRequest))
              .replaceAll('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'approved');

      String enrollmentId = enrollJsonMap['enrollmentId'];
      // Close the connection. Create a new connection and authenticate via the APKAM
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.apkam, enrollmentId: enrollmentId);

      // delete the wavi key
      String deleteResponse =
          await firstAtSignConnection.sendRequestToServer('delete:$waviKey');
      assert((!deleteResponse.contains('Invalid syntax')) &&
          (!deleteResponse.contains('null')));
    });
  });

  tearDown(() {
    firstAtSignConnection.close();
  });
}
