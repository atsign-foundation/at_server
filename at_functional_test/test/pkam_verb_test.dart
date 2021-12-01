import 'dart:io';

import 'package:test/test.dart';

import 'commons.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'pkam_utils.dart';

void main() {
  var first_atsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  Socket? _socket_first_atsign;

  setUp(() async {
    var first_atsign_server = ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    var first_atsign_port =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    _socket_first_atsign =
        await secure_socket_connection(first_atsign_server, first_atsign_port);
    socket_listener(_socket_first_atsign!);
  });

  test('pkam verb test - auth success', () async {
    ///From verb
    await socket_writer(_socket_first_atsign!, 'from:$first_atsign');
    var response = await read();
    print('from verb response : $response');
    assert(response != null);
    response = response.replaceAll('data:', '');
    var pkam_digest = generatePKAMDigest(first_atsign, response);

    ///PKAM Verb
    await socket_writer(_socket_first_atsign!, 'pkam:$pkam_digest');
    response = await read();
    print('pkam verb response : $response');
    expect(response, contains('data:success'));
  });
}
