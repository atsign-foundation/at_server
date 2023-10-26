import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:uuid/uuid.dart';

///The below test functions runs a complete flow of all verbs
///
/// The "setUpAll" runs at the beginning of all tests which creates a connection and authenticates.
/// All the verbs are executed on the connection.
/// Finally at the end the connection is closed in "tearDownAll"

void main() async {
  late String uniqueId;

  OutboundConnectionFactory firstAtSignConnection = OutboundConnectionFactory();
  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  String secondAtSign =
      ConfigUtil.getYaml()!['secondAtSignServer']['secondAtSignName'];

  setUpAll(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
    String authResponse = await firstAtSignConnection.authenticateConnection();
    expect(authResponse, 'data:success', reason: 'Authentication failed when executing test');
    // Generates Unique Id for each test that will be appended to keys to prevent
    // same keys being reused.
    uniqueId = Uuid().v4().hashCode.toString();
  });

  test('update verb test $firstAtSign', () async {
    ///Update verb with public key
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:public:mobile-$uniqueId$firstAtSign 9988112343');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///Update verb with private key
    response = await firstAtSignConnection.sendRequestToServer(
        'update:@alice:email-$uniqueId$firstAtSign bob@atsign.com');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
  });

  test('scan verb test $firstAtSign', () async {
    String response = await firstAtSignConnection
        .sendRequestToServer('scan mobile-$uniqueId');
    expect(response, contains('"public:mobile-$uniqueId$firstAtSign"'));
  });

  test('llookup verb test $firstAtSign', () async {
    String response = await firstAtSignConnection
        .sendRequestToServer('llookup:public:mobile-$uniqueId$firstAtSign');
    expect(response, contains('data:9988112343'));
  });

  test('Delete verb test $firstAtSign', () async {
    String response = await firstAtSignConnection
        .sendRequestToServer('delete:public:mobile-$uniqueId$firstAtSign');
    assert(!response.contains('data:null'));
  });

  test('scan verb test after delete $firstAtSign', () async {
    String response = await firstAtSignConnection
        .sendRequestToServer('scan mobile-$uniqueId');
    expect(response, isNot('public:mobile-$uniqueId$firstAtSign'));
  });

  test('config verb test -add block list $firstAtSign', () async {
    String response = await firstAtSignConnection
        .sendRequestToServer('config:block:add:$secondAtSign');
    expect(response, contains('data:success'));
    response =
        await firstAtSignConnection.sendRequestToServer('config:block:show');
    expect(response, contains(secondAtSign));
  });

  test('config verb test -remove from block list $firstAtSign', () async {
    String response = await firstAtSignConnection
        .sendRequestToServer('config:block:remove:$secondAtSign');
    expect(response, contains('data:success'));
    response =
        await firstAtSignConnection.sendRequestToServer('config:block:show');
    expect(response, contains('data:null'));
  });

//FOR THESE TESTS TO WORK/PASS SET testingMode TO TRUE THROUGH ENV VARIABLES
// Use "docker run -d --rm --name at_virtual_env_cont -e testingMode=true -p 6379:6379 -p 25000-25017:25000-25017 -p 64:64 at_virtual_env:trunk" to set testngMode to true in docker container

//THE FOLLOWING TESTS ONLY WORK WHEN IN TESTING MODE
  test('config verb test set-reset-print operation', () async {
    //the below block of code sets the commit log compaction freq to  4
    String response = await firstAtSignConnection
        .sendRequestToServer('config:set:commitLogCompactionFrequencyMins=4');
    expect(response, contains('data:ok'));
    //this resets the commit log compaction freq previously set to 4 to default value
    response = await firstAtSignConnection
        .sendRequestToServer('config:reset:commitLogCompactionFrequencyMins');
    expect(response, contains('data:ok'));
    // this ensures that the reset actually works and the current value is 18 as per the config
    // at tools/build_virtual_environment/ve_base/contents/atsign/secondary/base/config/config.yaml
    response = await firstAtSignConnection
        .sendRequestToServer('config:print:commitLogCompactionFrequencyMins');
    response = response.trim();
    print('config verb response [$response]');
    expect(response == 'data:18', true);
  });

  test('config verb test set-print', () async {
    //the block of code below sets max notification retries to 25
    String response = await firstAtSignConnection
        .sendRequestToServer('config:set:maxNotificationRetries=25');
    expect(response, contains('data:ok'));
    //the block of code below verifies that the max notification retries is set to 25
    response = await firstAtSignConnection
        .sendRequestToServer('config:print:maxNotificationRetries');
    expect(response, contains('data:25'));
  });

  tearDownAll(() {
    firstAtSignConnection.close();
  });
}
