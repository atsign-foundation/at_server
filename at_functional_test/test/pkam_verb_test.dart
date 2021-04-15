import 'dart:io';

import 'package:test/test.dart';

import 'commons.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'pkam_utils.dart';


void main() {
  Socket _socket_atsign;
  
  var atsign = '@alice🛠';
  var atsign_port = 25000;

  //Establish the client socket connection
  setUp(() async {
    var root_server = ConfigUtil.getYaml()['root_server']['url'];
    _socket_atsign =
        await secure_socket_connection(root_server, atsign_port);
    socket_listener(_socket_atsign);
  });

  test('pkam verb test - auth success',
      () async {
    ///From verb
    await socket_writer(_socket_atsign, 'from:$atsign');
    var response = await read();
    print('from verb response : $response');
    assert(response != null);
    response = response.replaceAll('data:','');
    var pkam_digest = generatePKAMDigest(atsign,response);

    ///PKAM Verb
    await socket_writer(_socket_atsign, 'pkam:$pkam_digest');
    response = await read();
    print('pkam verb response : $response');
    expect(response, contains('data:success'));
  });
}
