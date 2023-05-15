import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'functional_test_commons.dart';
import 'package:at_functional_test/conf/config_util.dart';

void main() {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];

  Socket? socketFirstAtsign;

  //Establish the client socket connection
  setUp(() async {
    var firstAtsignServer =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    var firstAtsignPort =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    // socket connection for first atsign
    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);
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
      String key = 'newkey-${Uuid().v4()}';
      await socket_writer(
          socketFirstAtsign!, 'update:public:$key$firstAtsign new-value');
      var response = await read();
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
      await socket_writer(
          socketFirstAtsign!, 'llookup:all:public:$key$firstAtsign');
      response = await read();
      response = response.replaceAll('data:', '');
      var atData = jsonDecode(response);
      expect(atData['metaData']['version'], 0);
      expect(
          DateTime.parse(atData['metaData']['createdAt'])
                  .millisecondsSinceEpoch >
              keyCreationDateTime.millisecondsSinceEpoch,
          true);
      expect(atData['metaData']['createdBy'], firstAtsign);
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
      String key = 'newkey-${Uuid().v4()}';
      await socket_writer(
          socketFirstAtsign!, 'update:public:$key$firstAtsign new-value');
      var response = await read();
      var keyUpdateDateTime = DateTime.now().toUtc();
      await socket_writer(
          socketFirstAtsign!, 'update:public:$key$firstAtsign updated-value');
      response = await read();
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
      await socket_writer(
          socketFirstAtsign!, 'llookup:all:public:$key$firstAtsign');
      response = await read();
      response = response.replaceAll('data:', '');
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
      expect(atData['metaData']['createdBy'], firstAtsign);
      expect(atData['metaData']['updatedBy'], firstAtsign);
    });
  });

  group('A group of test to verify updating a key multiple times', () {
    test('update same key multiple times test', () async {
      // Stats verb before multiple updates
      await socket_writer(socketFirstAtsign!, 'stats:3');
      var statsResponse = await read();
      print('stats response is $statsResponse');
      var jsonData =
          jsonDecode(statsResponse.replaceAll('data:', '').trim().toString());
      var commitIDValue = jsonDecode(jsonData[0]['value']);
      print('last commit id value is $commitIDValue');

      int noOfTests = 5;
      late String response;

      /// UPDATE VERB
      for (int i = 1; i <= noOfTests; i++) {
        await socket_writer(
            socketFirstAtsign!, 'update:public:location$firstAtsign Hyderabad');
        response = await read();
        print('update verb response : $response');
        assert((!response.contains('Invalid syntax')) &&
            (!response.contains('null')));
      }
      // sync
      await socket_writer(socketFirstAtsign!,
          'sync:from:${commitIDValue - 1}:limit:$noOfTests');
      response = await read();
      print('sync response is : $response');
      expect('public:location$firstAtsign'.allMatches(response).length, 1);
    });

    test('delete same key multiple times test', () async {
      int noOfTests = 3;
      late String response;

      /// Delete VERB
      for (int i = 1; i <= noOfTests; i++) {
        await socket_writer(
            socketFirstAtsign!, 'delete:public:location$firstAtsign');
        response = await read();
        print('delete verb response : ${response.trim()}');
        var re = RegExp(r'^data:\d+\n$');
        assert(re.hasMatch(response));
      }
    });

    test('update multiple key at the same time', () async {
      int noOfTests = 5;
      late String response;
      var atKey = 'public:key';
      var atValue = 'val';

      /// UPDATE VERB
      for (int i = 1, j = 1; i <= noOfTests; i++, j++) {
        await socket_writer(
            socketFirstAtsign!, 'update:$atKey$j$firstAtsign $atValue$j');
        response = await read();
        print('update verb response : $response');
        assert((!response.contains('Invalid syntax')) &&
            (!response.contains('null')));
      }
    });
  });
}
