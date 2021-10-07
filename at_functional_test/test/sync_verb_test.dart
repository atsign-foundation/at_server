import 'dart:io';

import 'package:test/test.dart';

import 'commons.dart';
import 'package:at_functional_test/conf/config_util.dart';

void main() {
  var first_atsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  Socket? _socket_first_atsign;

  setUp(() async {
    var first_atsign_server = ConfigUtil.getYaml()!['root_server']['url'];
    var first_atsign_port =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    _socket_first_atsign =
        await secure_socket_connection(first_atsign_server, first_atsign_port);
    socket_listener(_socket_first_atsign!);
    await prepare(_socket_first_atsign!, first_atsign);
  });

  test('sync verb ', () async {
    /// UPDATE VERB
    await socket_writer(
        _socket_first_atsign!, 'update:public:location$first_atsign Hyderabad');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    var commitId = response.replaceAll('data:', '');
    var syncId = int.parse(commitId);

    // sync with commit Id
    await socket_writer(_socket_first_atsign!, 'sync:${syncId - 1}');
    response = await read();
    print('sync response is : $response');
    assert(response.contains('"atKey":"public:location$first_atsign'));
  });

  test('sync verb with regex ', () async {
    /// UPDATE VERB
    await socket_writer(_socket_first_atsign!,
        'update:public:twitter.persona$first_atsign bob_tweet');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    var commitId = response.replaceAll('data:', '');
    var syncId = int.parse(commitId);
    var regex = '.persona';

    // sync with regex
    await socket_writer(_socket_first_atsign!, 'sync:${syncId - 1}:$regex');
    response = await read();
    print('sync response is : $response');
    assert((response.contains('"atKey":"public:twitter$regex$first_atsign')) &&
        (!response.contains('"atKey":"public:location$first_atsign')));
  });

  // sync negative scenario
  test('sync verb with only regex and no commit Id ', () async {
    /// UPDATE VERB
    var regex = '.buzz@';
    await socket_writer(_socket_first_atsign!, 'sync:$regex');
    var response = await read();
    print('update verb response : $response');
    assert((response.contains('Invalid syntax')));
  });

  test('sync verb in an incorrect format ', () async {
    /// UPDATE VERB
    var regex = '.buzz@';
    await socket_writer(_socket_first_atsign!, 'sync $regex');
    var response = await read();
    print('update verb response : $response');
    assert((response.contains('Invalid syntax')));
  });

  tearDown(() {
    //Closing the client socket connection
    clear();
    _socket_first_atsign!.destroy();
  });
}
