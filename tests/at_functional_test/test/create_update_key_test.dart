import 'dart:convert';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() {
  late String uniqueId;
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

  setUp(() {
    // Generates Unique Id for each test that will be appended to keys to prevent
    // same keys being reused.
    uniqueId = Uuid().v4().hashCode.toString();
  });

  group('A group of tests to assert on metadata of a key', () {
    // The test asserts the following on creation of a key
    // 1. The version of the key should be set to 0
    // 2. The createdAt should be populated with DateTime .
    // 3. The createdBy should be populated with atSign.
    test(
        'A test to assert of default fields in metadata are populated on creation of a key',
        () async {
      // Insert a new key. To ensure the key is always new append UUID.
      var keyCreationDateTime = DateTime.now().toUtc();
      String key = 'newkey-$uniqueId';
      var response = await firstAtSignConnection
          .sendRequestToServer('update:public:$key$firstAtSign new-value');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
      response = (await firstAtSignConnection
              .sendRequestToServer('llookup:all:public:$key$firstAtSign'))
          .replaceAll('data:', '');
      var atData = jsonDecode(response);
      expect(atData['metaData']['version'], 0);
      expect(
          DateTime.parse(atData['metaData']['createdAt'])
                  .millisecondsSinceEpoch >
              keyCreationDateTime.millisecondsSinceEpoch,
          true);
      expect(atData['metaData']['createdBy'], firstAtSign);
    });

    test(
        'A test to assert of default fields in metadata are populated on update of a key',
        () async {
      // The test asserts the following on update of a key
      // 1. The version of the key should be set to 1
      // 2. The createdAt should be populated with currentDateTime (now),
      // 3. The updatedAt should be populated with DateTime which is higher than now,
      // 4. The createdBy should be populated with atSign.
      // Insert a new key. To ensure the key is always new, append UUID.
      var keyCreationDateTime = DateTime.now().toUtc();
      String key = 'newkey-$uniqueId';
      var response = await firstAtSignConnection
          .sendRequestToServer('update:public:$key$firstAtSign new-value');
      var keyUpdateDateTime = DateTime.now().toUtc();
      response = await firstAtSignConnection
          .sendRequestToServer('update:public:$key$firstAtSign updated-value');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
      response = (await firstAtSignConnection
              .sendRequestToServer('llookup:all:public:$key$firstAtSign'))
          .replaceAll('data:', '');
      var atData = jsonDecode(response);
      expect(atData['metaData']['version'], 1);
      expect(
          DateTime.parse(atData['metaData']['createdAt'])
                  .millisecondsSinceEpoch >=
              keyCreationDateTime.millisecondsSinceEpoch,
          true);
      expect(
          DateTime.parse(atData['metaData']['updatedAt'])
                  .millisecondsSinceEpoch >=
              keyUpdateDateTime.millisecondsSinceEpoch,
          true);
      expect(atData['metaData']['createdBy'], firstAtSign);
      expect(atData['metaData']['updatedBy'], firstAtSign);
    });
  });

  group('A group of test to verify updating a key multiple times', () {
    test('update same key multiple times test', () async {
      // Stats verb before multiple updates
      String statsResponse =
          await firstAtSignConnection.sendRequestToServer('stats:3');
      var jsonData =
          jsonDecode(statsResponse.replaceAll('data:', '').trim().toString());
      var commitIDValue = jsonDecode(jsonData[0]['value']);
      int noOfTests = 5;
      late String response;
      /// UPDATE VERB
      for (int i = 1; i <= noOfTests; i++) {
        response = await firstAtSignConnection.sendRequestToServer(
            'update:public:location-$uniqueId$firstAtSign Hyderabad');
        assert((!response.contains('Invalid syntax')) &&
            (!response.contains('null')));
      }
      // sync
      response = await firstAtSignConnection.sendRequestToServer(
          'sync:from:${commitIDValue - 1}:limit:$noOfTests');
      expect('public:location-$uniqueId$firstAtSign'.allMatches(response).length, 1);
    });

    test('delete same key multiple times test', () async {
      int noOfTests = 3;
      late String response;
      /// Delete VERB
      for (int i = 1; i <= noOfTests; i++) {
        response = await firstAtSignConnection
            .sendRequestToServer('delete:public:location-$uniqueId$firstAtSign')
          ..trim();
        assert(RegExp(r'^data:\d+').hasMatch(response));
      }
    });

    test('update multiple key at the same time', () async {
      int noOfTests = 5;
      late String response;
      var atKey = 'public:key-$uniqueId';
      var atValue = 'val';
      /// UPDATE VERB
      for (int i = 1, j = 1; i <= noOfTests; i++, j++) {
        response = await firstAtSignConnection
            .sendRequestToServer('update:$atKey$j$firstAtSign $atValue$j');
        assert((!response.contains('Invalid syntax')) &&
            (!response.contains('null')));
      }
    });
  });

  tearDownAll(() async {
    await firstAtSignConnection.close();
  });
}
