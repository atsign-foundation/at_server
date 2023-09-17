import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'at_demo_data.dart';
import 'functional_test_commons.dart';
import 'package:at_functional_test/conf/config_util.dart';

import 'pkam_utils.dart';

void main() {
  var firstAtSign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  var firstAtSignServer =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
  var firstAtSignPort =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

  var secondAtSign =
      ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'];
  var secondAtSignServer =
      ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_url'];
  var secondAtSignPort =
      ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_port'];

  Socket? socketFirstAtsign;

  setUp(() async {
    socketFirstAtsign =
        await secure_socket_connection(firstAtSignServer, firstAtSignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtSign);
  });

  test('sync verb with regex ', () async {
    /// UPDATE VERB
    await socket_writer(socketFirstAtsign!,
        'update:public:twitter.persona$firstAtSign bob_tweet');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    var commitId = response.replaceAll('data:', '');
    var syncId = int.parse(commitId);
    var regex = '.persona';

    // sync with regex
    await socket_writer(
        socketFirstAtsign!, 'sync:from:${syncId - 1}:limit:5:$regex');
    response = await read();
    print('sync response is : $response');
    assert((response.contains('"atKey":"public:twitter$regex$firstAtSign')));
  });

  // sync negative scenario
  test('sync verb with only regex and no commit Id ', () async {
    /// UPDATE VERB
    var regex = '.buzz@';
    await socket_writer(socketFirstAtsign!, 'sync:$regex');
    var response = await read();
    print('update verb response : $response');
    assert((response.contains('Invalid syntax')));
  });

  test('sync verb in an incorrect format ', () async {
    /// UPDATE VERB
    var regex = '.buzz@';
    await socket_writer(socketFirstAtsign!, 'sync $regex');
    var response = await read();
    print('update verb response : $response');
    assert((response.contains('Invalid syntax')));
  });

  group('A group of tests to verify sync entries', () {
    late SecureSocket authenticatedSocket;
    late SecureSocket unauthenticatedSocket;
    late String enrollmentId;

    setUp(() async {
      authenticatedSocket =
          await secure_socket_connection(firstAtSignServer, firstAtSignPort);
      socket_listener(authenticatedSocket);
      unauthenticatedSocket =
          await secure_socket_connection(firstAtSignServer, firstAtSignPort);
      socket_listener(unauthenticatedSocket);
      // Get TOTP from server
      String otp = await _getOTPFromServer(authenticatedSocket, firstAtSign);
      String enrollRequest =
          'enroll:request:{"appName":"my-first-app","deviceName":"pixel","namespaces":{"wavi":"rw","buzz":"r"},"otp":"$otp","apkamPublicKey":"${pkamPublicKeyMap[firstAtSign]!}"}';

      await socket_writer(unauthenticatedSocket, enrollRequest);
      String enrollmentResponse = await read();
      enrollmentResponse = enrollmentResponse.replaceAll('data:', '');
      enrollmentId = jsonDecode(enrollmentResponse)['enrollmentId'];
      enrollmentId = enrollmentId.trim();
    });
    test(
        'A test to verify sync entries contains keys with only enrolled namespace on APKAM Authenticated Connection',
        () async {
      await socket_writer(authenticatedSocket, 'stats:3');
      int lastCommitIdBeforeUpdate = int.parse(
          jsonDecode((await read()).replaceAll('data:', ''))[0]['value']);
      String randomString = Uuid().v4();

      socket_writer(authenticatedSocket,
          'enroll:approve:{"enrollmentId":"$enrollmentId"}');
      await read();
      socket_writer(authenticatedSocket,
          'update:$secondAtSign:phone-$randomString.wavi$firstAtSign $randomString');
      await read();
      socket_writer(authenticatedSocket,
          'update:$secondAtSign:phone-$randomString.buzz$firstAtSign $randomString');
      await read();
      socket_writer(authenticatedSocket,
          'update:$secondAtSign:phone-$randomString.atmosphere$firstAtSign $randomString');
      await read();

      socket_writer(authenticatedSocket, 'stats:3');
      expect(
          int.parse(
              jsonDecode((await read()).replaceAll('data:', ''))[0]['value']),
          lastCommitIdBeforeUpdate + 4);
      authenticatedSocket.close();

      authenticatedSocket =
          await secure_socket_connection(firstAtSignServer, firstAtSignPort);
      socket_listener(authenticatedSocket);

      socket_writer(authenticatedSocket, 'from:$firstAtSign');
      String fromResponse = (await read()).replaceAll('data:', '').trim();
      String digest = generatePKAMDigest(firstAtSign, fromResponse);
      socket_writer(
          authenticatedSocket, 'pkam:enrollmentId:$enrollmentId:$digest');
      expect((await read()).trim(), 'data:success');
      socket_writer(
          authenticatedSocket, 'sync:from:$lastCommitIdBeforeUpdate:limit:10');
      List syncResponse = jsonDecode((await read()).replaceAll('data:', ''));
      expect(syncResponse.length, 2);
      expect(syncResponse[0]['atKey'],
          '$secondAtSign:phone-$randomString.wavi$firstAtSign');
      expect(syncResponse[0]['commitId'], lastCommitIdBeforeUpdate + 2);

      expect(syncResponse[1]['atKey'],
          '$secondAtSign:phone-$randomString.buzz$firstAtSign');
      expect(syncResponse[1]['commitId'], lastCommitIdBeforeUpdate + 3);
    });
  });

  tearDown(() {
    //Closing the client socket connection
    clear();
    socketFirstAtsign!.destroy();
  });
}

Future<String> _getOTPFromServer(SecureSocket socket, String atSign) async {
  await prepare(socket, atSign);
  await socket_writer(socket, 'otp:get');
  String otp = await read();
  otp = otp.replaceAll('data:', '').trim();
  return otp;
}
