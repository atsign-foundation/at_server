import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() async {
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
    uniqueId = Uuid().v4();
  });

  test('llookup verb on a non-existent key', () async {
    ///lookup verb alice  atsign
    String response = await firstAtSignConnection
        .sendRequestToServer('llookup:random-$uniqueId$firstAtSign');
    expect(
        response,
        contains(
            'key not found : random-$uniqueId$firstAtSign does not exist in keystore'));
  });

  test('update-lookup verb by giving wrong spelling - Negative case', () async {
    //lookup verb
    String response = await firstAtSignConnection
        .sendRequestToServer('lokup:public:phone-$uniqueId$firstAtSign');
    expect(response, contains('Invalid syntax'));
  });

  test('plookup with an extra symbols after the atsign', () async {
    //PLOOKUP VERB
    String response = await firstAtSignConnection
        .sendRequestToServer('plookup:emoji-color-$uniqueId$firstAtSign@@@');
    expect(response, contains('Invalid syntax'));
  });
}
