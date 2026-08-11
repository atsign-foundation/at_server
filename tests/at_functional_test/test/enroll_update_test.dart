import 'dart:convert';

import 'package:at_chops/at_chops.dart';
import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/auth_utils.dart';
import 'package:at_functional_test/utils/encryption_util.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Functional coverage of `enroll:update` — an approved enrollment amending
/// its own record, and in particular rotating its APKAM authentication
/// keypair while keeping its enrollment id.
///
/// The unit suite in `at_secondary_server` pins the handler's decisions
/// directly. What only the wire can show is the thing the whole operation
/// exists for: after a rotation the NEW key authenticates and the OLD one
/// does not. A unit test can assert the record changed; it cannot assert that
/// PKAM now judges a different key.
void main() {
  String atSign = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String host = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int port = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  String apkamPublicKey = apkamPublicKeyMap[atSign]!;
  String apkamPrivateKey = apkamPrivateKeyMap[atSign]!;
  String encryptedPrivateKey = EncryptionUtil.encryptValue(
      encryptionPrivateKeyMap[atSign]!, apkamSymmetricKeyMap[atSign]!);
  String encryptedSelfKey = EncryptionUtil.encryptValue(
      aesKeyMap[atSign]!, apkamSymmetricKeyMap[atSign]!);
  String encryptedApkamSymmetricKey = EncryptionUtil.encryptKey(
      apkamSymmetricKeyMap[atSign]!, encryptionPublicKeyMap[atSign]!);

  List<OutboundConnectionFactory> open = [];

  Future<OutboundConnectionFactory> newConnection() async {
    OutboundConnectionFactory c = await OutboundConnectionFactory()
        .initiateConnectionWithListener(atSign, host, port);
    open.add(c);
    return c;
  }

  Future<OutboundConnectionFactory> ownerConnection() async {
    OutboundConnectionFactory c = await newConnection();
    expect((await c.authenticateConnection(authType: AuthType.cram)).trim(),
        'data:success');
    return c;
  }

  /// An approved enrollment holding [namespaces], via the ordinary OTP flow.
  ///
  /// Run-unique app/device names: an approved `(appName, deviceName)` pair
  /// cannot be re-used, so fixed names pass once and collide on the next run
  /// against the same virtualenv.
  Future<String> createApprovedEnrollment(OutboundConnectionFactory owner,
      {required Map<String, String> namespaces}) async {
    String otp = (await owner.sendRequestToServer('otp:get'))
        .replaceFirst('data:', '')
        .trim();
    String appName = 'upd-app-${Uuid().v4().hashCode}';
    String deviceName = 'upd-dev-${Uuid().v4().hashCode}';
    // One enroll:request per connection: the rate limiter is per-connection.
    OutboundConnectionFactory requester = await newConnection();
    String response = await requester.sendRequestToServer(
        'enroll:request:{"appName":"$appName","deviceName":"$deviceName","namespaces":${jsonEncode(namespaces)},"otp":"$otp","apkamPublicKey":"$apkamPublicKey","encryptedAPKAMSymmetricKey":"$encryptedApkamSymmetricKey"}');
    String enrollmentId =
        jsonDecode(response.replaceFirst('data:', ''))['enrollmentId'];
    String approval = await owner.sendRequestToServer(
        'enroll:approve:{"enrollmentId":"$enrollmentId","encryptedDefaultEncryptionPrivateKey":"$encryptedPrivateKey","encryptedDefaultSelfEncryptionKey":"$encryptedSelfKey"}');
    expect(jsonDecode(approval.replaceFirst('data:', ''))['status'], 'approved');
    return enrollmentId;
  }

  /// The proof-of-possession a rotation must carry: a signature by the NEW
  /// private key over `<enrollmentId>|<apkamPublicKey>|<signingAlgo>`.
  ///
  /// `AtSigningMode.pkam` rather than `data` — `data` signs with the
  /// encryption keypair, so it cannot express possession of a signing key.
  String popSignature(AtPkamKeyPair pair, String enId, String algo) {
    final input = AtSigningInput('$enId|${pair.atPublicKey.publicKey}|$algo')
      ..signingAlgoType = SigningAlgoType.rsa2048
      ..hashingAlgoType = HashingAlgoType.sha256
      ..signingMode = AtSigningMode.pkam;
    return AtChopsImpl(AtChopsKeys.create(null, pair)).sign(input).result;
  }

  /// Whether [privateKey] can PKAM-authenticate as [enrollmentId] right now.
  ///
  /// Its own fresh connection each time, because a failed authentication is
  /// not something a connection is expected to survive.
  Future<bool> canAuthenticate(String enrollmentId, String privateKey) async {
    OutboundConnectionFactory c = await newConnection();
    String fromResponse =
        await c.sendRequestToServer('from:$atSign:clientConfig:{}');
    String challenge =
        fromResponse.replaceAll('data:', '').replaceAll('@$atSign@', '').trim();
    String signature =
        AuthenticationUtils.generatePKAMDigest(privateKey, challenge);
    try {
      String r = await c
          .sendRequestToServer('pkam:enrollmentId:$enrollmentId:$signature');
      return r.trim() == 'data:success';
    } on Exception {
      return false;
    }
  }

  tearDown(() async {
    for (final c in open) {
      c.close();
    }
    open.clear();
  });

  group('enroll:update', () {
    test('a rotation moves authentication to the new key and off the old one',
        () async {
      final owner = await ownerConnection();
      final enId =
          await createApprovedEnrollment(owner, namespaces: {'buzz': 'rw'});

      expect(await canAuthenticate(enId, apkamPrivateKey), true,
          reason: 'the enrollment must authenticate before the rotation, or '
              'the after-check proves nothing');

      final newPair = AtChopsUtil.generateAtPkamKeyPair();
      final newPub = newPair.atPublicKey.publicKey;

      final self = await newConnection();
      expect(
          (await self.authenticateConnection(
                  authType: AuthType.apkam, enrollmentId: enId))
              .trim(),
          'data:success');

      final response = await self.sendRequestToServer(
          'enroll:update:{"enrollmentId":"$enId","apkamPublicKey":"$newPub",'
          '"signingAlgo":"rsa2048","apkamPublicKeySignature":'
          '"${popSignature(newPair, enId, 'rsa2048')}"}');
      expect(jsonDecode(response.replaceFirst('data:', ''))['status'],
          'approved');

      // The point of the whole operation, and the part no unit test reaches.
      expect(
          await canAuthenticate(enId, newPair.atPrivateKey.privateKey), true,
          reason: 'the rotated-in key must authenticate as the SAME '
              'enrollment id');
      expect(await canAuthenticate(enId, apkamPrivateKey), false,
          reason: 'the rotated-out key must stop authenticating');
    });

    test('a rotation with an invalid proof is refused and changes nothing',
        () async {
      final owner = await ownerConnection();
      final enId =
          await createApprovedEnrollment(owner, namespaces: {'buzz': 'rw'});

      final newPair = AtChopsUtil.generateAtPkamKeyPair();
      final wrongPair = AtChopsUtil.generateAtPkamKeyPair();

      final self = await newConnection();
      expect(
          (await self.authenticateConnection(
                  authType: AuthType.apkam, enrollmentId: enId))
              .trim(),
          'data:success');

      // Signed by a key OTHER than the one being installed.
      final response = await self.sendRequestToServer(
          'enroll:update:{"enrollmentId":"$enId",'
          '"apkamPublicKey":"${newPair.atPublicKey.publicKey}",'
          '"signingAlgo":"rsa2048","apkamPublicKeySignature":'
          '"${popSignature(wrongPair, enId, 'rsa2048')}"}');
      expect(response.trim(), startsWith('error:'),
          reason: 'a proof that does not verify against the key being '
              'installed must be refused');

      // The differential half: the refusal left the record alone.
      expect(await canAuthenticate(enId, apkamPrivateKey), true,
          reason: 'the original key must still authenticate after a refused '
              'rotation');
      expect(
          await canAuthenticate(enId, newPair.atPrivateKey.privateKey), false,
          reason: 'the refused key must not have been installed');
    });

    test('one enrollment cannot update another', () async {
      final owner = await ownerConnection();
      final target =
          await createApprovedEnrollment(owner, namespaces: {'buzz': 'rw'});
      final other =
          await createApprovedEnrollment(owner, namespaces: {'buzz': 'rw'});

      final c = await newConnection();
      expect(
          (await c.authenticateConnection(
                  authType: AuthType.apkam, enrollmentId: other))
              .trim(),
          'data:success');

      final response = await c.sendRequestToServer(
          'enroll:update:{"enrollmentId":"$target","metadata":{"x":"y"}}');
      expect(response.trim(), startsWith('error:'),
          reason: 'enroll:update is self-only');
    });

    test('an update carrying apsk republishes the record', () async {
      final owner = await ownerConnection();
      final enId =
          await createApprovedEnrollment(owner, namespaces: {'buzz': 'rw'});

      final apsk = {
        'v': 1,
        'keys': [
          {
            'use': 'sign',
            'alg': 'mldsa65',
            'pub': 'ZnVuY3Rpb25hbC10ZXN0LWtleQ==',
            'status': 'active'
          }
        ]
      };

      final self = await newConnection();
      expect(
          (await self.authenticateConnection(
                  authType: AuthType.apkam, enrollmentId: enId))
              .trim(),
          'data:success');
      final response = await self.sendRequestToServer(
          'enroll:update:{"enrollmentId":"$enId","apsk":${jsonEncode(apsk)}}');
      expect(jsonDecode(response.replaceFirst('data:', ''))['status'],
          'approved');

      // Read it back the way a verifier does, not out of the enrollment
      // record: the published key is what every signature check resolves.
      final published =
          await owner.sendRequestToServer('llookup:public:_apsk.$enId.a.__e$atSign');
      expect(jsonDecode(published.replaceFirst('data:', '').trim()), apsk);
    });
  });
}
