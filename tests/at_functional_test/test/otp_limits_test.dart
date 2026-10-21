import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';

/// Functional (over-the-wire) coverage for the otp:get ttl limit. The
/// live-OTP limit is left to the unit tests: the functional pack shares one
/// atSign, so other tests' OTPs may be live at any moment.
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
    await firstAtSignConnection.authenticateConnection(authType: AuthType.cram);
  });

  tearDown(() async => await firstAtSignConnection.close());

  group('the otp:get ttl limit', () {
    test('a refused ttl answers AT0022 and leaves the connection open',
        () async {
      // NOTE the VE runs with the default maximum, 60 minutes.
      for (final String ttl in ['0', '3600001', '99999999999999999999']) {
        expect(
            await firstAtSignConnection.sendRequestToServer('otp:get:ttl:$ttl'),
            startsWith('error:AT0022'));
      }
      final String otp = (await firstAtSignConnection
              .sendRequestToServer('otp:get:ttl:3600000'))
          .replaceFirst('data:', '')
          .trim();
      expect(otp, hasLength(6));
      // NOTE deleted so it doesn't count toward the cap for later tests.
      expect(await firstAtSignConnection.sendRequestToServer('otp:delete:$otp'),
          'data:ok');
    });
  });
}
