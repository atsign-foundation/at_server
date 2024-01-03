import 'dart:convert';

import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';

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
    String enrollRequest =
        'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${apkamPublicKeyMap[firstAtSign]!}"}';
    var enrollResponse =
        await firstAtSignConnection.sendRequestToServer(enrollRequest);
    enrollResponse = enrollResponse.replaceFirst('data:', '');
    var enrollJsonMap = jsonDecode(enrollResponse);
    expect(enrollJsonMap['enrollmentId'], isNotEmpty);
    String enrollmentId = enrollJsonMap['enrollmentId'].toString().trim();
    // Approve enrollment
    enrollResponse = await firstAtSignConnection
        .sendRequestToServer('enroll:approve:{"enrollmentId":"$enrollmentId"}');
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
    expect(infoResponse['apkam_metadata'], isNotEmpty);
    var apkamMetadata = jsonDecode(infoResponse['apkam_metadata']);
    // Assert the APKAM metadata
    expect(apkamMetadata['appName'], 'wavi');
    expect(apkamMetadata['deviceName'], 'pixel');
    expect(apkamMetadata['namespaces'], {"wavi": "rw"});
    expect(apkamMetadata['sessionId'], isNotNull);
    expect(apkamMetadata['apkamPublicKey'], isNotNull);
  });
}
