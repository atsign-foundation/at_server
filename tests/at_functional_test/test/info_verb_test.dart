import 'dart:convert';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/apkam_keys.dart';
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
    int random = Uuid().v4().hashCode;
    ApkamKeys keys = mintApkamKeys();

    // The new app is admitted through the OTP path. A legacy connection's own
    // `enroll:request` is a RETROFIT of its own enrollment now — it carries
    // that enrollment's grants and may not choose `{"wavi":"rw"}` — so the
    // legacy connection MINTS the otp and the app sends its own request over
    // its own unauthenticated connection, which is what that path is for.
    String otp = (await firstAtSignConnection.sendRequestToServer('otp:get'))
        .replaceAll('data:', '')
        .trim();
    OutboundConnectionFactory newApp =
        await OutboundConnectionFactory().initiateConnectionWithListener(
            firstAtSign, firstAtSignHost, firstAtSignPort);
    String enrollRequest =
        'enroll:request:{"appName":"wavi-$random","deviceName":"pixel-$random","namespaces":{"wavi":"rw"},"otp":"$otp","apkamPublicKey":"${keys.publicKey}","encryptedAPKAMSymmetricKey":"dummy_apkam_$random"}';
    var enrollResponse = await newApp.sendRequestToServer(enrollRequest);
    enrollResponse = enrollResponse.replaceFirst('data:', '');
    var enrollJsonMap = jsonDecode(enrollResponse);
    expect(enrollJsonMap['enrollmentId'], isNotEmpty);
    String enrollmentId = enrollJsonMap['enrollmentId'].toString().trim();
    await newApp.close();
    // Approve enrollment
    enrollResponse = await firstAtSignConnection.sendRequestToServer(
        'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey": "dummy_encrypted_default_encryption_private_key","encryptedDefaultSelfEncryptionKey":"dummy_encrypted_default_self_encryption_key"}');
    enrollResponse = enrollResponse.replaceFirst('data:', '');
    await firstAtSignConnection.close();

    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
    await firstAtSignConnection.authenticateConnection(
        authType: AuthType.apkam,
        enrollmentId: enrollmentId,
        privateKey: keys.privateKey);
    // check the info verb.. It should return the result
    String infoVerbResponse =
        await firstAtSignConnection.sendRequestToServer('info');
    infoVerbResponse = infoVerbResponse.replaceAll('data:', '');
    Map infoResponse = jsonDecode(infoVerbResponse);
    print('infoResponse: $enrollResponse');
    expect(infoResponse['apkam_metadata'], isNotEmpty);
    // Assert the APKAM metadata
    expect(infoResponse['apkam_metadata']['appName'], 'wavi-$random');
    expect(infoResponse['apkam_metadata']['deviceName'], 'pixel-$random');
    expect(infoResponse['apkam_metadata']['namespaces'], {"wavi": "rw"});
    expect(infoResponse['apkam_metadata']['sessionId'], isNotNull);
    expect(infoResponse['apkam_metadata']['apkamPublicKey'], isNotNull);
  });
}
