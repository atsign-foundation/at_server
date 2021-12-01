import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'commons.dart';

void main() {
  
  Socket _socket;

  test('checking for test environment readiness', () async {
    var atsign = ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
    var atsign_url =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    var atsign_port = ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];
    print('root server url $atsign_url');
    await Future.delayed(Duration(seconds: 10));
    _socket = await secure_socket_connection(atsign_url, atsign_port);
    if (_socket != null) {
      print('connection established');
    }
    socket_listener(_socket);
    var response;
    while (response == null || response == 'data:null\n') {
      await socket_writer(_socket, 'lookup:signing_publickey$atsign');
      response = await read();
      print('waiting for signing public key response : $response');
      await Future.delayed(Duration(seconds: 5));
    }
    await _socket.close();
  }, timeout: Timeout(Duration(minutes: 5)));
}
