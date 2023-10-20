import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';

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
    response = response.replaceFirst('error:', '');
    var errorMap = jsonDecode(response);
    expect(errorMap['errorCode'], 'AT0015');
    assert(errorMap['errorDescription'].contains('key not found'));
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
}
