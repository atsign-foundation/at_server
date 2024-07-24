import 'dart:convert';

import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
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

  setUpAll(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
  });

  test('info verb test without authentication', () async {
    String infoVerbResponse =
        await firstAtSignConnection.sendRequestToServer('info');
    infoVerbResponse = infoVerbResponse.replaceAll('data:', '');
    Map infoResponse = jsonDecode(infoVerbResponse);
    expect(infoResponse['version'], isNotEmpty);
  });

  test('info verb with enroll verb changes', () async {
    await firstAtSignConnection.authenticateConnection();
    // create a key with the _manage namespace
    int random = Uuid().v4().hashCode;
    String enrollRequest =
        'enroll:request:{"appName":"wavi-$random","deviceName":"pixel-$random","namespaces":{"wavi":"rw"},"apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}"}';
    var enrollResponse =
        await firstAtSignConnection.sendRequestToServer(enrollRequest);
    enrollResponse = enrollResponse.replaceFirst('data:', '');
    print(enrollResponse);
    var enrollJsonMap = jsonDecode(enrollResponse);
    expect(enrollJsonMap['enrollmentId'], isNotEmpty);
    String enrollmentId = enrollJsonMap['enrollmentId'].toString().trim();
    // Approve enrollment
    enrollResponse = await firstAtSignConnection.sendRequestToServer(
        'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey": "dummy_encrypted_default_encryption_private_key","encryptedDefaultSelfEncryptionKey":"dummy_encrypted_default_self_encryption_key"}');
    enrollResponse = enrollResponse.replaceFirst('data:', '');
    await firstAtSignConnection.close();

    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
    await firstAtSignConnection.authenticateConnection(
        authType: AuthType.apkam, enrollmentId: enrollmentId);
    // check the info verb.. It should return the result
    String infoVerbResponse =
        await firstAtSignConnection.sendRequestToServer('info');
    infoVerbResponse = infoVerbResponse.replaceAll('data:', '');
    Map infoResponse = jsonDecode(infoVerbResponse);
    print('infoResponse: $enrollResponse');
    expect(infoResponse['apkam_metadata'], isNotEmpty);
    var apkamMetadata = jsonDecode(infoResponse['apkam_metadata']);
    // Assert the APKAM metadata
    expect(apkamMetadata['appName'], 'wavi-$random');
    expect(apkamMetadata['deviceName'], 'pixel-$random');
    expect(apkamMetadata['namespaces'], {"wavi": "rw"});
    expect(apkamMetadata['sessionId'], isNotNull);
    expect(apkamMetadata['apkamPublicKey'], isNotNull);
  });
}
