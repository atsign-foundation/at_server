import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';

void main() {
  OutboundConnectionFactory firstAtSignConnection = OutboundConnectionFactory();
  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  setUpAll(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
    String authResponse = await firstAtSignConnection.authenticateConnection();
    expect(authResponse, 'data:success', reason: 'Authentication failed when executing test');
  });

  test('update a lookup of a public key', () async {
    var updateKey = 'update:public:twitterid$firstAtSign';
    var updateValue = 'bob-twitter';
    String updateResponse = await firstAtSignConnection
        .sendRequestToServer('$updateKey  $updateValue');
    assert((!updateResponse.contains('Invalid syntax')) &&
        (!updateResponse.contains('null')));

    // llookup of reference key should display the updareref value
    String llookupResponse = await firstAtSignConnection
        .sendRequestToServer('llookup:public:twitterid$firstAtSign');
    expect(llookupResponse, contains(updateValue));
  });

  // Purpose of the tests
  // 1. update a public key with a value
  // 2. update a public reference key with ref to the above public key
  // 3. llookup of the reference key should display the value of the reference key
  // 4. lookup of the reference key without auth should display the value of the public key
  test('update and lookup of a public reference key', () async {
    var updateKey = 'update:public:landline$firstAtSign';
    var updateValue = '040-27502234';
    String updateResponse = await firstAtSignConnection
        .sendRequestToServer('$updateKey  $updateValue');
    assert((!updateResponse.contains('Invalid syntax')) &&
        (!updateResponse.contains('null')));

    // update a reference key
    var updaterefKey = 'update:public:landlineref$firstAtSign';
    var updaterefValue = 'atsign://landline$firstAtSign';
    updateResponse = await firstAtSignConnection
        .sendRequestToServer('$updaterefKey  $updaterefValue');
    assert((!updateResponse.contains('Invalid syntax')) &&
        (!updateResponse.contains('null')));

    // llookup of reference key should display the updareref value
    String llookupResponse = await firstAtSignConnection
        .sendRequestToServer('llookup:public:landlineref$firstAtSign');
    expect(llookupResponse, contains(updaterefValue));
    await firstAtSignConnection.close();

    // lookup of reference key should display the updatevalue
    // lookup of reference key without auth
    // looking up from a new socket connection without authentication
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
    String lookupResponse = await firstAtSignConnection
        .sendRequestToServer('lookup:landlineref$firstAtSign');
    expect(lookupResponse, contains(updateValue));
  });

  tearDownAll(() async {
    await firstAtSignConnection.close();
  });
}
