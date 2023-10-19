import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'functional_test_commons.dart';

void main() async {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  Socket? socketFirstAtsign;

  setUp(() async {
    var firstAtsignServer =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    var firstAtsignPort =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);
  });

  test('llookup verb on a non-existent key', () async {
    ///lookup verb alice  atsign
    await socket_writer(socketFirstAtsign!,'llookup:random$firstAtsign');
    String response = await read();
    print('llookup verb response : $response');
    expect(response,
        contains('key not found : random$firstAtsign does not exist in keystore'));
  });


  test('update-lookup verb by giving wrong spelling - Negative case', () async {
    ///lookup verb
    await socket_writer(socketFirstAtsign!,'lokup:public:phone$firstAtsign');
    String response = await read();
    print('lookup verb response from : $response');
    expect(response, contains('Invalid syntax'));
  });

}
