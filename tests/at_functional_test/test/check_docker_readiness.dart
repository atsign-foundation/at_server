import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  var atsign = '@sitaram🛠';
  // Match the port the ve entrypoint assigns to @sitaram🛠 when the VE runs on a
  // shifted base port (VIRTUALENV_BASE_PORT); default 25017 otherwise.
  const defaultAtsignPort = 25017;
  final basePort =
      int.tryParse(Platform.environment['VIRTUALENV_BASE_PORT'] ?? '');
  final atsignPort = basePort != null
      ? defaultAtsignPort + (basePort + 1 - 25000)
      : defaultAtsignPort;
  var rootServer = 'vip.ve.atsign.zone';
  String response = '';

  int maxRetryCount = 10;
  int retryCount = 1;

  SecureSocket? secureSocket;

  test('Checking for test environment readiness', () async {
    while (retryCount < maxRetryCount) {
      try {
        secureSocket = await SecureSocket.connect(rootServer, atsignPort);
      } on Exception {
        print(
            'Failed connecting to $rootServer:$atsignPort. Retrying for connection.. $retryCount');
        await Future.delayed(Duration(seconds: 1));
        retryCount = retryCount + 1;
      }
      if (secureSocket != null) {
        break;
      }
    }
    assert(secureSocket != null);

    secureSocket?.listen(expectAsync1((data) async {
      response = utf8.decode(data);
      // Ignore the '@' which is returned when connection is established.
      if (response == '@') {
        return;
      }
      response = response.replaceFirst('data:', '');
      await secureSocket?.close();
      expect(response.startsWith('null'), false);
      print('All atSign are up and running');
    }, count: 2));
    secureSocket?.write('lookup:signing_publickey$atsign\n');
  });
}
