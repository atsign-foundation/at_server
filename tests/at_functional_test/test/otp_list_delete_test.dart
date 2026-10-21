import 'dart:convert';

import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/apkam_keys.dart';
import 'package:at_functional_test/utils/encryption_util.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Functional (over-the-wire) coverage for otp:list and otp:delete, and for
/// otp:put needing full privilege.
void main() {
  OutboundConnectionFactory firstAtSignConnection = OutboundConnectionFactory();
  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  Map<String, String> apkamEncryptedKeysMap = <String, String>{
    'encryptedDefaultEncPrivateKey': EncryptionUtil.encryptValue(
        encryptionPrivateKeyMap[firstAtSign]!,
        apkamSymmetricKeyMap[firstAtSign]!),
    'encryptedSelfEncKey': EncryptionUtil.encryptValue(
        aesKeyMap[firstAtSign]!, apkamSymmetricKeyMap[firstAtSign]!),
    'encryptedAPKAMSymmetricKey': EncryptionUtil.encryptKey(
        apkamSymmetricKeyMap[firstAtSign]!,
        encryptionPublicKeyMap[firstAtSign]!)
  };

  setUp(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
    await firstAtSignConnection.authenticateConnection(authType: AuthType.cram);
  });

  group('otp:list and otp:delete', () {
    /// Owner (CRAM-authed) issues an OTP, a second connection sends an
    /// enroll:request for [namespaces], the owner approves it, and the second
    /// connection APKAM-authenticates.
    Future<OutboundConnectionFactory> approvedEnrollment(
        Map<String, String> namespaces) async {
      final otp = (await firstAtSignConnection.sendRequestToServer('otp:get'))
          .replaceAll('data:', '')
          .trim();
      final conn = await OutboundConnectionFactory()
          .initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      final keys = mintApkamKeys();
      final pending = jsonDecode(
          (await conn.sendRequestToServer('enroll:request:${jsonEncode({
            'appName': 'app-${Uuid().v4().hashCode}',
            'deviceName': 'device-${Uuid().v4().hashCode}',
            'namespaces': namespaces,
            'otp': otp,
            'apkamPublicKey': keys.publicKey,
            'encryptedAPKAMSymmetricKey':
                apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey'],
          })}\n'))
              .replaceAll('data:', ''));
      final enrollmentId = pending['enrollmentId'] as String;
      final approve = jsonDecode((await firstAtSignConnection
              .sendRequestToServer('enroll:approve:${jsonEncode({
            'enrollmentId': enrollmentId,
            'encryptedDefaultEncryptionPrivateKey':
                apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey'],
            'encryptedDefaultSelfEncryptionKey':
                apkamEncryptedKeysMap['encryptedSelfEncKey'],
          })}'))
          .replaceAll('data:', ''));
      expect(approve['status'], 'approved');
      await conn.authenticateConnection(
          authType: AuthType.apkam,
          enrollmentId: enrollmentId,
          privateKey: keys.privateKey);
      return conn;
    }

    String data(String response) => response.replaceFirst('data:', '').trim();

    /// The `type:value` of each passcode an otp:list answer lists.
    List<String> listed(String response) => (jsonDecode(data(response)) as List)
        .map((e) => '${e['type']}:${e['value']}')
        .toList();

    test('a __manage enrollment lists and deletes only the OTPs it covers',
        () async {
      final both = await approvedEnrollment(
          {'app_1': 'rw', 'app_2': 'rw', '__manage': 'rw'});
      final two = await approvedEnrollment({'app_2': 'rw', '__manage': 'rw'});
      final bothOtp = data(await both.sendRequestToServer('otp:get'));
      final twoOtp = data(await two.sendRequestToServer('otp:get'));

      // NOTE contains rather than equals: other tests' OTPs may still be live.
      expect(listed(await two.sendRequestToServer('otp:list')),
          allOf(contains('otp:$twoOtp'), isNot(contains('otp:$bothOtp'))));
      expect(listed(await both.sendRequestToServer('otp:list')),
          containsAll(['otp:$bothOtp', 'otp:$twoOtp']));

      expect(await two.sendRequestToServer('otp:delete:$bothOtp'), 'data:ok');
      expect(listed(await both.sendRequestToServer('otp:list')),
          contains('otp:$bothOtp'));
      expect(await two.sendRequestToServer('otp:delete:$twoOtp'), 'data:ok');
      expect(listed(await both.sendRequestToServer('otp:list')),
          isNot(contains('otp:$twoOtp')));
      await both.close();
      await two.close();
    });

    test('otp:list is refused for an enrollment without __manage', () async {
      final scoped = await approvedEnrollment({'buzz': 'rw'});
      expect(
          await scoped.sendRequestToServer('otp:list'), startsWith('error:'));
      await scoped.close();
    });

    test('only a full-privilege connection sets, sees or deletes the SPP',
        () async {
      final spp = 'Spp${Uuid().v4().hashCode}';
      final manage = await approvedEnrollment({'__manage': 'rw'});
      expect(await manage.sendRequestToServer('otp:put:Other123'),
          startsWith('error:'));
      expect(await firstAtSignConnection.sendRequestToServer('otp:put:$spp'),
          'data:ok');

      expect(
          listed(await firstAtSignConnection.sendRequestToServer('otp:list')),
          contains('spp:$spp'));
      expect(listed(await manage.sendRequestToServer('otp:list')),
          isNot(contains('spp:$spp')));
      expect(await manage.sendRequestToServer('otp:delete:spp'), 'data:ok');
      expect(
          listed(await firstAtSignConnection.sendRequestToServer('otp:list')),
          contains('spp:$spp'));

      expect(await firstAtSignConnection.sendRequestToServer('otp:delete:spp'),
          'data:ok');
      expect(
          listed(await firstAtSignConnection.sendRequestToServer('otp:list')),
          isNot(contains('spp:$spp')));
      await manage.close();
    });

    test('otp:delete of an unknown OTP answers data:ok', () async {
      expect(
          await firstAtSignConnection.sendRequestToServer('otp:delete:NOSUCH1'),
          'data:ok');
    });
  });
}
