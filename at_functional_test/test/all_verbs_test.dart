import 'dart:io';

import 'package:test/test.dart';

import 'commons.dart';
import 'package:at_functional_test/conf/config_util.dart';

///The below test functions runs a complete flow of all verbs
void main() async {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  Socket? socketFirstAtsign;

// second atsign details
  var secondAtsign =
      ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'];

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

  test('update verb test $firstAtsign', () async {
    ///Update verb with public key
    await socket_writer(
        socketFirstAtsign!, 'update:public:mobile$firstAtsign 9988112343');
    var response = await read();
    print('update verb response $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///Update verb with private key
    await socket_writer(
        socketFirstAtsign!, 'update:@alice:email$firstAtsign bob@atsign.com');
    response = await read();
    print('update verb response $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
  });

  test('scan verb test $firstAtsign', () async {
    await socket_writer(socketFirstAtsign!, 'scan');
    var response = await read();
    print('scan verb response $response');
    expect(response, contains('"public:mobile$firstAtsign"'));
  });

  test('llookup verb test $firstAtsign', () async {
    await socket_writer(
        socketFirstAtsign!, 'llookup:public:mobile$firstAtsign');
    var response = await read();
    print('llookup verb response $response');
    expect(response, contains('data:9988112343'));
  });

  test('Delete verb test $firstAtsign', () async {
    await socket_writer(socketFirstAtsign!, 'delete:public:mobile$firstAtsign');
    var response = await read();
    print('Delete verb response $response');
    assert(!response.contains('data:null'));
  });

  test('scan verb test after delete $firstAtsign', () async {
    await socket_writer(socketFirstAtsign!, 'scan');
    var response = await read();
    print('scan verb response $response');
    expect(response, isNot('public:mobile$firstAtsign'));
  });

  test('config verb test -add block list $firstAtsign', () async {
    await socket_writer(socketFirstAtsign!, 'config:block:add:$secondAtsign');
    var response = await read();
    print('config verb response $response');
    expect(response, contains('data:success'));

    await socket_writer(socketFirstAtsign!, 'config:block:show');
    response = await read();
    print('config verb response $response');
    expect(response, contains('$secondAtsign'));
  });

  test('config verb test -remove from block list $firstAtsign', () async {
    await socket_writer(
        socketFirstAtsign!, 'config:block:remove:$secondAtsign');
    var response = await read();
    print('config verb response $response');
    expect(response, contains('data:success'));

    await socket_writer(socketFirstAtsign!, 'config:block:show');
    await Future.delayed(Duration(seconds: 2));
    response = await read();
    print('config verb response $response');
    expect(response, contains('data:null'));
  });
//FOR THESE TESTS TO WORK/PASS SET testingMode TO TRUE THROUGH ENV VARIABLES
//THE FOLLOWING TESTS ONLY WORK WHEN IN TESTING MODE
  test('config verb test set/reset operation', () async {
    if (Platform.environment.containsKey('testingMode') &&
            (Platform.environment['testingMode']!.toLowerCase() == 'true')
        ? true
        : false) {
      await socket_writer(
          socketFirstAtsign!, 'config:set:commitLogCompactionFrequencyMins=4');
      var response = await read();
      print('config verb response $response');
      expect(response, contains('data:ok'));

      await socket_writer(
          socketFirstAtsign!, 'config:reset:commitLogCompactionFrequencyMins');
      await Future.delayed(Duration(seconds: 2));
      response = await read();
      print('config verb response $response');
      expect(response, contains('data:ok'));
    } else {
      print(
          'asserting true forcefully. Set testingMode to true for the test to work');
    }
  });

  test('config verb test set/print', () async {
    print(Platform.environment);
    if (Platform.environment.containsKey('testingMode') &&
            (Platform.environment['testingMode']!.toLowerCase() == 'true')
        ? true
        : false) {
      await socket_writer(
          socketFirstAtsign!, 'config:set:maxNotificationRetries=25');
      var response = await read();
      print('config verb response $response');
      expect(response, contains('data:ok'));

      await socket_writer(
          socketFirstAtsign!, 'config:print:maxNotificationRetries');
      await Future.delayed(Duration(seconds: 2));
      response = await read();
      print('config verb response $response');
      expect(response, contains('data:25'));
    } else {
      print(
          'asserting true forcefully. Set testingMode to true for the test to work');
    }
  });

  tearDown(() {
    //Closing the socket connection
    clear();
    socketFirstAtsign!.destroy();
  });
}
