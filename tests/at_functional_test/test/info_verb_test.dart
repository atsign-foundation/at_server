// ignore_for_file: unused_import

import 'dart:convert';
import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'at_demo_data.dart';
import 'functional_test_commons.dart';
import 'pkam_utils.dart';

void main() {
  // ignore: unused_local_variable
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
  });

  test('info verb test without authentication', () async {
    await socket_writer(socketFirstAtsign!, 'info');
    var infoVerbResponse = await read();
    print('info verb response : $infoVerbResponse');
    infoVerbResponse = infoVerbResponse.replaceAll('data:', '');
    var infoResponse = jsonDecode(infoVerbResponse);
    expect(infoResponse['version'], isNotEmpty);
  });

  // commenting the test as the server doesn't have enroll verb changes yet
  // test('info verb with enroll verb changes', () async {
  //   await socket_writer(socketFirstAtsign!, 'from:$firstAtsign');
  //   var fromResponse = await read();
  //   print('from verb response : $fromResponse');
  //   fromResponse = fromResponse.replaceAll('data:', '');
  //   var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
  //   await socket_writer(socketFirstAtsign!, 'pkam:$pkamDigest');
  //   var pkamResult = await read();
  //   expect(pkamResult, 'data:success\n');

  //   // create a key with the _manage namespace
  //   var enrollRequest =
  //       'enroll:request:appName:wavi:deviceName:pixel:namespaces:[wavi,rw]:apkamPublicKey:${pkamPublicKeyMap[firstAtsign]!}\n';
  //   await socket_writer(socketFirstAtsign!, enrollRequest);
  //   var enrollResponse = await read();
  //   print(enrollResponse);
  //   enrollResponse = enrollResponse.replaceFirst('data:', '');
  //   var enrollJsonMap = jsonDecode(enrollResponse);
  //   expect(enrollJsonMap['enrollmentId'], isNotEmpty);

  //   // check the info verb.. It should return the result
  //   await socket_writer(socketFirstAtsign!, 'info');
  //   var infoVerbResponse = await read();
  //   print('info verb response : $infoVerbResponse');
  //   infoVerbResponse = infoVerbResponse.replaceAll('data:', '');
  //   var infoResponse = jsonDecode(infoVerbResponse);
  //   expect(infoResponse['apkam_metadata'], isNotEmpty);
  // });
}
