import 'dart:io';

import 'package:test/test.dart';

import 'functional_test_commons.dart';

var maxRetryCount = 10;
var retryCount = 1;

void main() {
  var atsign = '@sitaram🛠';
  var atsignPort = 25017;
  var rootServer = 'vip.ve.atsign.zone';

  SecureSocket _secureSocket;

  test('checking for test environment readiness', () async {
    _secureSocket = await secure_socket_connection(rootServer, atsignPort);
    socket_listener(_secureSocket);
    String response = '';
    while ((retryCount < maxRetryCount) &&
        (response.isEmpty || response == 'data:null\n')) {
      _secureSocket.write('lookup:signing_publickey$atsign\n');
      response = await read();
      print('waiting for signing public key response : $response');
      await Future.delayed(Duration(milliseconds: 100));
      if (response.startsWith('data:')) {
        break;
      }
    }
    await _secureSocket.close();
    expect(response.startsWith('data:'), true);
  });
}
