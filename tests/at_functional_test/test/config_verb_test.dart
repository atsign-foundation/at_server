import 'dart:convert';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';
import 'package:at_functional_test/conf/config_util.dart';

void main() {
  OutboundConnectionFactory firstAtSignConnection = OutboundConnectionFactory();
  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  String secondAtSign =
      ConfigUtil.getYaml()!['secondAtSignServer']['secondAtSignName'];

  setUpAll(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
    String authResponse = await firstAtSignConnection.authenticateConnection();
    expect(authResponse, 'data:success',
        reason: 'Authentication failed when executing test');
  });

  test('config verb for adding a atsign to blocklist', () async {
    /// CONFIG VERB
    String response = await firstAtSignConnection
        .sendRequestToServer('config:block:add:$secondAtSign');
    expect(response, contains('data:success'));

    ///CONFIG VERB -SHOW BLOCK LIST
    response =
        await firstAtSignConnection.sendRequestToServer('config:block:show');
    expect(response, contains('data:["$secondAtSign"]'));
  });

  test('config verb for deleting a atsign from blocklist', () async {
    /// CONFIG VERB
    String response = await firstAtSignConnection
        .sendRequestToServer('config:block:add:$secondAtSign');
    expect(response, contains('data:success'));

    /// CONFIG VERB - REMOVE FROM BLOCKLIST
    response = await firstAtSignConnection
        .sendRequestToServer('config:block:remove:$secondAtSign');
    expect(response, contains('data:success'));

    ///CONFIG VERB -SHOW BLOCK LIST
    response =
        await firstAtSignConnection.sendRequestToServer('config:block:show');
    expect(response, contains('data:null'));
  });

  test(
      'config verb for adding a atsign to blocklist without giving a atsign (Negative case)',
      () async {
    /// CONFIG VERB
    String response =
        await firstAtSignConnection.sendRequestToServer('config:block:add:');
    response = response.replaceFirst('error:', '');
    var errorMap = jsonDecode(response);
    expect(errorMap['errorCode'], 'AT0003');
    assert(errorMap['errorDescription'].contains('Invalid syntax'));
  });

  test(
      'config verb for adding a atsign to blocklist by giving 2 @ in the atsign (Negative case)',
      () async {
    /// CONFIG VERB
    String response = await firstAtSignConnection
        .sendRequestToServer('config:block:add:@@kevin');
    response = response.replaceFirst('error:', '');
    var errorMap = jsonDecode(response);
    expect(errorMap['errorCode'], 'AT0003');
    assert(errorMap['errorDescription'].contains('Invalid syntax'));
  });

  test('config verb by giving list instead of show (Negative case)', () async {
    /// CONFIG VERB
    String response =
        await firstAtSignConnection.sendRequestToServer('config:block:list');
    response = response.replaceFirst('error:', '');
    var errorMap = jsonDecode(response);
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
    await socket_writer(socketFirstAtsign!, 'llookup:local:telemetryEventWebHook$firstAtsign');
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
          socketFirstAtsign!, 'config:set:telemetryEventWebHook=$uri');
      response = await read();
      expect(response.trim(), 'data:ok');

      // Expect it to have been set
      await socket_writer(
          socketFirstAtsign!, 'config:print:telemetryEventWebHook');
      response = await read();
      expect(response.trim(), 'data:$uri');

      // Expect it to have been persisted
      await socket_writer(socketFirstAtsign!,
          'llookup:local:telemetryEventWebHook$firstAtsign');
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
    firstAtSignConnection.close();
  });
}
