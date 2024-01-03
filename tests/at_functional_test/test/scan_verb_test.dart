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

  group('A group of scan verb tests on authenticated connection', () {
    setUpAll(() async {
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      String authResponse = await firstAtSignConnection.authenticateConnection();
      expect(authResponse, 'data:success', reason: 'Authentication failed when executing test');
    });

    setUp(() {
      uniqueId = Uuid().v4();
    });

    tearDownAll(() async {
      await firstAtSignConnection.close();
    });

    test('Scan verb after authentication', () async {
      //UPDATE VERB
      String response = await firstAtSignConnection.sendRequestToServer(
          'update:public:location-$uniqueId$firstAtSign California');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
      //SCAN VERB
      response = await firstAtSignConnection.sendRequestToServer('scan');
      expect(response, contains('"public:location-$uniqueId$firstAtSign"'));
    });

    test('Scan verb with only atSign and no value', () async {
      //SCAN VERB
      String response =
          await firstAtSignConnection.sendRequestToServer('scan@');
      expect(response, contains('Invalid syntax'));
    });

    test('Scan verb with regex', () async {
      //UPDATE VERB
      String response = await firstAtSignConnection.sendRequestToServer(
          'update:public:twitter-$uniqueId.me$firstAtSign bob_123');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
      //SCAN VERB
      response = await firstAtSignConnection.sendRequestToServer('scan $uniqueId.me');
      expect(response, contains('"public:twitter-$uniqueId.me$firstAtSign"'));
    });

    test('Scan verb does not return expired keys', () async {
      //UPDATE VERB
      String response = await firstAtSignConnection.sendRequestToServer(
          'update:ttl:3000:ttlKEY-$uniqueId.me$firstAtSign 1245');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
      //SCAN VERB should return the key before it expires
      response =
          await firstAtSignConnection.sendRequestToServer('scan $uniqueId');
      expect(
          false,
          response.contains(
              '"ttlKEY-$uniqueId.me$firstAtSign"')); // server ensures lower-case
      expect(true, response.contains('"ttlkey-$uniqueId.me$firstAtSign"'));

      // update ttl to a lesser value so that key expires for scan
      response = await firstAtSignConnection.sendRequestToServer(
          'update:ttl:200:ttlKEY-$uniqueId.me$firstAtSign 1245');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
      //  scan verb should not return the expired key
      await Future.delayed(Duration(milliseconds: 300));
      response =
          await firstAtSignConnection.sendRequestToServer('scan $uniqueId');
      expect(false, response.contains('"ttlkey-$uniqueId.me$firstAtSign"'));
      expect(false, response.contains('"ttlKEY-$uniqueId.me$firstAtSign"'));
    });

    test('Scan verb does not return unborn keys', () async {
      //UPDATE VERB
      String response = await firstAtSignConnection.sendRequestToServer(
          'update:ttb:4000:ttbkey-$uniqueId$firstAtSign Working?');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
      // scan verb should not return the unborn key
      response =
          await firstAtSignConnection.sendRequestToServer('scan $uniqueId');
      expect(false, response.contains('"ttbkey-$uniqueId$firstAtSign"'));
      // update ttb to a lesser value so that key becomes born
      response = await firstAtSignConnection.sendRequestToServer(
          'update:ttb:200:ttbkey-$uniqueId$firstAtSign Working?');
      assert((!response.contains('Invalid syntax')) &&
          (!response.contains('null')));
      // scan verb should return the born key
      await Future.delayed(Duration(milliseconds: 300));
      response =
          await firstAtSignConnection.sendRequestToServer('scan $uniqueId');
      expect(response, contains('"ttbkey-$uniqueId$firstAtSign"'));
    });
  });

  group('A group of scan verb tests on unauthenticated connection', () {
    setUpAll(() async {
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
    });

    tearDownAll(() async {
      await firstAtSignConnection.close();
    });
    test('scan verb before authentication', () async {
      await firstAtSignConnection.authenticateConnection();
      await firstAtSignConnection.sendRequestToServer(
          'update:public:location-$uniqueId$firstAtSign California');
      await firstAtSignConnection.close();
      // Initiate unauthenticated connection and run scan verb
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      String response =
          await firstAtSignConnection.sendRequestToServer('scan $uniqueId');
      expect(response, contains('location-$uniqueId$firstAtSign'));
    });
  });
}
