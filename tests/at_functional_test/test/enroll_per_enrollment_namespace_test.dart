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

    group('The first lookup after an enrollment expires moves its data', () {
      const int expiryMillis = 5000;
      late OutboundConnectionFactory unauthConnection;

      setUp(() async {
        await firstAtSignConnection.authenticateConnection(
            authType: AuthType.cram);
        unauthConnection = await OutboundConnectionFactory()
            .initiateConnectionWithListener(
                firstAtSign, firstAtSignHost, firstAtSignPort);
      });

      tearDown(() async {
        await unauthConnection.close();
      });

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
      /// its record has been removed.
      Future<String?> statusOf(String enrollmentId) async {
        final String response = await firstAtSignConnection.sendRequestToServer(
            'enroll:fetch:{"enrollmentId":"$enrollmentId"}');
        return response.startsWith('data:')
            ? jsonDecode(response.replaceFirst('data:', ''))['status']
            : null;
      }

      String publicKey(String enrollmentId, String state) =>
          'pub.$enrollmentId.$state.__e$firstAtSign';
      String selfKey(String enrollmentId, String state) =>
          '$firstAtSign:secret.$enrollmentId.$state.__e$firstAtSign';

      /// Enrols, with [expiryMillis] when [expiring], and writes a public and
      /// a self key in the enrollment's a.__e namespace. Returns its id.
      Future<String> enrollmentWithData({required bool expiring}) async {
        String otp =
            (await firstAtSignConnection.sendRequestToServer('otp:get'))
                .replaceFirst('data:', '')
                .trim();
        OutboundConnectionFactory secondConnection =
            await OutboundConnectionFactory().initiateConnectionWithListener(
                firstAtSign, firstAtSignHost, firstAtSignPort);
        ApkamKeys secondKeys = mintApkamKeys();
        final String expiry =
            expiring ? ',"apkamKeysExpiryInMillis":$expiryMillis' : '';
        var secondJson = jsonDecode((await secondConnection.sendRequestToServer(
                'enroll:request:{"appName":"buzz","deviceName":"pixel-${Uuid().v4().hashCode}","namespaces":{"buzz":"rw"},"otp":"$otp","apkamPublicKey":"${secondKeys.publicKey}","encryptedAPKAMSymmetricKey":"${apkamEncryptedKeysMap['encryptedAPKAMSymmetricKey']}"$expiry}\n'))
            .replaceAll('data:', ''));
        expect(secondJson['status'], 'pending');
        String enrollmentId = secondJson['enrollmentId'];
        var approveJson = jsonDecode(
            (await firstAtSignConnection.sendRequestToServer(
                    'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"${apkamEncryptedKeysMap["encryptedDefaultEncPrivateKey"]}","encryptedDefaultSelfEncryptionKey":"${apkamEncryptedKeysMap["encryptedSelfEncKey"]}"}'))
                .replaceAll('data:', ''));
        expect(approveJson['status'], 'approved');

        await secondConnection.authenticateConnection(
            authType: AuthType.apkam,
            enrollmentId: enrollmentId,
            privateKey: secondKeys.privateKey);
        for (final update in [
          'update:public:${publicKey(enrollmentId, 'a')} publicvalue',
          'update:${selfKey(enrollmentId, 'a')} selfvalue',
        ]) {
          expect(await secondConnection.sendRequestToServer(update),
              startsWith('data:'),
              reason: update);
        }
        await secondConnection.close();
        return enrollmentId;
      }

      /// An enrollment with data whose ttl has elapsed and whose record the
      /// expired-keys pass has not yet removed, or null when the pass got
      /// there first.
      Future<String?> expiredEnrollmentWithData() async {
        final String enrollmentId =
            await enrollmentWithData(expiring: true);
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
          return null;
        }
        return enrollmentId;
      }

      for (final String row in ['lookup', 'llookup', 'HTTP GET']) {
        test(row, () async {
          String? found;
          for (int attempt = 1;
              (found = await expiredEnrollmentWithData()) == null;
              attempt++) {
            expect(attempt, lessThan(3),
                reason: 'the expired-keys pass removed the enrollment '
                    'before every attempt\'s read');
          }
          final String id = found!;

          final String answer = switch (row) {
            'lookup' => await unauthConnection
                .sendRequestToServer('lookup:${publicKey(id, 'a')}'),
            'llookup' => await firstAtSignConnection
                .sendRequestToServer('llookup:${selfKey(id, 'a')}'),
            _ => '${await httpGet('pub.$id.a.__e')}',
          };

          expect(
              answer,
              row == 'HTTP GET'
                  ? '(404, 404 Not Found)'
                  : contains('does not exist in keystore'));
          expect(await statusOf(id), isNull,
              reason: 'the record is gone, exactly as after the sweep');
          expect(
              await firstAtSignConnection
                  .sendRequestToServer('llookup:${selfKey(id, 'd')}'),
              'data:selfvalue');
          expect(
              await unauthConnection
                  .sendRequestToServer('lookup:${publicKey(id, 'd')}'),
              'data:publicvalue',
              reason: 'a lookup of the d.__e key straight after finds it');
        });
      }

      test('A lookup of a live enrollment\'s data moves nothing', () async {
        final String id = await enrollmentWithData(expiring: false);

        expect(
            await unauthConnection
                .sendRequestToServer('lookup:${publicKey(id, 'a')}'),
            'data:publicvalue');

        expect(await statusOf(id), 'approved');
        expect(
            await firstAtSignConnection
                .sendRequestToServer('llookup:${selfKey(id, 'a')}'),
            'data:selfvalue');
      });
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
