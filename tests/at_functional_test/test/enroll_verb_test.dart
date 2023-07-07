import 'dart:convert';
import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'at_demo_data.dart';
import 'functional_test_commons.dart';
import 'pkam_utils.dart';

Socket? socketFirstAtsign;
Future<void> _connect() async {
  var firstAtsignServer =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
  var firstAtsignPort =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

  // socket connection for first atsign
  socketFirstAtsign =
      await secure_socket_connection(firstAtsignServer, firstAtsignPort);
  socket_listener(socketFirstAtsign!);
}

void main() {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];

  //Establish the client socket connection
  setUp(() async {
    await _connect();
  });

  group('A group of tests to verify apkam enroll requests', () {
    test('enroll request on authenticated connection', () async {
      await socket_writer(socketFirstAtsign!, 'from:$firstAtsign');
      var fromResponse = await read();
      print('from verb response : $fromResponse');
      fromResponse = fromResponse.replaceAll('data:', '');
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      await socket_writer(socketFirstAtsign!, 'pkam:$pkamDigest');
      var pkamResult = await read();
      expect(pkamResult, 'data:success\n');
      var enrollRequest =
          'enroll:request:appName:wavi:deviceName:pixel:namespaces:[wavi,rw]:apkamPublicKey:${pkamPublicKeyMap[firstAtsign]!}\n';
      await socket_writer(socketFirstAtsign!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'success');
    });

    test('enroll request on unauthenticated connection without totp', () async {
      var enrollRequest =
          'enroll:request:appName:wavi:deviceName:pixel:namespaces:[wavi,rw]:apkamPublicKey:${pkamPublicKeyMap[firstAtsign]!}\n';
      await socket_writer(socketFirstAtsign!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['status'], 'exception');
      expect(enrollJsonMap['reason'],
          'Exception: invalid totp. Cannot process enroll request');
    });

    test('enroll request on unauthenticated connection invalid totp', () async {
      var enrollRequest =
          'enroll:request:appName:wavi:deviceName:pixel:namespaces:[wavi,rw]:totp:1234:apkamPublicKey:${pkamPublicKeyMap[firstAtsign]!}\n';
      await socket_writer(socketFirstAtsign!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['status'], 'exception');
      expect(enrollJsonMap['reason'],
          'Exception: invalid totp. Cannot process enroll request');
    });

    test('second enroll request using totp', () async {
      await socket_writer(socketFirstAtsign!, 'from:$firstAtsign');
      var fromResponse = await read();
      print('from verb response : $fromResponse');
      fromResponse = fromResponse.replaceAll('data:', '');
      var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
      await socket_writer(socketFirstAtsign!, 'pkam:$pkamDigest');
      var pkamResult = await read();
      expect(pkamResult, 'data:success\n');
      var enrollRequest =
          'enroll:request:appName:wavi:deviceName:pixel:namespaces:[wavi,rw]:apkamPublicKey:${pkamPublicKeyMap[firstAtsign]!}\n';
      await socket_writer(socketFirstAtsign!, enrollRequest);
      var enrollResponse = await read();
      print(enrollResponse);
      enrollResponse = enrollResponse.replaceFirst('data:', '');
      var enrollJsonMap = jsonDecode(enrollResponse);
      expect(enrollJsonMap['enrollmentId'], isNotEmpty);
      expect(enrollJsonMap['status'], 'success');
      // final enrollmentId = enrollJsonMap['enrollmentId'];
      var totpRequest = 'totp:get\n';
      await socket_writer(socketFirstAtsign!, totpRequest);
      var totpResponse = await read();
      totpResponse = totpResponse.replaceFirst('data:', '');
      print(totpResponse);
      totpResponse = totpResponse.trim();
      //destroy the authenticated connection
      socketFirstAtsign!.destroy();
      print('socket destroyed');
      await _connect();
      //send second enroll request with totp
      var apkamPublicKey = apkamPublicKeyMap[firstAtsign];
      var secondEnrollRequest =
          'enroll:request:appName:buzz:deviceName:pixel:namespaces:[buzz,rw]:totp:$totpResponse:apkamPublicKey:$apkamPublicKey\n';
      print(secondEnrollRequest);
      await socket_writer(socketFirstAtsign!, secondEnrollRequest);

      var secondEnrollResponse = await read();
      print(secondEnrollResponse);
      var enrollJson = jsonDecode(secondEnrollResponse);
      expect(enrollJson['enrollmentId'], isNotEmpty);
      expect(enrollJson['status'], 'pending');
    });
  });
}
