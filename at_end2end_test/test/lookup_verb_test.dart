import 'dart:convert';
import 'dart:math';

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

  test('llookup verb on a non-existent key', () async {
    ///lookup verb alice  atsign
    await sh1.writeCommand('llookup:random$atSign_1');
    String response = await sh1.read();
    print('llookup verb response : $response');
    if (atSign_1 == '@cicd1' || atSign_1 == '@cicd3') {
      var decodedResponse = jsonDecode(response);
      expect(decodedResponse['errorCode'], 'AT0015');
      expect(decodedResponse['errorDescription'],
          'random$atSign_1 does not exist in keystore');
    }
    if (atSign_1 == '@cicd5') {
      assert(response.startsWith('error:AT0015'));
    }
  }, timeout: Timeout(Duration(minutes: 3)));

  test('update-lookup verb on private key - positive verb', () async {
    ///Update verb on bob atsign
    var lastValue = Random().nextInt(5);
    var value = 'Q7878R$lastValue';
    await sh1.writeCommand('update:$atSign_2:special-code$atSign_1 $value');
    String response = await sh1.read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///lookup verb alice  atsign
    await sh2.writeCommand('lookup:special-code$atSign_1');
    response = await sh2.read(timeoutMillis: 4000);
    print('lookup verb response : $response');
    expect(response, contains('data:$value'));
  }, timeout: Timeout(Duration(minutes: 3)));

  test('update-lookup verb by giving wrong spelling - Negative case', () async {
    ///lookup verb
    await sh1.writeCommand('lokup:public:phone$atSign_2');
    String response = await sh1.read();
    print('lookup verb response from : $response');
    if (atSign_1 == '@cicd1' || atSign_1 == '@cicd3') {
      var decodedResponse = jsonDecode(response);
      expect(decodedResponse['errorCode'], 'AT0003');
      // Asserts error description
      expect(decodedResponse['errorDescription'], contains('invalid command'));
    }
    if(atSign_1 == '@cicd5'){
      assert(response.startsWith('error:AT0003'));
    }
    // Going to reconnect, because invalid syntax causes server to close connection
    sh1.close();
    sh1 = await e2e.getSocketHandler(atSign_1);
  }, timeout: Timeout(Duration(minutes: 3)));
}
