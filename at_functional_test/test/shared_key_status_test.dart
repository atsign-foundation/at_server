import 'package:test/test.dart';

import 'commons.dart';

import 'dart:io';
import 'package:at_functional_test/conf/config_util.dart';

void main() {
 var first_atsign = '@bob';
  var first_atsign_port = 6365;

  var second_atsign = '@alice';
  var second_atsign_port = 6367;

  Socket _socket_first_atsign;
  Socket _socket_second_atsign;
  
  setUp(() async {
    var root_server = ConfigUtil.getYaml()['root_server']['url'];
    _socket_first_atsign =
        await secure_socket_connection(root_server, first_atsign_port);
    socket_listener(_socket_first_atsign);
    await prepare(_socket_first_atsign, first_atsign);

    _socket_second_atsign =
    await secure_socket_connection(root_server, second_atsign_port);
    socket_listener(_socket_second_atsign);
    await prepare(_socket_second_atsign, second_atsign);
  });

  test('update-llookup verb to check the shared key status', () async {
    /// UPDATE VERB
    await socket_writer(_socket_first_atsign, 'update:$second_atsign:location$first_atsign Hyderabad');
    var response = await read();
    print('update verb response : $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(_socket_first_atsign, 'llookup:all:$second_atsign:location$first_atsign');
    response = await read();
    print('llookup verb response : $response');
    assert(response.contains('"sharedKeyStatus":"SHARED_WITH_NOTIFIED"'));

// lookup in the reciever atsign
    await socket_writer(_socket_second_atsign, 'lookup:location$first_atsign');
    response = await read();
    print('lookup verb response : $response');
    assert(response.contains('data:Hyderabad'));

// checking the shared key status after the receiver has looked up the value
    await socket_writer(_socket_first_atsign, 'llookup:all:$second_atsign:location$first_atsign');
    response = await read();
    print('llookup verb response : $response');
    assert(response.contains('"sharedKeyStatus":"SHARED_WITH_LOOKED_UP"'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update-llookup verb to check the shared key status for ttl', () async {
    /// UPDATE VERB
    await socket_writer(_socket_first_atsign, 'update:ttl:5000:$second_atsign:auth-code$first_atsign 1122');
    var response = await read();
    print('update verb response : $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(_socket_first_atsign, 'llookup:all:$second_atsign:auth-code$first_atsign');
    response = await read();
    print('llookup verb response : $response');
    assert(response.contains('"sharedKeyStatus":"SHARED_WITH_NOTIFIED"'));

// lookup in the sender atsign after 5 seconds
    await socket_writer(_socket_first_atsign, 'llookup:all:$second_atsign:auth-code$first_atsign');
    response = await read();
    print('lookup verb response : $response');
    assert(response.contains('data:null'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update-llookup verb to check the shared key status for ttb', () async {
    /// UPDATE VERB
    await socket_writer(_socket_first_atsign, 'update:ttb:3000:$second_atsign:otp$first_atsign 1122');
    var response = await read();
    print('update verb response : $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(_socket_first_atsign, 'llookup:all:$second_atsign:otp$first_atsign');
    response = await read();
    print('lookup verb response : $response');
    assert(response.contains('data:null'));

    // lookup in the sender atsign after 5 seconds
    await socket_writer(_socket_first_atsign, 'llookup:all:$second_atsign:otp$first_atsign');
    response = await read();
    print('llookup verb response : $response');
    assert(response.contains('"sharedKeyStatus":"SHARED_WITH_NOTIFIED"'));
  }, timeout: Timeout(Duration(seconds: 90)));

  test('update-llookup verb to check the shared key status for ttr', () async {
    /// UPDATE VERB
    await socket_writer(_socket_first_atsign, 'update:ttr:3000:$second_atsign:new_otp$first_atsign Qats');
    var response = await read();
    print('update verb response : $response');
    assert((!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(_socket_first_atsign, 'llookup:all:$second_atsign:new_otp$first_atsign');
    response = await read();
    print('lookup verb response : $response');
    assert(response.contains('"sharedKeyStatus":"SHARED_WITH_NOTIFIED"'));
  }, timeout: Timeout(Duration(seconds: 90)));

  

  tearDown(() {
    //Closing the client socket connection
    clear();
    _socket_first_atsign.destroy();
    _socket_second_atsign.destroy();
  });
}
