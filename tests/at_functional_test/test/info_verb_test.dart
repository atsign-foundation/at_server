// ignore_for_file: unused_import

import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';
import 'package:version/version.dart';

import 'at_demo_data.dart';
import 'functional_test_commons.dart';
import 'pkam_utils.dart';

void main() {
  // ignore: unused_local_variable
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  Socket? socketFirstAtsign;
  String firstAtsignServer = '';
  int firstAtsignPort = 0;

  setUp(() async {
    firstAtsignServer =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    firstAtsignPort =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
  });

  test('info verb test without authentication', () async {
    await socket_writer(socketFirstAtsign!, 'info');
    var infoVerbResponse = await read();
    infoVerbResponse = infoVerbResponse.replaceAll('data:', '');
    var infoResponse = jsonDecode(infoVerbResponse);
    expect(infoResponse['version'], isNotEmpty);
  });

  test('info verb with enroll verb changes', () async {
    await socket_writer(socketFirstAtsign!, 'from:$firstAtsign');
    var fromResponse = await read();
    fromResponse = fromResponse.replaceAll('data:', '');
    var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
    await socket_writer(socketFirstAtsign!, 'pkam:$pkamDigest');
    var pkamResult = await read();
    expect(pkamResult, 'data:success\n');

    // create a key with the _manage namespace
    var enrollRequest =
        'enroll:request:{"appName":"wavi","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${pkamPublicKeyMap[firstAtsign]!}"}\n';
    await socket_writer(socketFirstAtsign!, enrollRequest);
    var enrollResponse = await read();
    enrollResponse = enrollResponse.replaceFirst('data:', '');
    var enrollJsonMap = jsonDecode(enrollResponse);
    expect(enrollJsonMap['enrollmentId'], isNotEmpty);
    String enrollmentId = enrollJsonMap['enrollmentId'].toString().trim();
    // Approve enrollment
    await socket_writer(
        socketFirstAtsign!, 'enroll:approve:{"enrollmentId":"$enrollmentId"}');
    enrollResponse = await read();
    enrollResponse = enrollResponse.replaceFirst('data:', '');
    await socketFirstAtsign?.close();

    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await socket_writer(socketFirstAtsign!, 'from:$firstAtsign');
    fromResponse = await read();
    fromResponse = fromResponse.replaceAll('data:', '');
    pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
    // Authenticate the connection via enrollmentId to fetch the APKAM metadata
    await socket_writer(
        socketFirstAtsign!, 'pkam:enrollmentId:$enrollmentId:$pkamDigest');
    pkamResult = await read();
    expect(pkamResult, 'data:success\n');

    // check the info verb.. It should return the result
    await socket_writer(socketFirstAtsign!, 'info');
    var infoVerbResponse = await read();
    infoVerbResponse = infoVerbResponse.replaceAll('data:', '');
    var infoResponse = jsonDecode(infoVerbResponse);
    expect(infoResponse['apkam_metadata'], isNotEmpty);
    var apkamMetadata = jsonDecode(infoResponse['apkam_metadata']);
    // Assert the APKAM metadata
    expect(apkamMetadata['appName'], 'wavi');
    expect(apkamMetadata['deviceName'], 'pixel');
    expect(apkamMetadata['namespaces'], {"wavi": "rw"});
    expect(apkamMetadata['sessionId'], isNotNull);
    expect(apkamMetadata['apkamPublicKey'], isNotNull);
  });
}
