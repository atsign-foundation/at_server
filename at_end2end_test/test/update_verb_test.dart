import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';
import 'package:version/version.dart';

import 'commons.dart';
import 'e2e_test_utils.dart' as e2e;

void main() {
  late String atSign_1;
  late e2e.SimpleOutboundSocketHandler sh1;

  late String atSign_2;
  late e2e.SimpleOutboundSocketHandler sh2;

  var lastValue = Random().nextInt(20);

  setUpAll(() async {
    List<String> atSigns = e2e.knownAtSigns();
    atSign_1 = atSigns[0];
    sh1 = await e2e.getSocketHandler(atSign_1);
    atSign_2 = atSigns[1];
    sh2 = await e2e.getSocketHandler(atSign_2);
  });

  tearDownAll(() {
    sh1.close();
    sh2.close();
  });

  setUp(() async {
    print("Clearing socket response queues");
    sh1.clear();
    sh2.clear();
  });

  test('update-llookup verb with public key', () async {
    /// UPDATE VERB
    var value = 'Hyderabad$lastValue';
    await sh1.writeCommand('update:public:location$atSign_1 $value');
    var response = await sh1.read(timeoutMillis: 1000);
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await sh1.writeCommand('llookup:public:location$atSign_1');
    response = await sh1.read(timeoutMillis: 1000);
    print('llookup verb response : $response');
    expect(response, contains('data:$value'));
  });

  test('update-llookup with private key', () async {
    /// UPDATE VERB
    var value = 'India$lastValue';
    await sh1.writeCommand('update:$atSign_2:country$atSign_1 $value');
    var response = await sh1.read();
    print('update verb response $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB - with @sign returns value
    await sh1.writeCommand('llookup:$atSign_2:country$atSign_1');
    response = await sh1.read();
    print('llookup verb response with private key in llookup verb: $response');
    expect(response, contains('data:$value'));

    ///LLOOKUP VERB - with out @sign does not return value.
    await sh1.writeCommand('llookup:country$atSign_1');
    response = await sh1.read();
    print(
        'llookup verb response without private key in llookup verb: $response');
    //TODO: remove else block in the next release -  when all servers json encode the error responses
    var serverResponse = Version.parse(await sh1.getVersion());
    if (serverResponse > Version(3, 0, 24)) {
      response = response.replaceFirst('error:', '');
      var errorMap = jsonDecode(response);
      expect(errorMap['errorCode'], 'AT0015');
      assert(errorMap['errorDescription'].contains('key not found'));
    } else {
      expect(response, contains('country$atSign_1 does not exist in keystore'));
    }
  });

  test('update verb with special characters', () async {
    ///UPDATE VERB
    await sh1.writeCommand('update:public:passcode$atSign_1 @!ice^&##');
    var response = await sh1.read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await sh1.writeCommand('llookup:public:passcode$atSign_1');
    response = await sh1.read();
    print('llookup verb response : $response');
    expect(response, contains('data:@!ice^&##'));
  });

  test('update verb with unicode characters', () async {
    ///UPDATE VERB
    await sh1.writeCommand('update:public:unicode$atSign_1 U+0026');
    var response = await sh1.read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await sh1.writeCommand('llookup:public:unicode$atSign_1');
    response = await sh1.read();
    print('llookup verb response : $response');
    expect(response, contains('data:U+0026'));
  });

  test('update verb with spaces ', () async {
    ///UPDATE VERB
    await sh1.writeCommand(
        'update:public:message$atSign_1 Hey Hello! welcome to the tests');
    var response = await sh1.read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await sh1.writeCommand('llookup:public:message$atSign_1');
    response = await sh1.read();
    print('llookup verb response : $response');
    expect(response, contains('data:Hey Hello! welcome to the tests'));
  });

  test('updating same key with different values and doing a llookup ',
      () async {
    ///UPDATE VERB
    await sh1.writeCommand(
        'update:public:message$atSign_1 Hey Hello! welcome to the tests');
    var response = await sh1.read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await sh1.writeCommand('llookup:public:message$atSign_1');
    response = await sh1.read();
    print('llookup verb response : $response');
    expect(response, contains('data:Hey Hello! welcome to the tests'));

    await sh1
        .writeCommand('update:public:message$atSign_1 Hope you are doing good');
    response = await sh1.read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await sh1.writeCommand('llookup:public:message$atSign_1');
    response = await sh1.read();
    print('llookup verb response : $response');
    expect(response, contains('data:Hope you are doing good'));
  });

  test('update verb without value should throw a error ', () async {
    ///UPDATE VERB
    await sh1.writeCommand('update:public:key-1$atSign_1');
    var response = await sh1.read();
    print('update verb response : $response');
    expect(response, contains('Invalid syntax'));

    // Going to reconnect, because invalid syntax causes server to close connection
    sh1.close();
    sh1 = await e2e.getSocketHandler(atSign_1);
  });

  test('update verb by passing emoji as value ', () async {
    ///UPDATE VERB
    var value = '🦄$lastValue';
    await sh1.writeCommand('update:public:emoji$atSign_1 $value');
    var response = await sh1.read(timeoutMillis: 5000);
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await sh1.writeCommand('llookup:public:emoji$atSign_1');
    response = await sh1.read();
    print('llookup verb response : $response');
    expect(response, contains('data:$value'));
  });

  test('update verb by passing japanese input as value ', () async {
    ///UPDATE VERB
    var value = 'パーニマぱーにま$lastValue';
    await sh1.writeCommand('update:public:japanese$atSign_1 $value');
    var response = await sh1.read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await sh1.writeCommand('llookup:public:japanese$atSign_1');
    response = await sh1.read();
    print('llookup verb response : $response');
    expect(response, contains('data:$value'));
  });

  test('update verb by sharing a cached key ', () async {
    ///UPDATE VERB
    var value = 'joey$lastValue$lastValue';
    await sh1
        .writeCommand('update:ttr:-1:$atSign_2:youtube_id$atSign_1 $value');
    var response = await sh1.read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB in the same secondary
    await sh1.writeCommand('llookup:$atSign_2:youtube_id$atSign_1');
    response = await sh1.read();
    print('llookup verb response : $response');
    expect(response, contains('data:$value'));

    //LOOKUP VERB in the other secondary
    while (true) {
      await sh2.writeCommand('llookup:cached:$atSign_2:youtube_id$atSign_1');
      response = await sh2.read();
      if (response.contains('data:$value') || retryCount > maxRetryCount) {
        break;
      }
      if (!response.contains('data:$value') || response.contains('data:null')) {
        print('Waiting for the cached key $retryCount');
        await Future.delayed(Duration(seconds: 2));
        retryCount++;
      }
    }
  }, timeout: Timeout(Duration(seconds: 120)));

  test('update verb by passing 2 @ symbols ', () async {
    ///UPDATE VERB
    await sh1.writeCommand('update:public:country@$atSign_1 USA');
    var response = await sh1.read();
    print('update verb response : $response');
    expect(response, contains('Invalid syntax'));

    // Going to reconnect, because invalid syntax causes server to close connection
    sh1.close();
    sh1 = await e2e.getSocketHandler(atSign_1);
  });

  test('update verb with public and shared with atsign should throw a error ',
      () async {
    ///UPDATE VERB
    await sh1.writeCommand(
        'update:public:$atSign_2:invalid-key$atSign_1 invalid-value');
    var response = await sh1.read();
    print('update verb response : $response');
    expect(response, contains('Invalid syntax'));

    // Going to reconnect, because invalid syntax causes server to close connection
    sh1.close();
    sh1 = await e2e.getSocketHandler(atSign_1);
  });

  test('update-llookup for private key for an emoji atsign ', () async {
    ///UPDATE VERB
    var value = 'unicorn$lastValue';
    await sh1.writeCommand('update:@🦄:emoji.name$atSign_1 $value');
    var response = await sh1.read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    await sh1.writeCommand('llookup:@🦄:emoji.name$atSign_1');
    response = await sh1.read();
    print('llookup verb response : $response');
    expect(response, contains('data:$value'));
  });

  test('update-llookup for ttl ', () async {
    ///UPDATE VERB
    var value = '$lastValue seconds';
    await sh1.writeCommand('update:ttl:3000:$atSign_2:offer$atSign_1 $value');
    var response = await sh1.read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP:META verb
    await sh1.writeCommand('llookup:meta:$atSign_2:offer$atSign_1');
    response = await sh1.read();
    print('llookup meta response : $response');
    expect(response, contains('"ttl":3000'));

    ///LLOOKUP VERB - Before 3 seconds
    await sh1.writeCommand('llookup:$atSign_2:offer$atSign_1');
    response = await sh1.read();
    print('llookup verb response before 3 seconds : $response');
    expect(response, contains('data:$value'));

    ///LLOOKUP VERB - After 3 seconds
    await Future.delayed(Duration(seconds: 3));
    await sh1.writeCommand('llookup:$atSign_2:offer$atSign_1');
    response = await sh1.read();
    print('llookup verb response after 3 seconds : $response');
    expect(response, contains('data:null'));
  });

  test('update-llookup for ttb ', () async {
    ///UPDATE VERB
    var value = '3289$lastValue';
    await sh1
        .writeCommand('update:ttb:2000:$atSign_2:auth-code$atSign_1 $value');
    var response = await sh1.read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB - Before 2 seconds
    await sh1.writeCommand('llookup:$atSign_2:auth-code$atSign_1');
    response = await sh1.read();
    print('llookup verb response before 2 seconds : $response');
    expect(response, contains('data:null'));

    /// Wait for 2 seconds before proceeding
    await Future.delayed(Duration(seconds: 2));

    ///LLOOKUP VERB - After 2 seconds
    await sh1.writeCommand('llookup:$atSign_2:auth-code$atSign_1');
    response = await sh1.read();
    print('llookup verb response after 2 seconds : $response');
    expect(response, contains('data:$value'));

    ///LLookup:META FOR TTB
    await sh1.writeCommand('llookup:meta:$atSign_2:auth-code$atSign_1');
    response = await sh1.read();
    print('llookup meta verb response for ttb is : $response');
    expect(response, contains('"ttb":2000'));
  });

  test('update-llookup for ttl and ttb together', () async {
    ///UPDATE VERB
    var value = '1122$lastValue';
    await sh1.writeCommand(
        'update:ttl:4000:ttb:2000:$atSign_2:login-code$atSign_1 $value');
    var response = await sh1.read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB - Before 3 seconds
    await sh1.writeCommand('llookup:$atSign_2:login-code$atSign_1');
    response = await sh1.read();
    print('llookup verb response before 4 seconds : $response');
    expect(response, contains('data:null'));

    ///LLOOKUP VERB - After 4 seconds ttb time
    await Future.delayed(Duration(seconds: 2));
    await sh1.writeCommand('llookup:$atSign_2:login-code$atSign_1');
    response = await sh1.read();
    print('llookup verb response after 4 seconds : $response');
    expect(response, contains('data:$value'));

    await sh1.writeCommand('llookup:$atSign_2:login-code$atSign_1');
    response = await sh1.read();
    print('llookup verb response before 4 seconds : $response');
    expect(response, contains('data:$value'));

    ///LLOOKUP VERB - After 4 seconds ttl time
    await Future.delayed(Duration(seconds: 4));
    await sh1.writeCommand('llookup:$atSign_2:login-code$atSign_1');
    response = await sh1.read();
    print('llookup verb response after 4 seconds : $response');
    expect(response, contains('data:null'));
  });

  // commenting this test till next version of server is released
  // test('update verb key with punctuation - check invalid key ', () async {
  //   ///UPDATE VERB
  //   await sh1.writeCommand('update:public:country,current$atSign_1 USA');
  //   var response = await sh1.read();
  //   print('update verb response : $response');
  //   expect(response, startsWith('error:AT0016'));
  //   expect(response, contains('Invalid key'));
  //
  //   // Going to reconnect, because invalid syntax causes server to close connection
  //   sh1.close();
  //   sh1 = await e2e.getSocketHandler(atSign_1);
  // });
}
