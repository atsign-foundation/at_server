import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'commons.dart';


// This test is not working

void main() {
  var alice_atsign = '@alice🛠';
  var alice_secondary_port = 8000;

  var bob_atsign = '@bob🛠';
  var bob_secondary_port = 9000;

  Socket bob_client;
  Socket alice_client;

  setUp(() async {
    var root_server_domain = ConfigUtil.getYaml()['root_server']['url'];
    bob_client = await secure_socket_connection(root_server_domain, bob_secondary_port);
    socket_listener(bob_client);
    await prepare(bob_client, bob_atsign);

    alice_client = await secure_socket_connection(root_server_domain, alice_secondary_port);
    socket_listener(alice_client);
    await prepare(alice_client, alice_atsign);
  });

  group('A group of monitor verb without regex or timestamp tests', () {

    test('Test one update and monitor', () async {
      await socket_writer(alice_client, 'monitor');
      await socket_writer(bob_client, 'update:@alice🛠:phone@bob🛠 1234');
      var bob_client_response = await read();

      await Future.delayed(Duration(seconds: 5));
      var alice_client_response = await read();
      expect(alice_client_response, contains('@alice🛠:phone@bob🛠'));
    }, timeout: Timeout(Duration(seconds: 100000)));
  });
}