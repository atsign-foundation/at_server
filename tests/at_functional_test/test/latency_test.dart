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

  String secondAtSign =
      ConfigUtil.getYaml()!['secondAtSignServer']['secondAtSignName'];

  setUpAll(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
    String authResponse = await firstAtSignConnection.authenticateConnection();
    expect(authResponse, 'data:success', reason: 'Authentication failed when executing test');
  });

  setUp(() {
    uniqueId = Uuid().v4();
  });

  test('updating a key and verifying the time taken', () async {
    String response;
    var timeBeforeUpdate = DateTime.now().millisecondsSinceEpoch;
    String updateCommand =
        'update:public:location-$uniqueId$firstAtSign Hyderabad';
    response = await firstAtSignConnection.sendRequestToServer(updateCommand);
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    var timeAfterUpdate = DateTime.now().millisecondsSinceEpoch;
    Duration timeDifferenceValue =
        timeDifference(timeBeforeUpdate, timeAfterUpdate);
    expect(timeDifferenceValue.inMilliseconds <= 1500, true);
  });

  test('Lookup should be less than a second for a given key', () async {
    String response;
    String atKey = 'discord$firstAtSign';
    String value = 'user_1';
    response = await firstAtSignConnection
        .sendRequestToServer('update:public:$atKey $value');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    var timeBeforeLookup = DateTime.now().millisecondsSinceEpoch;
    response = await firstAtSignConnection
        .sendRequestToServer('llookup:public:$atKey');
    expect(response, contains('data:$value'));
    var timeAfterLookup = DateTime.now().millisecondsSinceEpoch;
    Duration timeDifferenceValue =
        timeDifference(timeBeforeLookup, timeAfterLookup);
    expect(timeDifferenceValue.inMilliseconds <= 1500, true);
  });

  test('delete a key and verifying the time taken', () async {
    String response;
    var timeBeforeDelete = DateTime.now().millisecondsSinceEpoch;
    String deleteCommand = 'delete:public:location$firstAtSign';
    response = await firstAtSignConnection.sendRequestToServer(deleteCommand);
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    var timeAfterDelete = DateTime.now().millisecondsSinceEpoch;
    Duration timeDifferenceValue =
        timeDifference(timeBeforeDelete, timeAfterDelete);
    expect(timeDifferenceValue.inMilliseconds <= 1500, true);
  });

  test('notify a key and verifying the time taken', () async {
    String response;
    var timeBeforeNotification = DateTime.now().millisecondsSinceEpoch;
    response = await firstAtSignConnection.sendRequestToServer(
        'notify:update:messageType:key:$secondAtSign:company$firstAtSign:atsign');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    var timeAfterNotification = DateTime.now().millisecondsSinceEpoch;
    Duration timeDifferenceValue =
        timeDifference(timeBeforeNotification, timeAfterNotification);
    expect(timeDifferenceValue.inMilliseconds <= 1500, true);
  });

  test('stats verb and verifying the time taken to get the response', () async {
    String response;
    var timeBeforeStats = DateTime.now().millisecondsSinceEpoch;
    response = await firstAtSignConnection.sendRequestToServer('stats:3');
    assert(response.contains('"name":"lastCommitID"'));
    var timeAfterStats = DateTime.now().millisecondsSinceEpoch;
    Duration timeDifferenceValue =
        timeDifference(timeBeforeStats, timeAfterStats);
    expect(timeDifferenceValue.inMilliseconds <= 1500, true);
  });
}

// calculates the time difference between command before and after execution
Duration timeDifference(var beforeCommand, var afterCommand) {
  var timeDifferenceValue = DateTime.fromMillisecondsSinceEpoch(afterCommand)
      .difference(DateTime.fromMillisecondsSinceEpoch(beforeCommand));
  return timeDifferenceValue;
}
