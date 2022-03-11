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

  test('commit log compaction', () async {
    var beforeUpdate =  await compactionStats(socketFirstAtsign!);
    var sizeBeforeCompaction =  await beforeUpdate['size_before_compaction'];
    var deletedCountBefore = await beforeUpdate['deleted_keys_count'];
    print('size before compaction is $sizeBeforeCompaction');
    print('deleted keys before update is $deletedCountBefore');
    

    int noOfTests =30;
    for(int i =1 ; i <= noOfTests ;i++ ){
    await socket_writer(socketFirstAtsign!, 'update:public:role$firstAtsign Dev');
    var response = await read();  
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
     }

    await Future.delayed(Duration(seconds: 40));
    var afterUpdate = await compactionStats(socketFirstAtsign!);
    var sizeAfterCompaction =  await afterUpdate['size_after_compaction'];
    var deletedCountAfter = await afterUpdate['deleted_keys_count'];
    print('deleted keys count after update is $deletedCountAfter');
    print('size after compaction is $sizeAfterCompaction');
    expect(sizeAfterCompaction,0);
    expect(deletedCountAfter, (noOfTests-1) );
  },  timeout: Timeout(Duration(seconds: 150)));

  tearDown(() {
    //Closing the socket connection
    clear();
    socketFirstAtsign!.destroy();
  });
}

Future<Map> compactionStats(Socket socket) async {
  await socket_writer(socket, 'stats:12');
  var statsResponse = await read();
  print('stats verb response : $statsResponse');
  var jsonData =
      jsonDecode(statsResponse.replaceAll('data:', '').trim().toString());
  return jsonDecode(jsonData[0]['value']);
}