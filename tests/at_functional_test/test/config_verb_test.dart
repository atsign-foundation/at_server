import 'dart:convert';
import 'package:at_commons/at_commons.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/connection_type_util.dart';
import 'package:test/test.dart';
import 'package:at_functional_test/conf/config_util.dart';

void main() {
  OutboundConnectionFactory firstAtSignConnection = OutboundConnectionFactory();
  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  String firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];
  ConnectionType firstConnectionType =
      ConnectionTypeUtil.getConnectionType('firstAtSignServer');

  String secondAtSign =
      ConfigUtil.getYaml()!['secondAtSignServer']['secondAtSignName'];

  SecureSocketConfig secureSocketConfig = SecureSocketConfig();
  secureSocketConfig.decryptPackets = false;

  setUpAll(() async {
     await firstAtSignConnection.initiateConnection(
        firstAtSign, firstAtSignHost, firstAtSignPort,
        connectionType: firstConnectionType,
        secureSocketConfig: secureSocketConfig);
    String authResponse = await firstAtSignConnection.authenticateConnection();
    expect(authResponse, 'data:success', reason: 'Authentication failed when executing test');
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

  tearDownAll(() {
    firstAtSignConnection.close();
  });
}
