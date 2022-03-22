import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
    socketFirstAtsign =
        await secure_socket_connection('vip.ve.atsign.zone', firstAtsignPort);
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
    int noOfTests = 30;
    for (int i = 1; i <= noOfTests; i++) {
      await socket_writer(
          socketFirstAtsign!, 'update:public:role$firstAtsign Dev');
      var response = await read();
      print('update verb response : $response');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
    }

    await Future.delayed(Duration(seconds: 50));
    var afterUpdate = await  compactionStats(socketFirstAtsign!, 12);
    var preCompactionCount = afterUpdate['preCompactionEntriesCount'];
    var postCompactionCount = await afterUpdate['postCompactionEntriesCount'];
    var deletedCountAfter = await afterUpdate['deletedKeysCount'];
    print('pre compaction entries count $preCompactionCount');
    print('post compaction entries count $postCompactionCount');
    print('deleted keys count after update is $deletedCountAfter');
    expect((postCompactionCount != preCompactionCount), true);
    int result = (int.parse(preCompactionCount) - (int.parse(postCompactionCount)));
    expect(int.parse(deletedCountAfter),result );
  }, timeout: Timeout(Duration(seconds: 150)));

  test('access log compaction', () async {
    int randomNumber = Random().nextInt(30);
    var beforeUpdate = await compactionStats(socketFirstAtsign!, 13);
    var sizeBeforeCompaction = await beforeUpdate['size_before_compaction'];
    var deletedCountBefore = await beforeUpdate['deletedKeysCount'];
    var lastRunTime = await beforeUpdate['last_compaction_run'];
    print('size before compaction is $sizeBeforeCompaction');
    print('deleted keys before update is $deletedCountBefore');
    print('last compaction run time is $lastRunTime');

    int noOfTests = 30;
    for (int i = 1; i <= noOfTests; i++) {
      await socket_writer(socketFirstAtsign!,
          'update:public:pin$firstAtsign 1122$randomNumber');
      var response = await read();
      print('update verb response : $response');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
    }

    await Future.delayed(Duration(seconds: 40));
    var afterUpdate = await compactionStats(socketFirstAtsign!, 13);
    var sizeAfterCompaction = await afterUpdate['size_after_compaction'];
    var deletedCountAfter = await afterUpdate['deletedKeysCount'];
    print('deleted keys count after update is $deletedCountAfter');
    print('size after compaction is $sizeAfterCompaction');
    expect(sizeAfterCompaction, 0);
    expect(deletedCountAfter, (noOfTests - 1));
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
