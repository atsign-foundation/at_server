import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  var atsign = '@sitaram🛠';
  var atsignPort = 25017;
  var rootServer = 'vip.ve.atsign.zone';
  String response = '';

  int maxRetryCount = 10;
  int retryCount = 1;

  SecureSocket? _secureSocket;

  test('Checking for test environment readiness', () async {
    while (retryCount < maxRetryCount) {
      try {
        _secureSocket = await SecureSocket.connect(rootServer, atsignPort);
      } on Exception {
        print(
            'Failed connecting to $rootServer:$atsignPort. Retrying for connection.. $retryCount');
        await Future.delayed(Duration(seconds: 1));
        retryCount = retryCount + 1;
      }
      if (_secureSocket != null) {
        break;
      }
    }
    assert(_secureSocket != null);

    _secureSocket?.listen(expectAsync1((data) async {
      response = utf8.decode(data);
      // Ignore the '@' which is returned when connection is established.
      if (response == '@') {
        return;
      }
      response = response.replaceFirst('data:', '');
      await _secureSocket?.close();
      expect(response.startsWith('null'), false);
      print('All atSign are up and running');
    }, count: 2));
    _secureSocket?.write('lookup:signing_publickey$atsign\n');
  });
}
