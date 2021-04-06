import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'commons.dart';

void main() {
  var atsign = '@bob🛠';
  var atsign_port = 25003;

  Socket _socket;

  test('checking for test environment readiness', () async {
    var root_server = ConfigUtil.getYaml()['root_server']['url'];
    await Future.delayed(Duration(seconds: 10));
    _socket = await secure_socket_connection(root_server, atsign_port);
    if (_socket != null) {
      print('connection established');
    }
    socket_listener(_socket);
    var response;
    while (response == null || response == 'data:null\n') {
      await socket_writer(_socket, 'lookup:publickey$atsign');
      response = await read();
      print('waiting for lookup public key response : $response');
      await Future.delayed(Duration(seconds: 5));
    }
    await _socket.close();
  }, timeout: Timeout(Duration(minutes: 5)));
}
