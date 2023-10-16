import 'dart:io';

import 'package:test/test.dart';

import 'functional_test_commons.dart';

void main() {
  SecureSocket _secureSocket;
  var rootServer = 'vip.ve.atsign.zone';
  var atsign = '@sitaram🛠';
  var atsignPort = 25017;
  bool arePKAMKeysLoaded = false;
  int maxRetryCount = 10;
  int retryCount = 1;

  test('checking for test environment readiness', () async {
    _secureSocket = await secure_socket_connection(rootServer, atsignPort);
    print('connection established');
    socket_listener(_secureSocket);
    String response = '';
    while ((retryCount < maxRetryCount) &&
        (response.isEmpty || response.startsWith('error:'))) {
      _secureSocket.write('lookup:pkaminstalled$atsign\n');
      response = await read();
      print('Waiting for PKAM keys to load : $response');
      if (response.startsWith('data:')) {
        arePKAMKeysLoaded = true;
        break;
      }
      await Future.delayed(Duration(seconds: 1));
    }
    await _secureSocket.close();
    expect(arePKAMKeysLoaded, true,
        reason: 'PKAM Keys are not loaded successfully');
  });
}
