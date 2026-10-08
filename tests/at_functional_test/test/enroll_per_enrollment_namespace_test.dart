import 'dart:convert';
import 'dart:io';

import 'package:at_demo_data/at_demo_data.dart' as at_demos;
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/apkam_keys.dart';
import 'package:at_functional_test/utils/encryption_util.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Functional coverage of the per-enrollment reserved namespace
/// (`<enId>.a.__e`) over the wire: who may read and write it, and the move to
/// `r.__e` on revoke.
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
        at_demos.encryptionPrivateKeyMap[firstAtSign]!,
        at_demos.apkamSymmetricKeyMap[firstAtSign]!),
    'encryptedSelfEncKey': EncryptionUtil.encryptValue(
        at_demos.aesKeyMap[firstAtSign]!,
        at_demos.apkamSymmetricKeyMap[firstAtSign]!),
    'encryptedAPKAMSymmetricKey': EncryptionUtil.encryptKey(
        at_demos.apkamSymmetricKeyMap[firstAtSign]!,
        at_demos.encryptionPublicKeyMap[firstAtSign]!)
  };

  setUp(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
  });

  tearDown(() async {
    await firstAtSignConnection.close();
  });

  /// CRAM-authenticate, enroll (auto-approved), then re-connect and APKAM-auth
  /// on the new enrollment id. Returns the enrollment id.
  Future<String> cramEnrollAndApkam() async {
    await firstAtSignConnection.authenticateConnection(authType: AuthType.cram);
    ApkamKeys keys = mintApkamKeys();
    String enrollRequest =
        'enroll:request:{"appName":"wavi-${Uuid().v4().hashCode}","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${keys.publicKey}"}\n';
    var enrollJsonMap = jsonDecode(
        (await firstAtSignConnection.sendRequestToServer(enrollRequest))
            .replaceAll('data:', ''));
    expect(enrollJsonMap['status'], 'approved');
    String enrollmentId = enrollJsonMap['enrollmentId'];
    await firstAtSignConnection.close();
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
    await firstAtSignConnection.authenticateConnection(
        authType: AuthType.apkam,
        enrollmentId: enrollmentId,
        privateKey: keys.privateKey);
    return enrollmentId;
  }

  group('Per-enrollment reserved namespace', () {
    test(
        'an enrollment can update and llookup a self key in its own reserved namespace',
        () async {
      String enrollmentId = await cramEnrollAndApkam();

      String reservedKey =
          '$firstAtSign:some_key.$enrollmentId.a.__e$firstAtSign';
      String updateResponse = await firstAtSignConnection
          .sendRequestToServer('update:$reservedKey privatevalue');
      assert((updateResponse.startsWith('data:')) &&
          (!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));

      String llookupResponse =
          await firstAtSignConnection.sendRequestToServer('llookup:$reservedKey');
      expect(llookupResponse, 'data:privatevalue');
    });

    test('a public key in the reserved namespace is world-readable', () async {
      String enrollmentId = await cramEnrollAndApkam();

      String publicKey = 'public:pub_key.$enrollmentId.a.__e$firstAtSign';
      String updateResponse = await firstAtSignConnection
          .sendRequestToServer('update:$publicKey publicvalue');
      assert((updateResponse.startsWith('data:')) &&
          (!updateResponse.contains('Invalid syntax')) &&
          (!updateResponse.contains('null')));

      OutboundConnectionFactory unauthConnection =
          await OutboundConnectionFactory().initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      String lookupResponse = await unauthConnection.sendRequestToServer(
          'lookup:pub_key.$enrollmentId.a.__e$firstAtSign');
      expect(lookupResponse, 'data:publicvalue');
      await unauthConnection.close();
    });

    test(
        'revoking an enrollment moves its per-enrollment data to r.__e, and '
        'deleting it moves the data to d.__e', () async {
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      var primaryJson = jsonDecode((await firstAtSignConnection.sendRequestToServer(
              'enroll:request:{"appName":"wavi-${Uuid().v4().hashCode}","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${mintApkamKeys().publicKey}"}\n'))
          .replaceAll('data:', ''));
      expect(primaryJson['status'], 'approved');

      String otp = (await firstAtSignConnection.sendRequestToServer('otp:get'))
          .replaceFirst('data:', '')
          .trim();
      OutboundConnectionFactory secondConnection =
          await OutboundConnectionFactory().initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      ApkamKeys secondKeys = mintApkamKeys();
      var secondJson = jsonDecode((await secondConnection.sendRequestToServer(
              'enroll:request:{"appName":"buzz","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"buzz":"rw"},"otp":"$otp","apkamPublicKey":"${secondKeys.publicKey}","encryptedAPKAMSymmetricKey":"${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}\n'))
          .replaceAll('data:', ''));
      expect(secondJson['status'], 'pending');
      String secondEnrollmentId = secondJson['enrollmentId'];
      var approveJson = jsonDecode((await firstAtSignConnection.sendRequestToServer(
              'enroll:approve:{"enrollmentId":"$secondEnrollmentId","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap["encryptedDefaultEncPrivateKey"]}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap["encryptedSelfEncKey"]}"}'))
          .replaceAll('data:', ''));
      expect(approveJson['status'], 'approved');

      String publicKey(String state) =>
          'pub.$secondEnrollmentId.$state.__e$firstAtSign';
      String selfKey(String state) =>
          '$firstAtSign:secret.$secondEnrollmentId.$state.__e$firstAtSign';

      await secondConnection.authenticateConnection(
          authType: AuthType.apkam,
          enrollmentId: secondEnrollmentId,
          privateKey: secondKeys.privateKey);
      for (final update in [
        'update:public:${publicKey('a')} publicvalue',
        'update:${selfKey('a')} selfvalue',
      ]) {
        expect(await secondConnection.sendRequestToServer(update),
            startsWith('data:'),
            reason: update);
      }
      await secondConnection.close();

      OutboundConnectionFactory unauthConnection =
          await OutboundConnectionFactory().initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);

      /// Expects the public and self key to hold their values in [present]
      /// and to be gone from [absent].
      Future<void> expectDataIn(String present,
          {required String absent}) async {
        expect(
            await unauthConnection
                .sendRequestToServer('lookup:${publicKey(present)}'),
            'data:publicvalue');
        expect(
            await firstAtSignConnection
                .sendRequestToServer('llookup:${selfKey(present)}'),
            'data:selfvalue');
        expect(
            await unauthConnection
                .sendRequestToServer('lookup:${publicKey(absent)}'),
            contains('does not exist in keystore'));
        expect(
            await firstAtSignConnection
                .sendRequestToServer('llookup:${selfKey(absent)}'),
            contains('does not exist in keystore'));
      }

      await expectDataIn('a', absent: 'r');

      expect(
          await firstAtSignConnection.sendRequestToServer(
              'enroll:revoke:{"enrollmentId":"$secondEnrollmentId"}'),
          startsWith('data:'));
      await expectDataIn('r', absent: 'a');

      var deleteJson = jsonDecode(
          (await firstAtSignConnection.sendRequestToServer(
                  'enroll:delete:{"enrollmentId":"$secondEnrollmentId"}'))
              .replaceAll('data:', ''));
      expect(deleteJson['status'], 'deleted');
      await expectDataIn('d', absent: 'r');

      await unauthConnection.close();
    });

    test(
        'an expired enrollment\'s per-enrollment data reads as absent before '
        'the expired-keys pass moves it', () async {
      const int expiryMillis = 5000;
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.cram);
      var primaryJson = jsonDecode((await firstAtSignConnection.sendRequestToServer(
              'enroll:request:{"appName":"wavi-${Uuid().v4().hashCode}","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${mintApkamKeys().publicKey}"}\n'))
          .replaceAll('data:', ''));
      expect(primaryJson['status'], 'approved');

      OutboundConnectionFactory unauthConnection =
          await OutboundConnectionFactory().initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);

      /// GETs [path] over HTTP, which an atServer serves on its atProtocol
      /// port to a client that offers `http/1.1` by ALPN.
      Future<(int, String)> httpGet(String path) async {
        final HttpClient client = HttpClient()
          ..connectionFactory = (uri, proxyHost, proxyPort) =>
              SecureSocket.startConnect(uri.host, uri.port,
                  supportedProtocols: ['http/1.1']);
        try {
          final HttpClientResponse response = await (await client.getUrl(
                  Uri.parse('https://$firstAtSignHost:$firstAtSignPort/$path')))
              .close();
          return (
            response.statusCode,
            await response.transform(utf8.decoder).join()
          );
        } finally {
          client.close();
        }
      }

      /// The enrollment's status as `enroll:fetch` reports it, or null once
      /// the expired-keys pass has removed it.
      Future<String?> statusOf(String enrollmentId) async {
        final String response = await firstAtSignConnection.sendRequestToServer(
            'enroll:fetch:{"enrollmentId":"$enrollmentId"}');
        return response.startsWith('data:')
            ? jsonDecode(response.replaceFirst('data:', ''))['status']
            : null;
      }

      /// Enrols with [expiryMillis], writes a public and a self key in the
      /// enrollment's a.__e namespace, and reads both once it has expired.
      /// Returns false when the expired-keys pass removed the enrollment or
      /// moved its data around the reads, which would make absence its doing.
      Future<bool> readsAbsentOnceExpired() async {
        String otp =
            (await firstAtSignConnection.sendRequestToServer('otp:get'))
                .replaceFirst('data:', '')
                .trim();
        OutboundConnectionFactory secondConnection =
            await OutboundConnectionFactory().initiateConnectionWithListener(
                firstAtSign, firstAtSignHost, firstAtSignPort);
        ApkamKeys secondKeys = mintApkamKeys();
        var secondJson = jsonDecode((await secondConnection.sendRequestToServer(
                'enroll:request:{"appName":"buzz","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"buzz":"rw"},"otp":"$otp","apkamPublicKey":"${secondKeys.publicKey}","encryptedAPKAMSymmetricKey":"${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}","apkamKeysExpiryInMillis":$expiryMillis}\n'))
            .replaceAll('data:', ''));
        expect(secondJson['status'], 'pending');
        String enrollmentId = secondJson['enrollmentId'];
        var approveJson = jsonDecode(
            (await firstAtSignConnection.sendRequestToServer(
                    'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap["encryptedDefaultEncPrivateKey"]}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap["encryptedSelfEncKey"]}"}'))
                .replaceAll('data:', ''));
        expect(approveJson['status'], 'approved');

        String publicKey(String state) =>
            'pub.$enrollmentId.$state.__e$firstAtSign';
        String selfKey(String state) =>
            '$firstAtSign:secret.$enrollmentId.$state.__e$firstAtSign';
        String path = 'pub.$enrollmentId.a.__e';

        await secondConnection.authenticateConnection(
            authType: AuthType.apkam,
            enrollmentId: enrollmentId,
            privateKey: secondKeys.privateKey);
        for (final update in [
          'update:public:${publicKey('a')} publicvalue',
          'update:${selfKey('a')} selfvalue',
        ]) {
          expect(await secondConnection.sendRequestToServer(update),
              startsWith('data:'),
              reason: update);
        }
        await secondConnection.close();

        const String live = 'the enrollment must still be live here; raise '
            'expiryMillis if setup outlasts it';
        expect(
            await unauthConnection
                .sendRequestToServer('lookup:${publicKey('a')}'),
            'data:publicvalue',
            reason: live);
        expect(
            await firstAtSignConnection
                .sendRequestToServer('llookup:${selfKey('a')}'),
            'data:selfvalue',
            reason: live);
        expect(await httpGet(path), (200, 'publicvalue'), reason: live);

        final DateTime giveUp = DateTime.now()
            .add(const Duration(milliseconds: expiryMillis + 10000));
        String? status;
        while ((status = await statusOf(enrollmentId)) == 'approved' &&
            DateTime.now().isBefore(giveUp)) {
          await Future.delayed(const Duration(milliseconds: 250));
        }
        if (status != 'expired') {
          expect(status, isNull,
              reason: 'the enrollment never expired: status $status');
          return false;
        }

        final String lookup = await unauthConnection
            .sendRequestToServer('lookup:${publicKey('a')}');
        final String llookup = await firstAtSignConnection
            .sendRequestToServer('llookup:${selfKey('a')}');
        final (int, String) get = await httpGet(path);

        // NOTE the pass moves the data before it removes the record, and
        // neither is undone, so both checks come after the reads.
        if (await statusOf(enrollmentId) != 'expired') return false;
        for (final key in [selfKey('d'), 'public:${publicKey('d')}']) {
          if (!(await firstAtSignConnection.sendRequestToServer('llookup:$key'))
              .contains('does not exist in keystore')) {
            return false;
          }
        }

        expect({
          'lookup': lookup.contains('does not exist in keystore'),
          'llookup': llookup.contains('does not exist in keystore'),
          'HTTP GET': get == (404, '404 Not Found'),
        }, {
          'lookup': true,
          'llookup': true,
          'HTTP GET': true
        },
            reason: 'each read must answer as absent; got\n'
                'lookup: $lookup\nllookup: $llookup\nHTTP GET: $get');
        return true;
      }

      const int attempts = 3;
      for (int attempt = 1; !await readsAbsentOnceExpired(); attempt++) {
        expect(attempt, lessThan(attempts),
            reason: 'the expired-keys pass removed the enrollment around the '
                'reads on all $attempts attempts');
        print('expired-keys pass interfered with attempt $attempt; retrying');
      }
      await unauthConnection.close();
    });

    test(
        'a *:rw + __manage primary cannot read another enrollment\'s per-enrollment (a.__e) data',
        () async {
      await firstAtSignConnection.authenticateConnection(authType: AuthType.cram);
      ApkamKeys primaryKeys = mintApkamKeys();
      String primaryEnroll =
          'enroll:request:{"appName":"wavi-${Uuid().v4().hashCode}","deviceName":"pixel","namespaces":{"wavi":"rw"},"apkamPublicKey":"${primaryKeys.publicKey}"}\n';
      var primaryJson = jsonDecode(
          (await firstAtSignConnection.sendRequestToServer(primaryEnroll))
              .replaceAll('data:', ''));
      expect(primaryJson['status'], 'approved');
      String primaryEnrollmentId = primaryJson['enrollmentId'];

      String otp = (await firstAtSignConnection.sendRequestToServer('otp:get'))
          .replaceFirst('data:', '')
          .trim();
      OutboundConnectionFactory secondConnection =
          await OutboundConnectionFactory().initiateConnectionWithListener(
              firstAtSign, firstAtSignHost, firstAtSignPort);
      ApkamKeys secondKeys = mintApkamKeys();
      String secondEnroll =
          'enroll:request:{"appName":"buzz","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"buzz":"rw"},"otp":"$otp","apkamPublicKey":"${secondKeys.publicKey}","encryptedAPKAMSymmetricKey":"${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"}\n';
      var secondJson = jsonDecode(
          (await secondConnection.sendRequestToServer(secondEnroll))
              .replaceAll('data:', ''));
      expect(secondJson['status'], 'pending');
      String secondEnrollmentId = secondJson['enrollmentId'];

      var approveJson = jsonDecode((await firstAtSignConnection.sendRequestToServer(
              'enroll:approve:{"enrollmentId":"$secondEnrollmentId","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap["encryptedDefaultEncPrivateKey"]}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap["encryptedSelfEncKey"]}"}'))
          .replaceAll('data:', ''));
      expect(approveJson['status'], 'approved');

      await secondConnection.authenticateConnection(
          authType: AuthType.apkam,
          enrollmentId: secondEnrollmentId,
          privateKey: secondKeys.privateKey);
      String approvedKey =
          '$firstAtSign:secret.$secondEnrollmentId.a.__e$firstAtSign';
      String updateResponse = await secondConnection
          .sendRequestToServer('update:$approvedKey topsecret');
      assert((updateResponse.startsWith('data:')) &&
          (!updateResponse.contains('null')));
      expect(await secondConnection.sendRequestToServer('llookup:$approvedKey'),
          'data:topsecret');
      await secondConnection.close();

      expect(
          await firstAtSignConnection.sendRequestToServer('llookup:$approvedKey'),
          'data:topsecret',
          reason: 'a CRAM connection is the atSign, whatever it has enrolled');

      await firstAtSignConnection.close();
      await firstAtSignConnection.initiateConnectionWithListener(
          firstAtSign, firstAtSignHost, firstAtSignPort);
      await firstAtSignConnection.authenticateConnection(
          authType: AuthType.apkam,
          enrollmentId: primaryEnrollmentId,
          privateKey: primaryKeys.privateKey);
      String crossRead = await firstAtSignConnection
          .sendRequestToServer('llookup:$approvedKey');
      expect(crossRead, isNot(contains('topsecret')),
          reason: 'primary must not see another enrollment\'s a.__e value');
      expect(crossRead.toLowerCase(),
          anyOf(startsWith('error:'), contains('not authorized')));
    });
  });
}
