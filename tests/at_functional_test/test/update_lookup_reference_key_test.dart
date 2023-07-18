import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'functional_test_commons.dart';
import 'pkam_utils.dart';

Socket? socketConnection1;

var firstAtsignServer =
    ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
var firstAtsignPort =
    ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

Future<void> _connect() async {
  // socket connection for first atsign
  socketConnection1 =
      await secure_socket_connection(firstAtsignServer, firstAtsignPort);
  socket_listener(socketConnection1!);
}

void main() {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];

  //Establish the client socket connection
  setUp(() async {
    await _connect();
  });

  test('update a lookup of a public key', () async {
    await socket_writer(socketConnection1!, 'from:$firstAtsign');
    var fromResponse = await read();
    print('from verb response : $fromResponse');
    fromResponse = fromResponse.replaceAll('data:', '');
    var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);

    await socket_writer(socketConnection1!, 'pkam:$pkamDigest');
    var pkamResult = await read();
    expect(pkamResult, 'data:success\n');
    var updateKey = 'update:public:twitterid$firstAtsign';
    var updateValue = 'bob-twitter';
    await socket_writer(socketConnection1!, '$updateKey  $updateValue');
    var updateResponse = await read();
    assert((!updateResponse.contains('Invalid syntax')) &&
        (!updateResponse.contains('null')));

    // llookup of reference key should display the updareref value
    await socket_writer(
        socketConnection1!, 'llookup:public:twitterid$firstAtsign');
    var llookupResponse = await read();
    expect(llookupResponse, contains(updateValue));
  });

  // Purpose of the tests
  // 1. update a public key with a value
  // 2. update a public reference key with ref to the above public key
  // 3. llookup of the reference key should display the value of the reference key
  // 4. lookup of the reference key without auth should display the value of the public key
  test('update and lookup of a public reference key', () async {
    await socket_writer(socketConnection1!, 'from:$firstAtsign');
    var fromResponse = await read();
    print('from verb response : $fromResponse');
    fromResponse = fromResponse.replaceAll('data:', '');
    var pkamDigest = generatePKAMDigest(firstAtsign, fromResponse);
    await socket_writer(socketConnection1!, 'pkam:$pkamDigest');
    var pkamResult = await read();
    expect(pkamResult, 'data:success\n');
    var updateKey = 'update:public:landline$firstAtsign';
    var updateValue = '040-27502234';
    await socket_writer(socketConnection1!, '$updateKey  $updateValue');
    var updateResponse = await read();
    assert((!updateResponse.contains('Invalid syntax')) &&
        (!updateResponse.contains('null')));

    // update a reference key
    var updaterefKey = 'update:public:landlineref$firstAtsign';
    var updaterefValue = 'atsign://landline$firstAtsign';
    await socket_writer(socketConnection1!, '$updaterefKey  $updaterefValue');
    updateResponse = await read();
    assert((!updateResponse.contains('Invalid syntax')) &&
        (!updateResponse.contains('null')));

    // llookup of reference key should display the updareref value
    await socket_writer(
        socketConnection1!, 'llookup:public:landlineref$firstAtsign');
    var llookupResponse = await read();
    expect(llookupResponse, contains(updaterefValue));

    socketConnection1!.destroy();

    // lookup of reference key should display the updatevalue
    // lookup of reference key without auth
    // looking up from a new socket connection without authentication
    await _connect();
    await socket_writer(socketConnection1!, 'lookup:landlineref$firstAtsign');
    var lookupResponse = await read();
    expect(lookupResponse, contains(updateValue));
  });

  tearDown(() {
    //Closing the client socket connection
    clear();
    socketConnection1!.destroy();
  });
}
