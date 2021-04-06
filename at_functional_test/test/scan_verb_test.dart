import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'commons.dart';

void main() {
  var first_atsign = '@bob🛠';
  var first_atsign_port = 25003;

  Socket _socket_first_atsign;

  test('Scan verb after authentication', () async {
    var root_server = ConfigUtil.getYaml()['root_server']['url'];
    _socket_first_atsign =
        await secure_socket_connection(root_server, first_atsign_port);
    socket_listener(_socket_first_atsign);
    await prepare(_socket_first_atsign, first_atsign);

    ///UPDATE VERB
    await socket_writer(
        _socket_first_atsign, 'update:public:location$first_atsign California');
    var response = await read();
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///SCAN VERB
    await socket_writer(_socket_first_atsign, 'scan');
    response = await read();
    print('scan verb response : $response');
    expect(response, contains('"public:location$first_atsign"'));
  });

  tearDown(() {
    //Closing the client socket connection
    _socket_first_atsign.destroy();
  });
}
