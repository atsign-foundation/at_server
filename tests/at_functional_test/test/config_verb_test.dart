import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'functional_test_commons.dart';
import 'package:at_functional_test/conf/config_util.dart';

void main() {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  Socket? socketFirstAtsign;

// second atsign details
  var secondAtsign =
      ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'];

  setUpAll(() async {
    var firstAtsignServer = ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    var firstAtsignPort =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);
  });

  test('config verb for adding a atsign to blocklist', () async {
    /// CONFIG VERB
    await socket_writer(
        socketFirstAtsign!, 'config:block:add:$secondAtsign');
    var response = await read();
    print('config verb response : $response');
    expect(response, contains('data:success'));

    ///CONFIG VERB -SHOW BLOCK LIST
    await socket_writer(socketFirstAtsign!, 'config:block:show');
    response = await read();
    print('config verb response $response');
    expect(response, contains('data:["$secondAtsign"]'));
  });

  test('config verb for deleting a atsign from blocklist', () async {
    /// CONFIG VERB
    await socket_writer(
        socketFirstAtsign!, 'config:block:add:$secondAtsign');
    var response = await read();
    print('config verb response : $response');
    expect(response, contains('data:success'));

    /// CONFIG VERB - REMOVE FROM BLOCKLIST
    await socket_writer(
        socketFirstAtsign!, 'config:block:remove:$secondAtsign');
    response = await read();
    print('config verb response : $response');
    expect(response, contains('data:success'));

    ///CONFIG VERB -SHOW BLOCK LIST
    await socket_writer(socketFirstAtsign!, 'config:block:show');
    response = await read();
    print('config verb response $response');
    expect(response, contains('data:null'));
  });

  test(
      'config verb for adding a atsign to blocklist without giving a atsign (Negative case)',
      () async {
    /// CONFIG VERB
    await socket_writer(socketFirstAtsign!, 'config:block:add:');
    var response = await read();
    response = response.replaceFirst('error:', '');
    var errorMap = jsonDecode(response);
    print('config verb response : $response');
    expect(errorMap['errorCode'], 'AT0003');
    assert(errorMap['errorDescription'].contains('Invalid syntax'));
  });

  test(
      'config verb for adding a atsign to blocklist by giving 2 @ in the atsign (Negative case)',
      () async {
    /// CONFIG VERB
    await socket_writer(socketFirstAtsign!, 'config:block:add:@@kevin');
    var response = await read();
    response = response.replaceFirst('error:', '');
    var errorMap = jsonDecode(response);
    print('config verb response : $response');
    expect(errorMap['errorCode'], 'AT0003');
    assert(errorMap['errorDescription'].contains('Invalid syntax'));
  });

  test('config verb by giving list instead of show (Negative case)', () async {
    /// CONFIG VERB
    await socket_writer(socketFirstAtsign!, 'config:block:list');
    var response = await read();
    response = response.replaceFirst('error:', '');
    var errorMap = jsonDecode(response);
    print('config verb response : $response');
    expect(errorMap['errorCode'], 'AT0003');
    assert(errorMap['errorDescription'].contains('Invalid syntax'));
  });

  test('Check that default telemetryEventWebHook is empty string', () async {
    await socket_writer(socketFirstAtsign!, 'config:reset:telemetryEventWebHook');
    var response = await read();
    expect(response.trim(), 'data:ok');

    // expect empty string
    await socket_writer(socketFirstAtsign!, 'config:print:telemetryEventWebHook');
    response = await read();
    expect(response.trim(), 'data:');

    // expect that there is no persisted value for the webhook uri
    await socket_writer(socketFirstAtsign!, 'llookup:local:telemetryEventWebHook$socketFirstAtsign');
    response = await read();
    response = response.replaceFirst('error:', '');
    var errorMap = jsonDecode(response);
    print('config verb response : $response');
    expect(errorMap['errorCode'], 'AT0015'); // KeyNotFound
  });

  test('Check that setting telemetryEventWebHook works', () async {
    String response;
    try {
      String uri = 'http://foo';

      await socket_writer(
          socketFirstAtsign!, 'config:set:telemetryEventWebHook:$uri');
      response = await read();
      expect(response.trim(), 'data:ok');

      // Expect it to have been set
      await socket_writer(
          socketFirstAtsign!, 'config:print:telemetryEventWebHook');
      response = await read();
      expect(response.trim(), 'data:$uri');

      // Expect it to have been persisted
      await socket_writer(socketFirstAtsign!,
          'llookup:local:telemetryEventWebHook$socketFirstAtsign');
      response = await read();
      expect(response.trim(), 'data:$uri');
    } finally {
      // Let's reset it again
      await socket_writer(
          socketFirstAtsign!, 'config:reset:telemetryEventWebHook');
      response = await read();
      expect(response.trim(), 'data:ok');
    }
  });

  tearDownAll(() {
    //Closing the client socket connection
    clear();
    socketFirstAtsign!.destroy();
  });
}
