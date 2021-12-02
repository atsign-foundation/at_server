import 'dart:io';

import 'package:test/test.dart';

import 'commons.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'pkam_utils.dart';

void main() {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  Socket? socketFirstAtsign;

  setUp(() async {
    var firstAtsignServer = ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    var firstAtsignPort =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
  });

  test('pkam verb test - auth success', () async {
    ///From verb
    await socket_writer(socketFirstAtsign!, 'from:$firstAtsign');
    var response = await read();
    print('from verb response : $response');
    response = response.replaceAll('data:', '');
    var pkamDigest = generatePKAMDigest(firstAtsign, response);

    ///PKAM Verb
    await socket_writer(socketFirstAtsign!, 'pkam:$pkamDigest');
    response = await read();
    print('pkam verb response : $response');
    expect(response, contains('data:success'));
  });
}
