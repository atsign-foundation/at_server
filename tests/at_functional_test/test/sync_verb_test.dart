import 'dart:convert';

import 'package:at_demo_data/at_demo_data.dart' as at_demos;
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
    await firstAtSignConnection.authenticateConnection();
  });

  test('sync verb with regex ', () async {
    String regex = '.persona';

    /// UPDATE VERB
    var response = await firstAtSignConnection.sendRequestToServer(
        'update:public:twitter$regex$firstAtSign bob_tweet');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    String commitId = response.replaceAll('data:', '');
    int syncId = int.parse(commitId);
    // sync with regex
    response = await firstAtSignConnection
        .sendRequestToServer('sync:from:${syncId - 1}:limit:5:$regex');
    assert((response.contains('"atKey":"public:twitter$regex$firstAtSign')));
  });

  // sync negative scenario
  test('sync verb with only regex and no commit Id ', () async {
    // UPDATE VERB
    String regex = '.buzz@';
    String response =
        await firstAtSignConnection.sendRequestToServer('sync:$regex');
    assert((response.contains('Invalid syntax')));
  });

  test('sync verb in an incorrect format ', () async {
    // UPDATE VERB
    String regex = '.buzz@';
    String response =
        await firstAtSignConnection.sendRequestToServer('sync $regex');
    assert((response.contains('Invalid syntax')));
  });

  group('A group of tests to verify sync entries', () {
    late OutboundConnectionFactory authenticatedSocket =
        OutboundConnectionFactory();
    late OutboundConnectionFactory unauthenticatedSocket =
        OutboundConnectionFactory();
    late String enrollmentId;

    setUp(() async {
      await authenticatedSocket.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      await authenticatedSocket.authenticateConnection();
      await unauthenticatedSocket.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);

      // Get OTP from server
      String otp = await authenticatedSocket.sendRequestToServer('otp:get');
      otp = otp.replaceFirst('data:', '');
      String enrollRequest =
          'enroll:request:{"appName":"my-first-app","deviceName":"pixel","namespaces":{"wavi":"rw","buzz":"r"},"otp":"$otp","apkamPublicKey":"${at_demos.apkamPublicKeyMap[firstAtSign]!}","encryptedAPKAMSymmetricKey" : "${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}';

      String enrollmentResponse =
          await unauthenticatedSocket.sendRequestToServer(enrollRequest);
      enrollmentResponse = enrollmentResponse.replaceAll('data:', '');
      enrollmentId = jsonDecode(enrollmentResponse)['enrollmentId'];
      enrollmentId = enrollmentId.trim();
    });

    test(
        'A test to verify sync entries contains keys with only enrolled namespace on APKAM Authenticated Connection',
        () async {
      String serverResponse =
          await authenticatedSocket.sendRequestToServer('stats:3');
      int lastCommitIdBeforeUpdate = int.parse(
          jsonDecode(serverResponse.replaceAll('data:', ''))[0]['value']);
      String randomString = Uuid().v4();

      await authenticatedSocket.sendRequestToServer(
          'enroll:approve:{"enrollmentId":"$enrollmentId"}');
      await authenticatedSocket.sendRequestToServer(
          'update:$secondAtSign:phone-$randomString.wavi$firstAtSign $randomString');
      await authenticatedSocket.sendRequestToServer(
          'update:$secondAtSign:phone-$randomString.buzz$firstAtSign $randomString');
      await authenticatedSocket.sendRequestToServer(
          'update:$secondAtSign:phone-$randomString.atmosphere$firstAtSign $randomString');

      String statsResponse =
          await authenticatedSocket.sendRequestToServer('stats:3');
      expect(
          int.parse(
              jsonDecode(statsResponse.replaceAll('data:', ''))[0]['value']),
          lastCommitIdBeforeUpdate + 4);
      await authenticatedSocket.close();

      await authenticatedSocket.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      await authenticatedSocket.authenticateConnection(
          authType: AuthType.apkam, enrollmentId: enrollmentId);
      String syncResponse = await authenticatedSocket
          .sendRequestToServer('sync:from:$lastCommitIdBeforeUpdate:limit:10');
      List syncResponseList = jsonDecode(syncResponse.replaceAll('data:', ''));

      expect(syncResponseList.length, 2);
      expect(syncResponseList[0]['atKey'],
          '$secondAtSign:phone-$randomString.wavi$firstAtSign');
      expect(syncResponseList[0]['commitId'], lastCommitIdBeforeUpdate + 2);

      expect(syncResponseList[1]['atKey'],
          '$secondAtSign:phone-$randomString.buzz$firstAtSign');
      expect(syncResponseList[1]['commitId'], lastCommitIdBeforeUpdate + 3);
    });
  });

  tearDown(() async {
    await firstAtSignConnection.close();
  });
}
