import 'dart:convert';
import 'dart:math';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_demo_data/at_demo_data.dart' as at_demos;
import 'package:at_functional_test/utils/apkam_keys.dart';
import 'package:at_functional_test/utils/encryption_util.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Probe: a per-passkey at-keys record stored as
/// `public:_<64 lowercase hex>.atkeysv@<atSign>` on the existing verbs.
void main() {
  final config = ConfigUtil.getYaml()!;
  final String alice = config['firstAtSignServer']['firstAtSignName'];
  final String host = config['firstAtSignServer']['firstAtSignUrl'];
  final int alicePort = config['firstAtSignServer']['firstAtSignPort'];
  final String bob = config['secondAtSignServer']['secondAtSignName'];
  const int bobPort = 25003;

  final record = jsonEncode({
    'v': 2,
    'alg': 'A256GCM',
    'kdf': 'HKDF-SHA256',
    'iv': 'AAECAwQFBgcICQoL',
    'ct': 'c2VjcmV0LWF0a2V5cy1ibG9i',
  });

  String lookupHex() {
    final random = Random.secure();
    return List.generate(32, (_) => random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  String recordKey(String hex, String atSign) => '_$hex.atkeysv$atSign';

  final opened = <OutboundConnectionFactory>[];

  Future<OutboundConnectionFactory> connect(String atSign, int port,
      {AuthType? auth}) async {
    final connection = await OutboundConnectionFactory()
        .initiateConnectionWithListener(atSign, host, port);
    opened.add(connection);
    if (auth != null) {
      await connection.authenticateConnection(authType: auth);
    }
    return connection;
  }

  final apkamKeysMaterial = {
    'encryptedDefaultEncryptionPrivateKey': EncryptionUtil.encryptValue(
        at_demos.encryptionPrivateKeyMap[alice]!,
        at_demos.apkamSymmetricKeyMap[alice]!),
    'encryptedDefaultSelfEncryptionKey': EncryptionUtil.encryptValue(
        at_demos.aesKeyMap[alice]!, at_demos.apkamSymmetricKeyMap[alice]!),
  };
  final encryptedApkamSymmetricKey = EncryptionUtil.encryptKey(
      at_demos.apkamSymmetricKeyMap[alice]!,
      at_demos.encryptionPublicKeyMap[alice]!);

  Map<String, dynamic> data(String response) =>
      jsonDecode(response.replaceFirst('data:', ''));

  /// An OTP-gated enrollment approved over CRAM, holding only [namespaces].
  Future<OutboundConnectionFactory> enrolled(
      Map<String, String> namespaces) async {
    final cram = await connect(alice, alicePort, auth: AuthType.cram);
    final otp = (await cram.sendRequestToServer('otp:get'))
        .replaceFirst('data:', '')
        .trim();
    final keys = mintApkamKeys();
    final apkam = await connect(alice, alicePort);
    final request =
        data(await apkam.sendRequestToServer('enroll:request:${jsonEncode({
          'appName': 'atkeys-probe',
          'deviceName': 'browser-${Uuid().v4().hashCode}',
          'namespaces': namespaces,
          'otp': otp,
          'apkamPublicKey': keys.publicKey,
          'encryptedAPKAMSymmetricKey': encryptedApkamSymmetricKey,
        })}'));
    expect(request['status'], 'pending');
    final enrollmentId = request['enrollmentId'];
    final approval =
        data(await cram.sendRequestToServer('enroll:approve:${jsonEncode({
          'enrollmentId': enrollmentId,
          ...apkamKeysMaterial,
        })}'));
    expect(approval['status'], 'approved');
    await apkam.authenticateConnection(
        authType: AuthType.apkam,
        enrollmentId: enrollmentId,
        privateKey: keys.privateKey);
    final grant = data(await cram.sendRequestToServer(
            'enroll:fetch:${jsonEncode({'enrollmentId': enrollmentId})}'))[
        'namespace'];
    expect(grant, isNot(contains('*')), reason: 'grant: $grant');
    return apkam;
  }

  Future<String> put(OutboundConnectionFactory connection, String key,
          {int ttl = 60000}) =>
      connection.sendRequestToServer('update:ttl:$ttl:public:$key $record');

  Future<int> expiresAt(OutboundConnectionFactory owner, String key) async {
    final meta =
        data(await owner.sendRequestToServer('llookup:meta:public:$key'));
    return DateTime.parse(meta['expiresAt']).millisecondsSinceEpoch;
  }

  tearDown(() async {
    for (final connection in opened) {
      await connection.close();
    }
    opened.clear();
  });

  test('P1 the name is accepted and round-trips', () async {
    final owner = await connect(alice, alicePort, auth: AuthType.cram);
    final key = recordKey(lookupHex(), alice);
    expect(await put(owner, key), startsWith('data:'));
    expect(
        await owner.sendRequestToServer('llookup:public:$key'), 'data:$record');
  });

  test(
      'P2 unauthenticated lookup on the owner server reads it; a miss is AT0015',
      () async {
    final owner = await connect(alice, alicePort, auth: AuthType.cram);
    final key = recordKey(lookupHex(), alice);
    await put(owner, key);
    final anonymous = await connect(alice, alicePort);
    expect(await anonymous.sendRequestToServer('lookup:$key'), 'data:$record');
    expect(
        await anonymous
            .sendRequestToServer('lookup:${recordKey(lookupHex(), alice)}'),
        startsWith('error:AT0015'));
  });

  test('P3 atkeysv:rw enrollment writes and deletes; other namespaces cannot',
      () async {
    final writer = await enrolled({'atkeysv': 'rw'});
    final key = recordKey(lookupHex(), alice);
    expect(await put(writer, key), startsWith('data:'));

    final outsider = await enrolled({'wavi': 'rw'});
    expect(await put(outsider, recordKey(lookupHex(), alice)),
        startsWith('error:'));
    expect(await outsider.sendRequestToServer('delete:public:$key'),
        startsWith('error:'));

    expect(await writer.sendRequestToServer('delete:public:$key'),
        startsWith('data:'));
  });

  test('P4 one atkeysv enrollment can delete another enrollment\'s record',
      () async {
    final x = await enrolled({'atkeysv': 'rw'});
    final y = await enrolled({'atkeysv': 'rw'});
    final key = recordKey(lookupHex(), alice);
    await put(x, key);
    expect(
        await y.sendRequestToServer('delete:public:$key'), startsWith('data:'));
    final anonymous = await connect(alice, alicePort);
    expect(await anonymous.sendRequestToServer('lookup:$key'),
        startsWith('error:AT0015'));
  });

  test(
      'P5 re-update with ttl pushes expiresAt forward; an expired record reads as data:null',
      () async {
    final owner = await connect(alice, alicePort, auth: AuthType.cram);
    final key = recordKey(lookupHex(), alice);
    await put(owner, key, ttl: 5000);
    final first = await expiresAt(owner, key);
    await put(owner, key, ttl: 600000);
    final refreshed = await expiresAt(owner, key);
    expect(refreshed - first, greaterThan(500000));

    final shortLived = recordKey(lookupHex(), alice);
    await put(owner, shortLived, ttl: 1000);
    await Future.delayed(Duration(seconds: 3));
    final anonymous = await connect(alice, alicePort);
    expect(
        await anonymous.sendRequestToServer('lookup:$shortLived'), 'data:null');
  });

  test('P6 plookup via another atServer leaves no cached copy; delete is final',
      () async {
    final owner = await connect(bob, bobPort, auth: AuthType.cram);
    final hex = lookupHex();
    final key = recordKey(hex, bob);
    await put(owner, key);

    final reader = await connect(alice, alicePort, auth: AuthType.cram);
    expect(await reader.sendRequestToServer('plookup:$key'), 'data:$record');
    expect(await reader.sendRequestToServer('llookup:cached:public:$key'),
        startsWith('error:{"errorCode":"AT0015"'));

    await owner.sendRequestToServer('delete:public:$key');
    expect(await reader.sendRequestToServer('plookup:$key'),
        startsWith('error:{"errorCode":"AT0015"'));
  });

  test('P7 no scan lists it and it has no commit-log row', () async {
    final hex = lookupHex();
    final owner = await connect(alice, alicePort, auth: AuthType.cram);
    await put(owner, recordKey(hex, alice));

    final responses = <String, String>{
      'owner scan': await owner.sendRequestToServer('scan'),
      'owner scan:showhidden':
          await owner.sendRequestToServer('scan:showhidden:true'),
      'owner scan:cl': await owner.sendRequestToServer('scan:cl'),
      'owner scan:cl:showhidden':
          await owner.sendRequestToServer('scan:cl:showhidden:true'),
      'apkam scan:showhidden': await (await enrolled({'atkeysv': 'rw'}))
          .sendRequestToServer('scan:showhidden:true'),
      'anonymous scan':
          await (await connect(alice, alicePort)).sendRequestToServer('scan'),
      'pol scan from $bob':
          await (await connect(bob, bobPort, auth: AuthType.cram))
              .sendRequestToServer('scan:$alice'),
    };
    for (final MapEntry(:key, :value) in responses.entries) {
      expect(value, startsWith('data:'), reason: '$key → $value');
      expect(value, isNot(contains(hex)), reason: key);
    }
  });
}
