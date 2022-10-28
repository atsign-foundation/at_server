
import 'dart:convert';

import 'package:test/test.dart';
import 'commons.dart';
import 'dart:io';
import 'package:at_functional_test/conf/config_util.dart';

void main() {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];

  Socket? socketFirstAtsign;

  //Establish the client socket connection
  setUp(() async {
    var firstAtsignServer = ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
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

    int noOfTests =5;
    late String response;
     /// UPDATE VERB
    for(int i =1 ; i <= noOfTests ;i++ ){
      await socket_writer(
        socketFirstAtsign!, 'update:public:location$firstAtsign Hyderabad');
    response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    }
    // sync
    await socket_writer(socketFirstAtsign!, 'sync:from:${commitIDValue - 1}:limit:$noOfTests');
    response = await read();
    print('sync response is : $response');
    expect('public:location$firstAtsign'.allMatches(response).length,1);
  });

  test('delete same key multiple times test', () async {
    int noOfTests =5;
    late String response;
     /// UPDATE VERB
    for(int i =1 ; i <= noOfTests ;i++ ){
      await socket_writer(
        socketFirstAtsign!, 'delete:public:location$firstAtsign');
    response = await read();
    print('delete verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    }});

   test('update multiple key at the same time', () async {
    int noOfTests =5;
    late String response;
    var atKey = 'public:key';
    var atValue = 'val';
     /// UPDATE VERB
    for(int i =1 , j=1; i <= noOfTests ;i++,j++ ){
      await socket_writer(
        socketFirstAtsign!, 'update:$atKey$j$firstAtsign $atValue$j');
    response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    }
  });
 
}


