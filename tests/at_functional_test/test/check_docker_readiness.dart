import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

var maxRetryCount = 10;
var retryCount = 1;

void main() {
  var atsign = '@sitaram🛠';
  var atsignPort = 25017;
  var rootServer = 'vip.ve.atsign.zone';
  String response = '';

  SecureSocket _secureSocket;

  test('checking for test environment readiness', () async {
    _secureSocket = await SecureSocket.connect(rootServer, atsignPort);
    _secureSocket.listen(expectAsync1((data) async {
      response = utf8.decode(data);
      // Ignore the '@' which is returned when connection is established.
      if(response == '@'){
        return;
      }
      print('waiting for signing public key response : $response');
      response = response.replaceFirst('data:', '');
      _secureSocket.close();
      expect(response.startsWith('null'), false);
    }, count: 2));
    _secureSocket.write('lookup:signing_publickey$atsign\n');
  });
}
