import 'dart:io';

import 'package:test/test.dart';

import 'commons.dart';
import 'package:at_functional_test/conf/config_util.dart';

void main() {
  var commitId;
  var first_atsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  Socket? _socket_first_atsign;

// second atsign details
  var second_atsign =
      ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'];

  setUp(() async {
    var first_atsign_server = ConfigUtil.getYaml()!['root_server']['url'];
    var first_atsign_port =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    _socket_first_atsign =
        await secure_socket_connection(first_atsign_server, first_atsign_port);
    socket_listener(_socket_first_atsign!);
    await prepare(_socket_first_atsign!, first_atsign);
  });

  test('stats verb returns result', () async {
    /// STATS VERB
    await socket_writer(
        _socket_first_atsign!, 'stats');
    var response = await read();
    print('stats verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
  });

  test('stats verb for id 3 ', () async {
    /// STATS VERB
    await socket_writer(
        _socket_first_atsign!, 'update:public:username$first_atsign Bob!');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    commitId = response.trim().replaceAll('data:', '');
    print(commitId);

    /// stats:3 verb response
    await socket_writer(
        _socket_first_atsign!, 'stats:3');
    response = await read();
    print('stats verb response : $response');
    expect(response, contains('[{"id":"3","name":"lastCommitID","value":"$commitId"'));
  });

  test('stats verb for invalid id ', () async {
    /// STATS VERB
    await socket_writer(
        _socket_first_atsign!, 'stats:-1');
    var response = await read();
    print('update verb response : $response');
    expect(response, contains('-Invalid syntax'));
  });

  test('stats verb for id 11 - Notification count ', () async {
    /// stats:11 verb response
    await socket_writer(
        _socket_first_atsign!, 'stats:11');
    var response = await read();
    print('stats verb response : $response');
    expect(response, contains('"name":"NotificationCount"'));
  });



  tearDown(() {
    //Closing the client socket connection
    clear();
    _socket_first_atsign!.destroy();
  });
}
