import 'dart:convert';
import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';
import 'package:version/version.dart';

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

  test('plookup with an extra symbols after the atsign', () async {
    ///PLOOKUP VERB
    await socket_writer(socketFirstAtsign!,'plookup:emoji-color$firstAtsign@@@');
    String response = await read();
    print('plookup verb response $response');
    expect(response, contains('Invalid syntax'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('plookup verb on non existent key - negative case', () async {
    ///PLOOKUP VERB
    await socket_writer(socketFirstAtsign!,'plookup:no-key$firstAtsign');
    var response = await read();
    var version = await getVersion(socketFirstAtsign!);
    print(version);
    var serverResponse = Version.parse(await getVersion(socketFirstAtsign!));
    if (serverResponse > Version(3, 0, 24)) {
      response = response.replaceFirst('error:', '');
      var errorMap = jsonDecode(response);
      expect(errorMap['errorCode'], 'AT0011');
      expect(errorMap['errorDescription'],
          contains('public:no-key$firstAtsign does not exist in keystore'));
    } else {
      expect(response,
          contains('public:no-key$firstAtsign does not exist in keystore'));
    }
  }, timeout: Timeout(Duration(seconds: 120)));
}
