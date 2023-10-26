import 'dart:convert';
import 'dart:math';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() async {
  late String uniqueId;
  OutboundConnectionFactory firstAtSignConnection = OutboundConnectionFactory();
  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  var lastValue = Random().nextInt(20);

  setUpAll(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
    String authResponse = await firstAtSignConnection.authenticateConnection();
    expect(authResponse, 'data:success', reason: 'Authentication failed when executing test');
  });

  setUp(() {
    uniqueId = Uuid().v4();
  });

  test('update-llookup verb with public key', () async {
    /// UPDATE VERB
    var value = 'Hyderabad$lastValue';
    var response = await firstAtSignConnection.sendRequestToServer(
        'update:public:location-$uniqueId$firstAtSign $value');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    response = await firstAtSignConnection
        .sendRequestToServer('llookup:public:location-$uniqueId$firstAtSign');
    expect(response, contains('data:$value'));
  });

  test('update verb with special characters', () async {
    ///UPDATE VERB
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:public:passcode-$uniqueId$firstAtSign @!ice^&##');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    response = await firstAtSignConnection
        .sendRequestToServer('llookup:public:passcode-$uniqueId$firstAtSign');
    expect(response, contains('data:@!ice^&##'));
  });

  test('update verb with unicode characters', () async {
    ///UPDATE VERB
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:public:unicode-$uniqueId$firstAtSign U+0026');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    response = await firstAtSignConnection
        .sendRequestToServer('llookup:public:unicode-$uniqueId$firstAtSign');
    expect(response, contains('data:U+0026'));
  });

  test('update verb with spaces ', () async {
    ///UPDATE VERB
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:public:message-$uniqueId$firstAtSign Hey Hello! welcome to the tests');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    response = await firstAtSignConnection
        .sendRequestToServer('llookup:public:message-$uniqueId$firstAtSign');
    expect(response, contains('data:Hey Hello! welcome to the tests'));
  });

  test('updating same key with different values and doing a llookup ',
      () async {
    ///UPDATE VERB
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:public:message-$uniqueId$firstAtSign Hey Hello! welcome to the tests');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    response = await firstAtSignConnection
        .sendRequestToServer('llookup:public:message-$uniqueId$firstAtSign');
    expect(response, contains('data:Hey Hello! welcome to the tests'));

    response = await firstAtSignConnection.sendRequestToServer(
        'update:public:message-$uniqueId$firstAtSign Hope you are doing good');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    response = await firstAtSignConnection
        .sendRequestToServer('llookup:public:message-$uniqueId$firstAtSign');
    expect(response, contains('data:Hope you are doing good'));
  });

  test('update verb without value should throw a error ', () async {
    ///UPDATE VERB
    String response = await firstAtSignConnection
        .sendRequestToServer('update:public:key-1-$uniqueId$firstAtSign');
    expect(response, contains('Invalid syntax'));
  });

  test('update verb by passing emoji as value ', () async {
    ///UPDATE VERB
    var value = '🦄$lastValue';
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:public:emoji-$uniqueId$firstAtSign $value');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    response = await firstAtSignConnection
        .sendRequestToServer('llookup:public:emoji-$uniqueId$firstAtSign');
    expect(response, contains('data:$value'));
  });

  test('update verb by passing japanese input as value ', () async {
    ///UPDATE VERB
    var value = 'パーニマぱーにま$lastValue';
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:public:japanese-$uniqueId$firstAtSign $value');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    response = await firstAtSignConnection
        .sendRequestToServer('llookup:public:japanese-$uniqueId$firstAtSign');
    expect(response, contains('data:$value'));
  });

  test('update verb by passing 2 @ symbols ', () async {
    ///UPDATE VERB
    String response = await firstAtSignConnection
        .sendRequestToServer('update:public:country@$firstAtSign USA');
    expect(response, contains('Invalid syntax'));
  });

  test('update verb with public and shared with atsign should throw a error ',
      () async {
    ///UPDATE VERB
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:public:@alice:invalid-key$firstAtSign invalid-value');
    response = response.replaceFirst('error:', '');
    var errorMap = jsonDecode(response);
    expect(errorMap['errorCode'], 'AT0003');
    assert(errorMap['errorDescription'].contains('Invalid syntax'));
  });

  test('update verb key with punctuation - check invalid key ', () async {
    ///UPDATE VERB
    String response = await firstAtSignConnection
        .sendRequestToServer('update:public:country,current$firstAtSign USA');
    response = response.replaceFirst('error:', '');
    var errorMap = jsonDecode(response);
    expect(errorMap['errorCode'], 'AT0016');
    assert(errorMap['errorDescription'].contains(
        'Invalid key : You may not update keys of type KeyType.invalidKey'));
  });

  test('update-llookup for private key for an emoji atsign ', () async {
    ///UPDATE VERB
    var value = 'unicorn$lastValue';
    String response = await firstAtSignConnection
        .sendRequestToServer('update:@🦄:emoji.name$firstAtSign $value');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    response = await firstAtSignConnection
        .sendRequestToServer('llookup:@🦄:emoji.name$firstAtSign');
    expect(response, contains('data:$value'));
  });

  test('update-llookup for ttl ', () async {
    ///UPDATE VERB
    var value = '$lastValue seconds';
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:ttl:3000:$firstAtSign:offer-$uniqueId$firstAtSign $value');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP:META verb
    response = await firstAtSignConnection.sendRequestToServer(
        'llookup:meta:$firstAtSign:offer-$uniqueId$firstAtSign');
    expect(response, contains('"ttl":3000'));

    ///LLOOKUP VERB - Before 3 seconds
    response = await firstAtSignConnection.sendRequestToServer(
        'llookup:$firstAtSign:offer-$uniqueId$firstAtSign');
    expect(response, contains('data:$value'));

    ///LLOOKUP VERB - After 3 seconds
    await Future.delayed(Duration(seconds: 3));
    response = await firstAtSignConnection.sendRequestToServer(
        'llookup:$firstAtSign:offer-$uniqueId$firstAtSign');
    expect(response, contains('data:null'));
  });

  test('update-llookup for ttb ', () async {
    ///UPDATE VERB
    var value = '3289$lastValue';
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:ttb:2000:$firstAtSign:auth-code-$uniqueId$firstAtSign $value');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB - Before 2 seconds
    response = await firstAtSignConnection.sendRequestToServer(
        'llookup:$firstAtSign:auth-code-$uniqueId$firstAtSign');
    expect(response, contains('data:null'));

    /// Wait for 2 seconds before proceeding
    await Future.delayed(Duration(seconds: 2));

    ///LLOOKUP VERB - After 2 seconds
    response = await firstAtSignConnection.sendRequestToServer(
        'llookup:$firstAtSign:auth-code-$uniqueId$firstAtSign');
    expect(response, contains('data:$value'));

    ///LLookup:META FOR TTB
    response = await firstAtSignConnection.sendRequestToServer(
        'llookup:meta:$firstAtSign:auth-code-$uniqueId$firstAtSign');
    expect(response, contains('"ttb":2000'));
  });

  test('update-llookup for ttl and ttb together', () async {
    ///UPDATE VERB
    var value = '1122$lastValue';
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:ttl:4000:ttb:2000:$firstAtSign:login-code-$uniqueId$firstAtSign $value');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB - Before 3 seconds
    response = await firstAtSignConnection.sendRequestToServer(
        'llookup:$firstAtSign:login-code-$uniqueId$firstAtSign');
    expect(response, contains('data:null'));

    ///LLOOKUP VERB - After 4 seconds ttb time
    await Future.delayed(Duration(seconds: 2));
    response = await firstAtSignConnection.sendRequestToServer(
        'llookup:$firstAtSign:login-code-$uniqueId$firstAtSign');
    expect(response, contains('data:$value'));

    response = await firstAtSignConnection.sendRequestToServer(
        'llookup:$firstAtSign:login-code-$uniqueId$firstAtSign');
    expect(response, contains('data:$value'));

    ///LLOOKUP VERB - After 4 seconds ttl time
    await Future.delayed(Duration(seconds: 4));
    response = await firstAtSignConnection.sendRequestToServer(
        'llookup:$firstAtSign:login-code-$uniqueId$firstAtSign');
    expect(response, contains('data:null'));
  });

  tearDownAll(() async {
    await firstAtSignConnection.close();
  });
}
