import 'dart:convert';
import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'commons.dart';

void main() async {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  Socket? socketFirstAtsign;

  setUp(() async {
    var firstAtsignServer =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    var firstAtsignPort =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);
  });
  test('Test that stats:12 returns the commit Log stats', () async {
    await socket_writer(socketFirstAtsign!, 'stats:12');
    var response = await read();
    print("stats:12 response is $response");
    assert(response.contains('"name":"CommitLogCompactionStats"'));
  });

  test('commit log compaction', () async {
    try {
      // setting the commit log compaction value to 1
      await socket_writer(
          socketFirstAtsign!, 'config:set:commitLogCompactionFrequencyMins= 1');
      var response = await read();
      print('config set verb response is $response');
      expect(response, contains('data:ok'));

      // Updating the same key multiple times
      int noOfTests = 40;
      for (int i = 1; i <= noOfTests; i++) {
        await socket_writer(
            socketFirstAtsign!, 'update:public:role$firstAtsign Dev');
        var response = await read();
        print('update verb response : $response');
        assert((!response.contains('Invalid syntax')) &&
            (!response.contains('null')));
      }
      // wait till the commit log compaction job runs
      await Future.delayed(Duration(seconds: 50));
      var afterUpdate = await compactionStats(socketFirstAtsign!, 12);
      // pre compaction entries count
      var preCompactionCount = await afterUpdate['preCompactionEntriesCount'];
      // post compaction entries count
      var postCompactionCount = await afterUpdate['postCompactionEntriesCount'];
      // Verifying whether post compaction count is less than pre compaction count
      expect((int.parse(postCompactionCount) < (int.parse(preCompactionCount))),
          true);
    } finally {
      //  reset the commit log compaction to default after the test
      await socket_writer(
          socketFirstAtsign!, 'config:reset:commitLogCompactionFrequencyMins');
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
  print('jsonData is $jsonData');
  return jsonDecode(jsonData[0]['value']);
}
