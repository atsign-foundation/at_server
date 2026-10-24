import 'dart:convert';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';

/// Functional (over-the-wire) coverage for the otp:get limits: the ttl limit
/// and the live-OTP limit. The pack runs one file at a time
/// (--concurrency=1), so no other test issues OTPs while the cap is full.
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
        final String response =
            await firstAtSignConnection.sendRequestToServer('otp:get:ttl:$ttl');
        // NOTE an authenticated connection answers errors as JSON.
        expect(response, startsWith('error:'));
        expect(jsonDecode(response.replaceFirst('error:', ''))['errorCode'],
            'AT0022');
      }
      // NOTE exactly the maximum, which NoPorts issue_keys asks for, so it
      // must not be refused for its ttl. Earlier test files may have filled
      // the live-OTP cap; the ttl is checked first, so AT0028 then still
      // shows the ttl was accepted.
      final String accepted = await firstAtSignConnection
          .sendRequestToServer('otp:get:ttl:3600000');
      if (accepted.startsWith('data:')) {
        final String otp = accepted.replaceFirst('data:', '').trim();
        expect(otp, hasLength(6));
        // NOTE deleted so it doesn't count toward the cap for later tests.
        expect(
            await firstAtSignConnection.sendRequestToServer('otp:delete:$otp'),
            'data:ok');
      } else {
        expect(jsonDecode(accepted.replaceFirst('error:', ''))['errorCode'],
            'AT0028');
      }
    });
  });

  group('the live-OTP limit', () {
    test('a full cap answers AT0028 and leaves the connection open', () async {
      // NOTE the VE runs with the default maximum, 10. Other test files' OTPs
      // may still be live, so this issues OTPs until refused rather than
      // exactly 10, and deletes only its own.
      final List<String> issued = [];
      String data(String response) => response.replaceFirst('data:', '').trim();
      // NOTE a 30-second ttl, so any OTP a failed run leaves behind stops
      // counting toward the cap long before the pack's later tests.
      Future<String> issue() =>
          firstAtSignConnection.sendRequestToServer('otp:get:ttl:30000');
      try {
        String response = await issue();
        for (int i = 0; i < 20 && response.startsWith('data:'); i++) {
          issued.add(data(response));
          response = await issue();
        }
        expect(response, startsWith('error:'),
            reason: 'otp:get was never refused');
        expect(jsonDecode(response.replaceFirst('error:', ''))['errorCode'],
            'AT0028');

        // The same connection still answers, and a delete frees a place.
        if (issued.isNotEmpty) {
          expect(
              await firstAtSignConnection
                  .sendRequestToServer('otp:delete:${issued.removeLast()}'),
              'data:ok');
          response = await issue();
          expect(response, startsWith('data:'));
          issued.add(data(response));
        } else {
          expect(await firstAtSignConnection.sendRequestToServer('otp:list'),
              startsWith('data:'));
        }
      } finally {
        for (final String otp in issued) {
          await firstAtSignConnection.sendRequestToServer('otp:delete:$otp');
        }
      }
    });
  });
}
