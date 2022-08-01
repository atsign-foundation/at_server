import 'dart:convert';
import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'commons.dart';

void main() {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  var firstAtsignPort =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

  Socket? socketFirstAtsign;

  setUp(() async {
    var firstAtsignServer =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);
  });

  test('Test that stats:13 returns the access Log stats', () async {
    await socket_writer(socketFirstAtsign!, 'stats:13');
    var response = await read();
    print("stats:13 response is $response");
    assert(response.contains('"name":"AccessLogCompactionStats"'));
  });

  test('Access log compaction', () async {
    try {
      // setting access log compaction to 1minute
      await socket_writer(
          socketFirstAtsign!, 'config:set:accessLogCompactionFrequencyMins= 1');
      var response = await read();
      print('config set verb response is $response');
      expect(response, contains('data:ok'));

      int noOfTests = 30;
      for (int i = 1; i <= noOfTests; i++) {
        await socket_writer(
            socketFirstAtsign!, 'update:public:role$firstAtsign Dev');
        response = await read();
        print('update verb response : $response');
        assert((!response.contains('Invalid syntax')) &&
            (!response.contains('null')));
      }

      // wait till the commit log compaction job runs
      await Future.delayed(Duration(seconds: 30));
      var afterUpdate = await compactionStats(socketFirstAtsign!, 13);
      // pre compaction entries count
      var preCompactionCount = afterUpdate['preCompactionEntriesCount'];
      // post compaction entries count
      var postCompactionCount = await afterUpdate['postCompactionEntriesCount'];
      // Deleted entries count post compaction
      var deletedCountAfter = await afterUpdate['deletedKeysCount'];
      print('pre compaction entries count $preCompactionCount');
      print('post compaction entries count $postCompactionCount');
      print('deleted keys count after update is $deletedCountAfter');
      // Verifying whether precompaction count is not equal to post compaction count
      expect((postCompactionCount != preCompactionCount), true);
      int result =
          (int.parse(preCompactionCount) - (int.parse(postCompactionCount)));
      // Verifying whether the deleted entries count is same as the result
      expect(int.parse(deletedCountAfter), result);
    } finally {
      //  reset the access log compaction to default after the test
      await socket_writer(
          socketFirstAtsign!, 'config:reset:accessLogCompactionFrequencyMins');
      var response = await read();
      print('config reset verb response is $response');
      expect(response, contains('data:ok'));
    }
  }, timeout: Timeout(Duration(seconds: 150)));

  tearDown(() {
    //Closing the socket connection
    clear();
    socketFirstAtsign!.destroy();
  });
}

Future<Map> compactionStats(Socket socket, int statsId) async {
  await socket_writer(socket, 'stats:$statsId');
  var statsResponse = await read();
  print('stats verb response : $statsResponse');
  var jsonData =
      jsonDecode(statsResponse.replaceAll('data:', '').trim().toString());
  return jsonDecode(jsonData[0]['value']);
}
