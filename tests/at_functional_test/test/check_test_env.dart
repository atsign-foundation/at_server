import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  SecureSocket _secureSocket;
  var rootServer = 'vip.ve.atsign.zone';
  var atsign = '@sitaram🛠';
  var atsignPort = 25017;
  int maxRetryCount = 10;
  int retryCount = 1;

  String response = '';

  test('checking for test environment readiness', () async {
    _secureSocket = await SecureSocket.connect(rootServer, atsignPort);
    _secureSocket.listen((data) async {
      response = utf8.decode(data);
      if (response == '@') {
        return;
      }
      print('Waiting for PKAM keys to load : $response');
      if (response.startsWith('error') && retryCount <= maxRetryCount) {
        retryCount = retryCount + 1;
        await Future.delayed(Duration(seconds: 1));
        _secureSocket.write('lookup:pkaminstalled$atsign\n');
        return;
      }
      expect(response.startsWith('data:yes'), true);
    });
    _secureSocket.write('lookup:pkaminstalled$atsign\n');
  });
}
