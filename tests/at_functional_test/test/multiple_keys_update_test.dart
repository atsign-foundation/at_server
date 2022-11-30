import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'commons.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:version/version.dart';

void main() {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];

  Socket? socketFirstAtsign;

  //Establish the client socket connection
  setUp(() async {
    var firstAtsignServer =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    var firstAtsignPort =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    // socket connection for first atsign
    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);
  });

  test('update same key multiple times test', () async {
    // Stats verb before multiple updates
    await socket_writer(socketFirstAtsign!, 'stats:3');
    var statsResponse = await read();
    print('stats response is $statsResponse');
    var jsonData =
        jsonDecode(statsResponse.replaceAll('data:', '').trim().toString());
    var commitIDValue = jsonDecode(jsonData[0]['value']);
    print('last commit id value is $commitIDValue');

    int noOfTests = 5;
    late String response;

    /// UPDATE VERB
    for (int i = 1; i <= noOfTests; i++) {
      await socket_writer(
          socketFirstAtsign!, 'update:public:location$firstAtsign Hyderabad');
      response = await read();
      print('update verb response : $response');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
    }
    // sync
    await socket_writer(
        socketFirstAtsign!, 'sync:from:${commitIDValue - 1}:limit:$noOfTests');
    response = await read();
    print('sync response is : $response');
    expect('public:location$firstAtsign'.allMatches(response).length, 1);
  });

  test('delete same key multiple times test', () async {
    int noOfTests = 3;
    late String response;
    await socket_writer(socketFirstAtsign!, 'info');
    var infoResponse = await read();
    infoResponse = infoResponse.replaceFirst('data:', '');
    final versionObj = jsonDecode(infoResponse)['version'];
    var versionStr = versionObj?.split('+')[0];
    var serverVersion;
    if (versionStr != null) {
      serverVersion = Version.parse(versionStr);
    }
    print('*** serverVersion $serverVersion');

    /// Delete VERB
    for (int i = 1; i <= noOfTests; i++) {
      await socket_writer(
          socketFirstAtsign!, 'delete:public:location$firstAtsign');
      response = await read();
      print('delete verb response : $response');
      if (serverVersion != null && serverVersion > Version(3, 0, 25)) {
        if (i > 1) {
          assert(response.startsWith('error:') && response.contains('AT0015'));
        }
      } else {
        assert((!response.contains('Invalid syntax')) &&
            (!response.contains('null')));
      }
    }
  },
      skip:
          'The changes related to throwing an exception on deleting a non-existent key are reverted in at_persistence_secondary_server : 3.0.42');

  test('update multiple key at the same time', () async {
    int noOfTests = 5;
    late String response;
    var atKey = 'public:key';
    var atValue = 'val';

    /// UPDATE VERB
    for (int i = 1, j = 1; i <= noOfTests; i++, j++) {
      await socket_writer(
          socketFirstAtsign!, 'update:$atKey$j$firstAtsign $atValue$j');
      response = await read();
      print('update verb response : $response');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
    }
  });
}
