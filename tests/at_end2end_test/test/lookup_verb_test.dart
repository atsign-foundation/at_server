import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:version/version.dart';

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

  test('A test to verify lookup metadata contains public key hash value',
      () async {
    Version atSign1ServerVersion = Version.parse(await sh1.getVersion());
    if (atSign1ServerVersion < Version(3, 0, 52)) {
      print(
          'Found $atSign_1 with server version: $atSign1ServerVersion. This test is only applicable for server version greater than 3.0.52. Skipping the test');
      return;
    }
    Version atSign2ServerVersion = Version.parse(await sh2.getVersion());
    if (atSign2ServerVersion < Version(3, 0, 52)) {
      print(
          'Found $atSign_2 with server version: $atSign2ServerVersion. This test is only applicable for server version greater than 3.0.52. Skipping the test');
      return;
    }
    var lastValue = Random().nextInt(5);
    var randomHashValue = Uuid().v4().hashCode;
    var value = 'Q7878R$lastValue';
    await sh1.writeCommand(
        'update:pubKeyHash:hashedValue-$randomHashValue:hashingAlgo:sha512:$atSign_2:special-code$atSign_1 $value');
    String response = await sh1.read();
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///lookup verb alice  atsign
    await sh2.writeCommand('lookup:all:special-code$atSign_1');
    response = await sh2.read(timeoutMillis: 4000);
    response = response.replaceAll('data:', '');
    var decodedResponse = jsonDecode(response);
    expect(decodedResponse['key'], '$atSign_2:special-code$atSign_1');
    expect(decodedResponse['metaData']['pubKeyHash']['hash'],
        'hashedValue-$randomHashValue');
    expect(decodedResponse['metaData']['pubKeyHash']['hashingAlgo'], 'sha512');
    expect(decodedResponse['data'], value);
  });
}
