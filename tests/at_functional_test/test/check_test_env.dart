import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'functional_test_commons.dart';

void main() {
  SecureSocket _secureSocket;
  var rootServer = 'vip.ve.atsign.zone';
  var atsign = '@sitaram🛠';
  var atsignPort = 25017;

  test('checking for test environment readiness', () async {
    _secureSocket = await secure_socket_connection(rootServer, atsignPort);
    print('connection established');
    socket_listener(_secureSocket);
    String response = '';
    while (response.isEmpty || response.startsWith('error:')) {
      _secureSocket.write('lookup:pkaminstalled$atsign\n');
      response = await read();
      print('Waiting for PKAM keys to load : $response');
      await Future.delayed(Duration(seconds: 1));
    }
    await _secureSocket.close();
  }, timeout: Timeout(Duration(minutes: 1)));
}
