import 'dart:convert';

import 'package:at_demo_data/at_demo_data.dart' as at_demos;
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/apkam_keys.dart';
import 'package:at_functional_test/utils/encryption_util.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Scenarios: features/enrollment/keys_verb_own_encryption_keys.feature
void main() {
  OutboundConnectionFactory firstAtSignConnection = OutboundConnectionFactory();
  OutboundConnectionFactory secondAtSignConnection =
      OutboundConnectionFactory();
  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  Map<String, String> apkamEncryptedKeysMap = <String, String>{
    'encryptedDefaultEncPrivateKey': EncryptionUtil.encryptValue(
        at_demos.encryptionPrivateKeyMap[firstAtSign]!,
        at_demos.apkamSymmetricKeyMap[firstAtSign]!),
    'encryptedSelfEncKey': EncryptionUtil.encryptValue(
        at_demos.aesKeyMap[firstAtSign]!,
        at_demos.apkamSymmetricKeyMap[firstAtSign]!),
    'encryptedAPKAMSymmetricKey': EncryptionUtil.encryptKey(
        at_demos.apkamSymmetricKeyMap[firstAtSign]!,
        at_demos.encryptionPublicKeyMap[firstAtSign]!)
  };

  String privateKeyOf(String id) =>
      '$id.default_enc_private_key.__manage$firstAtSign';
  String selfKeyOf(String id) =>
      '$id.default_self_enc_key.__manage$firstAtSign';

  /// The error code in [response], written plain or as JSON.
  String? errorCodeOf(String response) => response.startsWith('error:')
      ? RegExp(r'AT\d{4}').firstMatch(response)?.group(0)
      : null;

  setUp(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
    await secondAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
  });

  /// Enrols over an OTP from a CRAM-authenticated first connection, approves
  /// it there, which stores its two keys, and authenticates the second
  /// connection as it. Returns the enrollment's id and the first
  /// connection's own enrollment id.
  Future<(String, String)> approvedEnrollment() async {
    await firstAtSignConnection.authenticateConnection(authType: AuthType.cram);
    final String firstResponse = (await firstAtSignConnection.sendRequestToServer(
            'enroll:request:{"appName":"wavi","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"wavi":"rw"},"apkamPublicKey":"${mintApkamKeys().publicKey}"}'))
        .replaceFirst('data:', '');
    final String firstEnrollmentId = jsonDecode(firstResponse)['enrollmentId'];
    final String otp =
        (await firstAtSignConnection.sendRequestToServer('otp:get'))
            .replaceFirst('data:', '')
            .trim();

    final ApkamKeys keys = mintApkamKeys();
    final String enrollResponse = (await secondAtSignConnection.sendRequestToServer(
            'enroll:request:{"appName":"buzz","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"buzz":"rw"},"otp":"$otp","apkamPublicKey":"${keys.publicKey}","encryptedAPKAMSymmetricKey": "${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}'))
        .replaceFirst('data:', '');
    final String enrollmentId = jsonDecode(enrollResponse)['enrollmentId'];

    final String approveResponse = (await firstAtSignConnection.sendRequestToServer(
            'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap["encryptedDefaultEncPrivateKey"]}","encryptedDefaultSelfEncryptionKey": "${apkamEncryptedKeysMap["encryptedSelfEncKey"]}"}'))
        .replaceFirst('data:', '');
    expect(jsonDecode(approveResponse)['status'], 'approved');

    await secondAtSignConnection.authenticateConnection(
        authType: AuthType.apkam,
        enrollmentId: enrollmentId,
        privateKey: keys.privateKey);
    return (enrollmentId, firstEnrollmentId);
  }

  group('An enrollment reads its own encryption key by keyName', () {
    test('encryption private key', () async {
      final (String e, _) = await approvedEnrollment();

      final String response = await secondAtSignConnection
          .sendRequestToServer('keys:get:keyName:${privateKeyOf(e)}');

      expect(jsonDecode(response.replaceFirst('data:', ''))['value'],
          apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey']);
    });

    test('self encryption key', () async {
      final (String e, _) = await approvedEnrollment();

      final String response = await secondAtSignConnection
          .sendRequestToServer('keys:get:keyName:${selfKeyOf(e)}');

      expect(jsonDecode(response.replaceFirst('data:', ''))['value'],
          apkamEncryptedKeysMap['encryptedSelfEncKey']);
    });
  });

  test(
      'Every other keys: request is refused before the store is read or '
      'written', () async {
    final (String e, String f) = await approvedEnrollment();
    final List<String> requests = [
      'keys:put:public:namespace:__global:keyType:rsa2048:keyName:encryption_$e planted',
      'keys:put:self:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes256:encryptionKeyName:encryption_$e:keyName:myAESkey planted',
      'keys:put:private:namespace:__global:appName:wavi:deviceName:pixel:keyType:aes:encryptionKeyName:myAESkey:keyName:myPrivateKey planted',
      'keys:put:public:namespace:app:keyName:__nskey planted',
      'keys:delete:keyName:${privateKeyOf(e)}',
      'keys:get:private',
      'keys:get:self',
      'keys:get:public',
      'keys:get:keyName:${privateKeyOf(f)}',
      'keys:get:keyName:privatekey:at_secret',
      'keys:get:self:keyName:${selfKeyOf(e)}',
      'keys:get:namespace:__global:keyName:${selfKeyOf(e)}',
      'keys:get:keyName:${privateKeyOf(e)} planted',
    ];
    for (final String request in requests) {
      expect(
          errorCodeOf(
              await secondAtSignConnection.sendRequestToServer(request)),
          'AT0009',
          reason: request);
    }

    for (final String key in [
      'public:encryption_$e.__public_keys.__global$firstAtSign',
      'public:__nskey.__public_keys.app$firstAtSign',
    ]) {
      expect(
          errorCodeOf(
              await firstAtSignConnection.sendRequestToServer('llookup:$key')),
          'AT0015',
          reason: '$key is not stored');
    }
    final String stillThere = await secondAtSignConnection
        .sendRequestToServer('keys:get:keyName:${privateKeyOf(e)}');
    expect(jsonDecode(stillThere.replaceFirst('data:', ''))['value'],
        apkamEncryptedKeysMap['encryptedDefaultEncPrivateKey'],
        reason: 'the refused keys:delete deleted nothing');
  });

  test('A connection carrying no enrollment id is refused', () async {
    await firstAtSignConnection.authenticateConnection(authType: AuthType.cram);

    final String response = await firstAtSignConnection
        .sendRequestToServer('keys:get:keyName:${selfKeyOf(Uuid().v4())}');

    expect(response, startsWith('error:'));
    expect(response,
        contains('Keys verb cannot be accessed without an enrollmentId'));
  });

  test('check keys verb get operation - without authentication', () async {
    var getResponse =
        await firstAtSignConnection.sendRequestToServer('keys:get:self');
    expect(getResponse,
        'error:AT0401-Exception: Command cannot be executed without auth');
  });

  test('check keys verb put operation - without authentication', () async {
    var putCommand =
        'keys:put:public:namespace:__global:keyType:rsa2048:keyName:encryption_12344444 testPublicKeyValue';
    var putResponse =
        await firstAtSignConnection.sendRequestToServer(putCommand);
    expect(putResponse,
        'error:AT0401-Exception: Command cannot be executed without auth');
  });
}
