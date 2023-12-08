import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'functional_test_commons.dart';

void main() async {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  Socket? socketFirstAtsign;
  var lastValue = Random().nextInt(20);

  setUp(() async {
    var firstAtsignServer =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    var firstAtsignPort =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);
  });

  test('update-llookup verb with public key', () async {
    /// UPDATE VERB
    var value = 'Hyderabad$lastValue';
    await socket_writer(
        socketFirstAtsign!, 'update:public:location$firstAtsign $value');
    var response = await read(maxWaitMilliSeconds: 1000);
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(
        socketFirstAtsign!, 'llookup:public:location$firstAtsign');
    response = await read(maxWaitMilliSeconds: 1000);
    print('llookup verb response : $response');
    expect(response, contains('data:$value'));
  });

  test('update verb with special characters', () async {
    ///UPDATE VERB
    await socket_writer(
        socketFirstAtsign!, 'update:public:passcode$firstAtsign @!ice^&##');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(
        socketFirstAtsign!, 'llookup:public:passcode$firstAtsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:@!ice^&##'));
  });

  test('update verb with unicode characters', () async {
    ///UPDATE VERB
    await socket_writer(
        socketFirstAtsign!, 'update:public:unicode$firstAtsign U+0026');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(
        socketFirstAtsign!, 'llookup:public:unicode$firstAtsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:U+0026'));
  });

  test('update verb with spaces ', () async {
    ///UPDATE VERB
    await socket_writer(socketFirstAtsign!,
        'update:public:message$firstAtsign Hey Hello! welcome to the tests');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(
        socketFirstAtsign!, 'llookup:public:message$firstAtsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:Hey Hello! welcome to the tests'));
  });

  test('updating same key with different values and doing a llookup ',
      () async {
    ///UPDATE VERB
    await socket_writer(socketFirstAtsign!,
        'update:public:message$firstAtsign Hey Hello! welcome to the tests');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(
        socketFirstAtsign!, 'llookup:public:message$firstAtsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:Hey Hello! welcome to the tests'));

    await socket_writer(socketFirstAtsign!,
        'update:public:message$firstAtsign Hope you are doing good');
    response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(
        socketFirstAtsign!, 'llookup:public:message$firstAtsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:Hope you are doing good'));
  });

  test('update verb without value should throw a error ', () async {
    ///UPDATE VERB
    await socket_writer(socketFirstAtsign!, 'update:public:key-1$firstAtsign');
    var response = await read();
    print('update verb response : $response');
    expect(response, contains('Invalid syntax'));
  });

  test('update verb by passing emoji as value ', () async {
    ///UPDATE VERB
    var value = '🦄$lastValue';
    await socket_writer(
        socketFirstAtsign!, 'update:public:emoji$firstAtsign $value');
    var response = await read(maxWaitMilliSeconds: 5000);
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(socketFirstAtsign!, 'llookup:public:emoji$firstAtsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:$value'));
  });

  test('update verb by passing japanese input as value ', () async {
    ///UPDATE VERB
    var value = 'パーニマぱーにま$lastValue';
    await socket_writer(
        socketFirstAtsign!, 'update:public:japanese$firstAtsign $value');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(
        socketFirstAtsign!, 'llookup:public:japanese$firstAtsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:$value'));
  });

  test('update verb by passing 2 @ symbols ', () async {
    ///UPDATE VERB
    await socket_writer(
        socketFirstAtsign!, 'update:public:country@$firstAtsign USA');
    var response = await read();
    print('update verb response : $response');
    expect(response, contains('Invalid syntax'));
  });

  test('update verb with public and shared with atsign should throw a error ',
      () async {
    ///UPDATE VERB
    await socket_writer(socketFirstAtsign!,
        'update:public:@alice:invalid-key$firstAtsign invalid-value');
    var response = await read();
    response = response.replaceFirst('error:', '');
    var errorMap = jsonDecode(response);
    expect(errorMap['errorCode'], 'AT0003');
    assert(errorMap['errorDescription'].contains('Invalid syntax'));
  });

  test('update verb key with punctuation - check invalid key ', () async {
    ///UPDATE VERB
    await socket_writer(
        socketFirstAtsign!, 'update:public:country,current$firstAtsign USA');
    var response = await read();
    response = response.replaceFirst('error:', '');
    var errorMap = jsonDecode(response);
    expect(errorMap['errorCode'], 'AT0016');
    assert(errorMap['errorDescription'].contains(
        'Invalid key : You may not update keys of type KeyType.invalidKey'));
  });

  test('update-llookup for private key for an emoji atsign ', () async {
    ///UPDATE VERB
    var value = 'unicorn$lastValue';
    await socket_writer(
        socketFirstAtsign!, 'update:@🦄:emoji.name$firstAtsign $value');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await socket_writer(
        socketFirstAtsign!, 'llookup:@🦄:emoji.name$firstAtsign');
    response = await read();
    print('llookup verb response : $response');
    expect(response, contains('data:$value'));
  });

  test('update-llookup for ttl ', () async {
    ///UPDATE VERB
    var value = '$lastValue seconds';
    await socket_writer(socketFirstAtsign!,
        'update:ttl:3000:$firstAtsign:offer$firstAtsign $value');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP:META verb
    await socket_writer(
        socketFirstAtsign!, 'llookup:meta:$firstAtsign:offer$firstAtsign');
    response = await read();
    print('llookup meta response : $response');
    expect(response, contains('"ttl":3000'));

    ///LLOOKUP VERB - Before 3 seconds
    await socket_writer(
        socketFirstAtsign!, 'llookup:$firstAtsign:offer$firstAtsign');
    response = await read();
    print('llookup verb response before 3 seconds : $response');
    expect(response, contains('data:$value'));

    ///LLOOKUP VERB - After 3 seconds
    await Future.delayed(Duration(seconds: 3));
    await socket_writer(
        socketFirstAtsign!, 'llookup:$firstAtsign:offer$firstAtsign');
    response = await read();
    print('llookup verb response after 3 seconds : $response');
    expect(response, contains('data:null'));
  });

  test('update-llookup for ttb ', () async {
    ///UPDATE VERB
    var value = '3289$lastValue';
    await socket_writer(socketFirstAtsign!,
        'update:ttb:2000:$firstAtsign:auth-code$firstAtsign $value');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB - Before 2 seconds
    await socket_writer(
        socketFirstAtsign!, 'llookup:$firstAtsign:auth-code$firstAtsign');
    response = await read();
    print('llookup verb response before 2 seconds : $response');
    expect(response, contains('data:null'));

    /// Wait for 2 seconds before proceeding
    await Future.delayed(Duration(seconds: 2));

    ///LLOOKUP VERB - After 2 seconds
    await socket_writer(
        socketFirstAtsign!, 'llookup:$firstAtsign:auth-code$firstAtsign');
    response = await read();
    print('llookup verb response after 2 seconds : $response');
    expect(response, contains('data:$value'));

    ///LLookup:META FOR TTB
    await socket_writer(
        socketFirstAtsign!, 'llookup:meta:$firstAtsign:auth-code$firstAtsign');
    response = await read();
    print('llookup meta verb response for ttb is : $response');
    expect(response, contains('"ttb":2000'));
  });

  test('update-llookup for ttl and ttb together', () async {
    ///UPDATE VERB
    var value = '1122$lastValue';
    await socket_writer(socketFirstAtsign!,
        'update:ttl:4000:ttb:2000:$firstAtsign:login-code$firstAtsign $value');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB - Before 3 seconds
    await socket_writer(
        socketFirstAtsign!, 'llookup:$firstAtsign:login-code$firstAtsign');
    response = await read();
    print('llookup verb response before 4 seconds : $response');
    expect(response, contains('data:null'));

    ///LLOOKUP VERB - After 4 seconds ttb time
    await Future.delayed(Duration(seconds: 2));
    await socket_writer(
        socketFirstAtsign!, 'llookup:$firstAtsign:login-code$firstAtsign');
    response = await read();
    print('llookup verb response after 4 seconds : $response');
    expect(response, contains('data:$value'));

    await socket_writer(
        socketFirstAtsign!, 'llookup:$firstAtsign:login-code$firstAtsign');
    response = await read();
    print('llookup verb response before 4 seconds : $response');
    expect(response, contains('data:$value'));

    ///LLOOKUP VERB - After 4 seconds ttl time
    await Future.delayed(Duration(seconds: 4));
    await socket_writer(
        socketFirstAtsign!, 'llookup:$firstAtsign:login-code$firstAtsign');
    response = await read();
    print('llookup verb response after 4 seconds : $response');
    expect(response, contains('data:null'));
  });
}
