import 'dart:convert';

import 'package:at_chops/at_chops.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';

import 'enrollment_test_utils.dart';
import 'test_utils.dart';

/// A key installed by any request must not be held by any stored enrollment.
///
/// One keypair under two enrollment names is two identities with separate
/// lifecycles: revoking one leaves the same key authenticating as the other.
/// So every request that installs key material — the OTP request, the CRAM
/// auto-approve, the retrofit, and an `enroll:update` that replaces
/// `apkamPublicKey` — is refused, with nothing persisted, when a stored
/// enrollment in ANY status already holds that key. The one exception is a
/// record re-sending its own current key, which is not a collision with
/// itself.
void main() {
  verbTestsSetUpLogging();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  final etu = ETU();

  /// The key the fixture's CRAM-minted root holds.
  late String rootKey;

  setUp(() async {
    await verbTestsSetUp();
    await etu.init();
    rootKey = (await enMgr.getEnrollmentById(etu.primaryEnId)).apkamPublicKey;
  });

  tearDown(() async {
    AtSecondaryConfig.testingModeOverride = null;
    await verbTestsTearDown();
  });

  /// What the refusal says, whichever path it is refused on.
  const String refusalText =
      'The apkamPublicKey is already held by another enrollment on this '
      'atSign; every enrollment needs a keypair of its own';

  /// Runs [command] through the enroll verb handler on [inboundConnection]
  /// as it stands, and reports a refusal the handler THROWS as an error
  /// response — the shape the server's own dispatch gives it — so every
  /// assertion below reads one thing.
  Future<Response> send(String command) async {
    final r = Response();
    try {
      await etu.evh.processVerb(
          r, getVerbParam(VerbSyntax.enroll, command), inboundConnection);
    } on AtException catch (e) {
      r.isError = true;
      r.errorMessage = '${e.runtimeType}: ${e.message}';
    }
    return r;
  }

  /// An `enroll:request` over an unauthenticated connection with a fresh OTP,
  /// returning the raw response.
  Future<Response> requestOverOtp(
      {required String appName,
      required String deviceName,
      required String apkamPublicKey,
      String? signingAlgo}) async {
    final EnrollParams ep = EnrollParams()
      ..appName = appName
      ..deviceName = deviceName
      ..apkamPublicKey = apkamPublicKey
      ..signingAlgo = signingAlgo
      ..encryptedAPKAMSymmetricKey = 'wrapped-$appName-$deviceName'
      ..namespaces = {'wavi': 'rw'}
      ..otp = await etu.getOtp();
    inboundConnection.metaData
      ..isAuthenticated = false
      ..authType = null
      ..sessionID = DateTime.now().millisecondsSinceEpoch.toString();
    return send('enroll:request:${jsonEncode(ep.toJson())}');
  }

  /// An `enroll:request` over a CRAM connection: the auto-approve path.
  Future<Response> requestOverCram(
      {required String appName,
      required String deviceName,
      required String apkamPublicKey}) async {
    final EnrollParams ep = EnrollParams()
      ..appName = appName
      ..deviceName = deviceName
      ..apkamPublicKey = apkamPublicKey
      ..namespaces = {'wavi': 'rw'};
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.cram
      ..sessionID = DateTime.now().millisecondsSinceEpoch.toString();
    inboundConnection.metadata.enrollmentId = null;
    return send('enroll:request:${jsonEncode(ep.toJson())}');
  }

  /// An `enroll:request` over a connection carrying [predecessorId]: the
  /// retrofit path.
  Future<Response> retrofit(String predecessorId,
      {required String apkamPublicKey, String appName = 'successor'}) async {
    final EnrollParams ep = EnrollParams()
      ..appName = appName
      ..deviceName = 'device'
      ..apkamPublicKey = apkamPublicKey;
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.apkam
      ..sessionID = DateTime.now().millisecondsSinceEpoch.toString();
    inboundConnection.metadata.enrollmentId = predecessorId;
    return send('enroll:request:${jsonEncode(ep.toJson())}');
  }

  /// An `enroll:update` from [enId] itself, replacing its key with [pair]'s
  /// public half under a valid proof of possession.
  Future<Response> rotate(String enId, AtPkamKeyPair pair) async {
    final String publicKey = pair.atPublicKey.publicKey;
    final input = AtSigningInput('$enId|$publicKey|rsa2048')
      ..signingAlgoType = SigningAlgoType.rsa2048
      ..hashingAlgoType = HashingAlgoType.sha256
      ..signingMode = AtSigningMode.pkam;
    final String proof =
        AtChopsImpl(AtChopsKeys.create(null, pair)).sign(input).result;
    final EnrollParams ep = EnrollParams()
      ..enrollmentId = enId
      ..apkamPublicKey = publicKey
      ..signingAlgo = 'rsa2048'
      ..apkamPublicKeySignature = proof;
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.apkam;
    inboundConnection.metadata.enrollmentId = enId;
    return send('enroll:update:${jsonEncode(ep.toJson())}');
  }

  Future<int> storedCount() async =>
      (await enMgr.getAllEnrollmentKeys(includeExpired: true)).length;

  Future<String> storedKeyOf(String id) async =>
      (await enMgr.getEnrollmentById(id)).apkamPublicKey;

  /// Asserts [r] is the uniqueness refusal.
  void expectRefused(Response r) {
    expect(r.isError, isTrue, reason: 'expected a refusal, got ${r.data}');
    expect(r.errorMessage, startsWith('IllegalStateException:'),
        reason: 'the same refusal class as the (appName, deviceName) rule, '
            'which the wire reports as AT0032');
    expect(r.errorMessage, contains(refusalText));
  }

  group('every request path is refused when a stored enrollment holds the key',
      () {
    test('the OTP request', () async {
      final int roster = await storedCount();
      final int writes = EnrollmentManager.cacheInvalidations;

      final r = await requestOverOtp(
          appName: 'otp-app', deviceName: 'device', apkamPublicKey: rootKey);

      expectRefused(r);
      expect(await storedCount(), roster,
          reason: 'nothing persisted: no pending record was written');
      expect(EnrollmentManager.cacheInvalidations, writes,
          reason: 'and no enrollment write happened at all');
    });

    test('the CRAM auto-approve', () async {
      final int roster = await storedCount();
      final int writes = EnrollmentManager.cacheInvalidations;

      final r = await requestOverCram(
          appName: 'cram-app', deviceName: 'device', apkamPublicKey: rootKey);

      expectRefused(r);
      expect(await storedCount(), roster);
      expect(EnrollmentManager.cacheInvalidations, writes);
    });

    test('the retrofit, re-sending its predecessor\'s key', () async {
      // A retrofit is a re-key: the successor is the same principal under a
      // NEW keypair. One that carries its predecessor's key would leave one
      // keypair under two names.
      final String predecessorId = await etu.createPendingEnrollment(
          appName: 'device-app',
          deviceName: 'device',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null);
      await etu.approveEnrollment(etu.primaryEnId, predecessorId);
      final String predecessorKey = await storedKeyOf(predecessorId);
      final int roster = await storedCount();
      final int writes = EnrollmentManager.cacheInvalidations;

      final r = await retrofit(predecessorId, apkamPublicKey: predecessorKey);

      expectRefused(r);
      expect(await storedCount(), roster);
      expect(EnrollmentManager.cacheInvalidations, writes);

      // The control: the same retrofit with a key nobody holds is admitted.
      final ok = await retrofit(predecessorId,
          apkamPublicKey: 'a fresh key for the successor');
      expect(ok.isError, isFalse, reason: ok.errorMessage);
    });

    test('enroll:update rotating onto a key another enrollment holds',
        () async {
      final AtPkamKeyPair pair = AtChopsUtil.generateAtPkamKeyPair();
      final String holderId = await etu.createPendingEnrollment(
          appName: 'holder',
          deviceName: 'device',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null,
          apkamPublicKey: pair.atPublicKey.publicKey);
      await etu.approveEnrollment(etu.primaryEnId, holderId);
      final String rotatingId = await etu.createPendingEnrollment(
          appName: 'rotating',
          deviceName: 'device',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null);
      await etu.approveEnrollment(etu.primaryEnId, rotatingId);
      final String before = await storedKeyOf(rotatingId);
      final int writes = EnrollmentManager.cacheInvalidations;

      final r = await rotate(rotatingId, pair);

      expect(r.isError, isTrue, reason: 'got ${r.data}');
      expect(r.errorMessage, contains(refusalText));
      expect(await storedKeyOf(rotatingId), before,
          reason: 'the refused key was not installed');
      expect(EnrollmentManager.cacheInvalidations, writes);
    });

    test('enroll:update re-sending the record\'s own key is not a collision',
        () async {
      final AtPkamKeyPair pair = AtChopsUtil.generateAtPkamKeyPair();
      final String id = await etu.createPendingEnrollment(
          appName: 'self',
          deviceName: 'device',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null,
          apkamPublicKey: pair.atPublicKey.publicKey,
          signingAlgo: 'rsa2048');
      await etu.approveEnrollment(etu.primaryEnId, id);

      final r = await rotate(id, pair);

      expect(r.isError, isFalse, reason: r.errorMessage);
      expect(await storedKeyOf(id), pair.atPublicKey.publicKey);
    });
  });

  group('every stored status holds the key', () {
    Future<String> holderIn(EnrollmentStatus status, String key) async {
      final String id = await etu.createPendingEnrollment(
          appName: 'holder-${status.name}',
          deviceName: 'device',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null,
          apkamPublicKey: key);
      switch (status) {
        case EnrollmentStatus.pending:
          break;
        case EnrollmentStatus.approved:
          await etu.approveEnrollment(etu.primaryEnId, id);
        case EnrollmentStatus.denied:
          await etu.denyEnrollment(etu.primaryEnId, id);
        case EnrollmentStatus.revoked:
          await etu.approveEnrollment(etu.primaryEnId, id);
          await etu.revokeEnrollment(etu.primaryEnId, id);
        case EnrollmentStatus.expired:
          fail('made by elapsing a ttl, below');
      }
      return id;
    }

    for (final status in [
      EnrollmentStatus.pending,
      EnrollmentStatus.approved,
      EnrollmentStatus.denied,
      EnrollmentStatus.revoked,
    ]) {
      test('a ${status.name} holder blocks', () async {
        final String key = 'key held while ${status.name}';
        await holderIn(status, key);

        final r = await requestOverOtp(
            appName: 'newcomer', deviceName: 'device', apkamPublicKey: key);

        expect(r.isError, isTrue,
            reason: 'a ${status.name} holder still holds the key: got '
                '${r.data}');
        expect(r.errorMessage, contains(refusalText));
      });
    }

    test('an expired holder the sweep has not yet removed blocks', () async {
      const String key = 'key held while expired';
      final String id = await holderIn(EnrollmentStatus.approved, key);
      // Elapse the ttl without removing the record: the state between a ttl
      // elapsing and the sweep reaping it.
      final String ek = enMgr.buildEnrollmentKey(id);
      final AtData record = (await keyValueStore.get(ek))!;
      await enMgr.put(id, record, EnrollmentStatus.approved,
          assertedTimestamps: AtAssertedTimestamps(
              expiresAt: DateTime.now().toUtc().subtract(Duration(minutes: 1)),
              deriveTtl: true));
      expect((await enMgr.getEnrollmentById(id)).approval?.state,
          EnrollmentStatus.expired.name,
          reason: 'precondition: reported expired, and still on disk');

      final r = await requestOverOtp(
          appName: 'newcomer', deviceName: 'device', apkamPublicKey: key);

      expect(r.isError, isTrue, reason: 'got ${r.data}');
      expect(r.errorMessage, contains(refusalText));
    });

    test('a deleted holder no longer blocks', () async {
      // The control for the four above: the rule is about what the store
      // HOLDS, and deletion is the remedy it points at.
      const String key = 'key held until deleted';
      final String id = await holderIn(EnrollmentStatus.denied, key);
      await etu.deleteEnrollment(etu.primaryEnId, id);

      final r = await requestOverOtp(
          appName: 'newcomer', deviceName: 'device', apkamPublicKey: key);

      expect(r.isError, isFalse, reason: r.errorMessage);
    });
  });

  group('the comparison is on key material, not on spelling', () {
    test('an ECC key re-cased collides', () async {
      const String lower = 'deadbeef00112233';
      const String upper = 'DEADBEEF00112233';
      final String holderId = await etu.createPendingEnrollment(
          appName: 'ecc-holder',
          deviceName: 'device',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null,
          apkamPublicKey: lower,
          signingAlgo: 'ecc_secp256r1');
      await etu.approveEnrollment(etu.primaryEnId, holderId);

      final r = await requestOverOtp(
          appName: 'ecc-newcomer',
          deviceName: 'device',
          apkamPublicKey: upper,
          signingAlgo: 'ecc_secp256r1');

      expect(r.isError, isTrue,
          reason: 'hex decodes case-insensitively, so this is the same key: '
              'got ${r.data}');
      expect(r.errorMessage, contains(refusalText));
    });

    test('a base64 key with surrounding whitespace collides', () async {
      final String key = AtChopsUtil.generateAtPkamKeyPair().atPublicKey.publicKey;
      final String holderId = await etu.createPendingEnrollment(
          appName: 'b64-holder',
          deviceName: 'device',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null,
          apkamPublicKey: key);
      await etu.approveEnrollment(etu.primaryEnId, holderId);

      final r = await requestOverOtp(
          appName: 'b64-newcomer', deviceName: 'device', apkamPublicKey: ' $key ');

      expect(r.isError, isTrue, reason: 'got ${r.data}');
      expect(r.errorMessage, contains(refusalText));
    });

    test('two different keys do not collide', () async {
      // The control for the group: the comparison can say no.
      final String a = AtChopsUtil.generateAtPkamKeyPair().atPublicKey.publicKey;
      final String b = AtChopsUtil.generateAtPkamKeyPair().atPublicKey.publicKey;
      final String holderId = await etu.createPendingEnrollment(
          appName: 'a-holder',
          deviceName: 'device',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null,
          apkamPublicKey: a);
      await etu.approveEnrollment(etu.primaryEnId, holderId);

      final r = await requestOverOtp(
          appName: 'b-newcomer', deviceName: 'device', apkamPublicKey: b);

      expect(r.isError, isFalse, reason: r.errorMessage);
    });
  });

  group('the order and the wording of the refusal', () {
    test('the (appName, deviceName) rule fires first', () async {
      final String holderId = await etu.createPendingEnrollment(
          appName: 'same-app',
          deviceName: 'same-device',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null,
          apkamPublicKey: 'the same key too');
      await etu.approveEnrollment(etu.primaryEnId, holderId);

      final r = await requestOverOtp(
          appName: 'same-app',
          deviceName: 'same-device',
          apkamPublicKey: 'the same key too');

      expect(r.isError, isTrue);
      expect(r.errorMessage, contains('Another enrollment with id $holderId'),
          reason: 'a request breaking both rules is told about the one it '
              'can fix by renaming');
      expect(r.errorMessage, isNot(contains(refusalText)));
    });

    test('an unauthenticated refusal does not name the holder', () async {
      AtSecondaryConfig.testingModeOverride = false;

      final r = await requestOverOtp(
          appName: 'anon', deviceName: 'device', apkamPublicKey: rootKey);

      expect(r.isError, isTrue);
      expect(r.errorMessage, isNot(contains(etu.primaryEnId)),
          reason: 'the roster is not an unauthenticated requester\'s to '
              'read, one refusal at a time');
      expect(r.errorMessage, isNot(contains('held by enrollment')));
    });

    test('under testingMode the refusal names the holder, as a diagnostic',
        () async {
      AtSecondaryConfig.testingModeOverride = true;

      final r = await requestOverOtp(
          appName: 'diag', deviceName: 'device', apkamPublicKey: rootKey);

      expect(r.isError, isTrue,
          reason: 'no exemption from the rule under testingMode: got '
              '${r.data}');
      expect(r.errorMessage,
          contains('held by enrollment ${etu.primaryEnId}, approved'));
    });
  });

  group('the roster walk', () {
    test('holderOfApkamPublicKey excludes the enrollment named', () async {
      expect(
          await enMgr.holderOfApkamPublicKey(rootKey, null,
              excluding: etu.primaryEnId),
          isNull);
      expect((await enMgr.holderOfApkamPublicKey(rootKey, null))?.$1,
          etu.primaryEnId);
    });

    test('a record that does not decode is skipped, and the rest are read',
        () async {
      await keyValueStore.put(
          enMgr.buildEnrollmentKey('corrupt'), AtData()..data = 'not json');

      final List<(String, EnrollDataStoreValue)> stored =
          await enMgr.storedEnrollments();

      expect(stored.map((e) => e.$1), contains(etu.primaryEnId));
      expect(stored.map((e) => e.$1), isNot(contains('corrupt')));
    });
  });
}
