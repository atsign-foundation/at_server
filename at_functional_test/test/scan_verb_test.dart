import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'commons.dart';

void main() {
  var firstAtSign = '@bob🛠';
  var firstAtSignPort = 25003;

  Socket socketFirstAtSign;

  test('Scan verb after authentication', () async {
    var rootServer = ConfigUtil.getYaml()['root_server']['url'];
    socketFirstAtSign =
        await secureSocketConnection(rootServer, firstAtSignPort);
    socketListener(socketFirstAtSign);
    await prepare(socketFirstAtSign, firstAtSign);

    ///UPDATE VERB
    await socketWriter(
        socketFirstAtSign, 'update:public:location$firstAtSign California');
    var response = await read();
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///SCAN VERB
    await socketWriter(socketFirstAtSign, 'scan');
    response = await read();
    print('scan verb response : $response');
    expect(response, contains('"public:location$firstAtSign"'));
  });

  tearDown(() {
    //Closing the client socket connection
    socketFirstAtSign.destroy();
  });
}
