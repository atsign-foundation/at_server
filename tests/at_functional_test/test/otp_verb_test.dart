import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'functional_test_commons.dart';

void main() {
  late SecureSocket authenticatedConnection;
  String firstAtSignServer =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
  int firstAtSignPort =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];
  String firstAtSign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];

  setUp(() async {
    authenticatedConnection =
        await secure_socket_connection(firstAtSignServer, firstAtSignPort);
    socket_listener(authenticatedConnection);
  });

  group('A group of tests related to OTP generation and expiration', () {
    test('A test to generate OTP and returns valid before OTP is not expired',
        () async {
      await prepare(authenticatedConnection, firstAtSign);
      await socket_writer(authenticatedConnection,
          'otp:get:ttl:${Duration(minutes: 1).inMilliseconds}');
      String otp = (await read()).trim().replaceAll('data:', '');
      expect(otp, isNotEmpty);

      await socket_writer(authenticatedConnection, 'otp:validate:$otp');
      String response = (await read()).replaceAll('data:', '').trim();
      expect(response, 'valid');
    });

    test('A test to generate OTP and returns invalid when TTL is met',
        () async {
      await prepare(authenticatedConnection, firstAtSign);
      await socket_writer(authenticatedConnection, 'otp:get:ttl:1');
      String otp = (await read()).trim().replaceAll('data:', '');
      expect(otp, isNotEmpty);

      await Future.delayed(Duration(seconds: 1));
      await socket_writer(authenticatedConnection, 'otp:validate:$otp');
      String response = (await read()).replaceAll('data:', '').trim();
      expect(response, 'invalid');
    });
  });
}
