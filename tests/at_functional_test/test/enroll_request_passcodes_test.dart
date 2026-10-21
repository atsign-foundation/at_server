import 'dart:convert';

import 'package:at_demo_data/at_demo_data.dart' as at_demos;
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/apkam_keys.dart';
import 'package:at_functional_test/utils/encryption_util.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Catalogue: features/enrollment/enroll_request_passcodes.feature
void main() {
  final String atSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  final String host =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  final int port =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];
  final String encryptedApkamSymmetricKey = EncryptionUtil.encryptKey(
      at_demos.apkamSymmetricKeyMap[atSign]!,
      at_demos.encryptionPublicKeyMap[atSign]!);

  Future<OutboundConnectionFactory> connect() => OutboundConnectionFactory()
      .initiateConnectionWithListener(atSign, host, port);

  /// Sends an enroll:request with [passcode] on a new unauthenticated
  /// connection, answering the atServer's response.
  Future<String> enrollRequest(String passcode) async {
    final OutboundConnectionFactory connection = await connect();
    try {
      return await connection.sendRequestToServer('enroll:request:'
          '{"appName":"passcodes-${Uuid().v4()}","deviceName":"device"'
          ',"namespaces":{"wavi":"rw"},"otp":"$passcode"'
          ',"apkamPublicKey":"${mintApkamKeys().publicKey}"'
          ',"encryptedAPKAMSymmetricKey":"$encryptedApkamSymmetricKey"}');
    } finally {
      await connection.close();
    }
  }

  /// Issues an OTP over a CRAM connection of the atSign's.
  Future<String> issueOtp() async {
    final OutboundConnectionFactory owner = await connect();
    try {
      await owner.authenticateConnection(authType: AuthType.cram);
      return (await owner.sendRequestToServer('otp:get'))
          .replaceFirst('data:', '');
    } finally {
      await owner.close();
    }
  }

  group('An issued OTP in another spelling is refused', () {
    for (final (String example, String Function(String) spell) in [
      ('P with a leading space', (String p) => ' $p'),
      (
        'P with a space inside it',
        (String p) => '${p.substring(0, 3)} '
            '${p.substring(3)}'
      ),
    ]) {
      test(example, () async {
        final String otp = await issueOtp();
        expect(await enrollRequest(spell(otp)),
            contains('invalid otp. Cannot process enroll request'));
        final Map<String, dynamic> accepted =
            jsonDecode((await enrollRequest(otp)).replaceFirst('data:', ''));
        expect(accepted['status'], 'pending');
      });
    }
  });
}
