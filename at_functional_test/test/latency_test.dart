import 'package:test/test.dart';
import 'commons.dart';
import 'dart:io';
import 'package:at_functional_test/conf/config_util.dart';

void main() {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  var secondAtsign =
      ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'];

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


test('updating a key and verifying the time taken', () async {
    String response;
    var timeBeforeUpdate = DateTime.now().millisecondsSinceEpoch;
    String updateCommand = 'update:public:location$firstAtsign Hyderabad';
    await socket_writer(
        socketFirstAtsign!, updateCommand);
    response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    var timeAfterUpdate = DateTime.now().millisecondsSinceEpoch;
    timeDifference(timeBeforeUpdate, timeAfterUpdate);
  });

  test('Lookup should be less than a second for a given key', () async {
    String response;
    String atKey = 'discord$firstAtsign'; 
    String value = 'user_1';
    await socket_writer(
        socketFirstAtsign!, 'update:public:$atKey $value');
    response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    var timeBeforeLookup = DateTime.now().millisecondsSinceEpoch;
    await socket_writer(socketFirstAtsign!, 'llookup:public:$atKey');
    response = await read();
    expect(response, contains('data:$value'));
    var timeAfterLookup = DateTime.now().millisecondsSinceEpoch;
    timeDifference(timeBeforeLookup, timeAfterLookup);
  });

  test('delete a key and verifying the time taken', () async {
    String response;
    var timeBeforeDelete = DateTime.now().millisecondsSinceEpoch;
    String deleteCommand = 'delete:public:location$firstAtsign';
    await socket_writer(
        socketFirstAtsign!, deleteCommand);
    response = await read();
    print('delete verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    var timeAfterDelete = DateTime.now().millisecondsSinceEpoch;
    timeDifference(timeBeforeDelete, timeAfterDelete);
  });

  test('notify a key and verifying the time taken', () async {
    String response;
    var timeBeforeNotification = DateTime.now().millisecondsSinceEpoch;
    await socket_writer(
        socketFirstAtsign!, 'notify:update:messageType:key:$secondAtsign:company$firstAtsign:atsign');
    response = await read();
    print('notify verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    var timeAfterNotification = DateTime.now().millisecondsSinceEpoch;
    timeDifference(timeBeforeNotification, timeAfterNotification);
  });

  test('stats verb and verifying the time taken to get the response', () async {
    String response;
    var timeBeforeStats = DateTime.now().millisecondsSinceEpoch;
    await socket_writer(
        socketFirstAtsign!, 'stats:3');
    response = await read();
    print('stats verb response : $response');
    assert(response.contains('"name":"lastCommitID"'));
    var timeAfterStats = DateTime.now().millisecondsSinceEpoch;
    timeDifference(timeBeforeStats, timeAfterStats);
  });
}


// calculates the time difference between command before and after execution
Future<void> timeDifference(var beforeCommand, var afterCommand) async {
  var timeDifferenceValue = DateTime.fromMillisecondsSinceEpoch(afterCommand).difference(DateTime.fromMillisecondsSinceEpoch(beforeCommand));
  expect(timeDifferenceValue.inMilliseconds<= 1500, true);
  print('time difference is $timeDifferenceValue');
}