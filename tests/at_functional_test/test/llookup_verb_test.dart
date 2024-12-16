import 'package:at_commons/at_commons.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/connection_type_util.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() async {
  late String uniqueId;
  OutboundConnectionFactory firstAtSignConnection = OutboundConnectionFactory();

  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  String firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];
   ConnectionType firstConnectionType =
      ConnectionTypeUtil.getConnectionType('firstAtSignServer');

  SecureSocketConfig secureSocketConfig = SecureSocketConfig();
  secureSocketConfig.decryptPackets = false;

  setUpAll(() async {
    await firstAtSignConnection.initiateConnection(
        firstAtSign, firstAtSignHost, firstAtSignPort, connectionType: firstConnectionType, secureSocketConfig: secureSocketConfig);
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
