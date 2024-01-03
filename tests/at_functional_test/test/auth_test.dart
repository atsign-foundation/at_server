import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';
import 'package:at_functional_test/conf/config_util.dart';

void main() {
  OutboundConnectionFactory firstAtSignConnection = OutboundConnectionFactory();
  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  setUp(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
  });

  test('authenticate and verify the time taken', () async {
    var timeBeforeAuth = DateTime.now().millisecondsSinceEpoch;
    await firstAtSignConnection.authenticateConnection();
    var timeAfterAuth = DateTime.now().millisecondsSinceEpoch;
    Duration timeDifferenceValue =
        timeDifference(timeBeforeAuth, timeAfterAuth);
    expect(timeDifferenceValue.inMilliseconds <= 1500, true);
  });

  test('authenticate multiple times', () async {
    int noOfTests = 10;
    for (int i = 1; i <= noOfTests; i++) {
      await firstAtSignConnection.authenticateConnection();
    }
  });

  tearDown(() {
    firstAtSignConnection.close();
  });
}

Duration timeDifference(var beforeCommand, var afterCommand) {
  var timeDifferenceValue = DateTime.fromMillisecondsSinceEpoch(afterCommand)
      .difference(DateTime.fromMillisecondsSinceEpoch(beforeCommand));
  return timeDifferenceValue;
}
