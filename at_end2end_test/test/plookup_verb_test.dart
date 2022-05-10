import 'dart:convert';

import 'package:test/test.dart';

import 'e2e_test_utils.dart' as e2e;

void main() {
  late String atSign_1;
  late e2e.SimpleOutboundSocketHandler sh1;

  late String atSign_2;
  late e2e.SimpleOutboundSocketHandler sh2;

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

  test('plookup verb with public key - positive case', () async {
    /// UPDATE VERB
    await sh1.writeCommand('update:public:phone$atSign_1 9982212143');
    String response = await sh1.read();
    print('update verb response $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB
    await sh2.writeCommand('plookup:phone$atSign_1');
    response = await sh2.read();
    print('plookup verb response $response');
    expect(response, contains('data:9982212143'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('plookup verb with private key - negative case', () async {
    /// UPDATE VERB
    await sh1.writeCommand('update:$atSign_2:mobile$atSign_1 9982212143');
    String response = await sh1.read();
    print('update verb response $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB
    await sh2.writeCommand('plookup:mobile$atSign_1$atSign_2');
    response = await sh2.read();
    print('plookup verb response $response');
    expect(response, contains('Invalid syntax'));
    // Going to reconnect, because invalid syntax causes server to close connection
    sh2.close();
    sh2 = await e2e.getSocketHandler(atSign_2);
  }, timeout: Timeout(Duration(seconds: 120)));

  test('plookup verb on non existent key - negative case', () async {
    ///PLOOKUP VERB
    await sh1.writeCommand('plookup:no-key$atSign_1');
    String response = await sh1.read();
    print('plookup verb response $response');
    if (atSign_1 == '@cicd1' || atSign_1 == '@cicd3') {
      var decodedResponse = jsonDecode(response);
      expect(decodedResponse['errorCode'], 'AT0015');
      expect(decodedResponse['errorDescription'],
          'public:no-key$atSign_1 does not exist in keystore');
    }
    if (atSign_1 == '@cicd5') {
      assert(response.startsWith('error:AT0011'));
    }
    //Commenting the below line untill the changes are merged into prod.
    //expect(response,contains('public:no-key$atSign_1 does not exist in keystore'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('plookup for an emoji key', () async {
    ///UPDATE VERB
    await sh1.writeCommand('update:public:🦄🦄$atSign_1 2-unicorn-emojis');
    String response = await sh1.read();
    print('update verb response $response');
    assert((!response.contains('data:null') &&
        (!response.contains('Invalid syntax'))));

    ///PLOOKUP VERB
    await sh2.writeCommand('plookup:🦄🦄$atSign_1');
    response = await sh2.read(timeoutMillis: 5000);
    print('plookup verb response $response');
    expect(response, contains('data:2-unicorn-emojis'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('plookup with an extra symbols after the atsign', () async {
    ///PLOOKUP VERB
    await sh1.writeCommand('plookup:emoji-color@emoji🦄🛠@@@');
    String response = await sh1.read();
    print('plookup verb response $response');
    expect(response, contains('Invalid syntax'));
    // Going to reconnect, because invalid syntax causes server to close connection
    sh1.close();
    sh1 = await e2e.getSocketHandler(atSign_1);
  }, timeout: Timeout(Duration(seconds: 120)));

  test('cached key creation when we do a lookup for a public key', () async {
    ///UPDATE VERB
    await sh1.writeCommand('update:public:key-1$atSign_1 9102');
    String response = await sh1.read();
    print('update verb response $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB
    await sh2.writeCommand('plookup:key-1$atSign_1');
    response = await sh2.read();
    print('plookup verb response $response');
    expect(response, contains('data:9102'));

    /// SCAN VERB
    await sh2.writeCommand('scan');
    response = await sh2.read();
    print('scan verb response $response');
    assert(response.contains('cached:public:key-1$atSign_1'));
  }, timeout: Timeout(Duration(seconds: 120)));

  test('plookup verb with public key -updating same key multiple times',
      () async {
    /// UPDATE VERB
    await sh1.writeCommand('update:public:fav-series$atSign_1 Friends');
    String response = await sh1.read();
    print('update verb response $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB after updating same key multiple times
    await sh1.writeCommand('plookup:fav-series$atSign_1');
    response = await sh1.read();
    print('plookup verb response $response');
    expect(response, contains('data:Friends'));

    /// UPDATE the same key with a different value
    await sh1.writeCommand('update:public:fav-series$atSign_1 young sheldon');
    response = await sh1.read();
    print('update verb response $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///PLOOKUP VERB after updating same key second time
    await sh1.writeCommand('plookup:fav-series$atSign_1');
    response = await sh1.read();
    print('plookup verb response $response');
    expect(response, contains('data:young sheldon'));
  }, timeout: Timeout(Duration(seconds: 120)));
}
