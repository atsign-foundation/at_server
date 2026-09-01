import 'dart:convert';

import 'dart:typed_data';

import 'package:at_chops/at_chops.dart' show MlDsa65PureDartAlgo;
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/pkam_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:test/test.dart';

import 'enrollment_test_utils.dart';
import 'test_utils.dart';

/// The atSign's oldest credential — the legacy keyfile, which authenticates
/// with no enrollment id at all — gets an enrollment record of its own.
///
/// Without one it is the single credential on the atSign whose grants are
/// assumed rather than stated, which no roster shows, which no verb can
/// revoke, and which nothing ever retires. The housekeeping enrollment is what
/// a legacy connection authenticates AS, so that credential acquires the
/// lifecycle every other credential already has.
void main() {
  verbTestsSetUpLogging();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  final etu = ETU();

  /// The atSign's legacy PKAM public key. Its presence is what distinguishes
  /// "the housekeeping record never existed" from "it was retired", so every
  /// test that expects creation needs it there.
  Future<void> seedLegacyKey(
      [String value = 'the-legacy-pkam-key']) async {
    await keyValueStore.put(
        AtConstants.atPkamPublicKey, AtData()..data = value,
        skipCommit: true);
  }

  setUp(() async {
    await verbTestsSetUp();
    await etu.init();
    await seedLegacyKey();
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  /// A genuine legacy PKAM authentication, end to end through the verb
  /// handler: no enrollment id on the wire, and the signature verified
  /// against `at_pkam_publickey`. The legacy path takes the signing algorithm
  /// from the wire — it has no record to be authoritative about — so ML-DSA
  /// serves as well as RSA and needs no fixture keys.
  ///
  /// Returns the handler's [Response]; the caller decides whether success or
  /// refusal is what it expects.
  Future<Response> authenticateLegacy({String sessionId = 'legacy-session'}) async {
    final mlDsa = await MlDsa65PureDartAlgo().generateKeyPair();
    await seedLegacyKey(base64Encode(mlDsa.publicKey));

    const challenge = 'a-per-connection-challenge';
    await keyValueStore.put(
        'private:$sessionId$alice', AtData()..data = challenge);
    final signature = await MlDsa65PureDartAlgo().signBytes(
        Uint8List.fromList(utf8.encode('$sessionId$alice:$challenge')),
        secretKey: mlDsa.secretKey);

    inboundConnection.metaData
      ..isAuthenticated = false
      ..enrollmentId = null
      ..sessionID = sessionId;

    final r = Response();
    await PkamVerbHandler(keyValueStore).processVerb(
      r,
      getVerbParam(VerbSyntax.pkam,
          'pkam:signingAlgo:mldsa65:${base64Encode(signature)}'),
      inboundConnection,
    );
    return r;
  }

  String hKey() =>
      enMgr.buildEnrollmentKey(EnrollmentManager.housekeepingEnrollmentId);

  /// `keyStore.get` THROWS for a missing key rather than returning null, so
  /// absence has to be caught rather than tested for.
  Future<EnrollDataStoreValue?> storedH() async {
    final AtData? r;
    try {
      r = await keyValueStore.get(hKey());
    } on KeyNotFoundException {
      return null;
    }
    if (r?.data == null) return null;
    return EnrollDataStoreValue.fromJson(jsonDecode(r!.data!));
  }

  Future<void> setHStatus(EnrollmentStatus status) async {
    final h = (await storedH())!..approval = EnrollApproval(status.name);
    await enMgr.put(EnrollmentManager.housekeepingEnrollmentId,
        AtData()..data = jsonEncode(h.toJson()), status);
  }

  group('the housekeeping enrollment', () {
    test('its id is the literal `primary`', () {
      expect(EnrollmentManager.housekeepingEnrollmentId, 'primary',
          reason: 'AT-REST AND CROSS-REPO, so this is a raw-literal pin. '
              'at_client already publishes a legacy client\'s signing key at '
              '`public:_apsk.primary.a.__e@<atSign>`, and that key becomes '
              'this enrollment\'s per-enrollment data only because the two '
              'ids match exactly. Changing this string strands it.');
    });

    test('is created on demand, approved and fully privileged', () async {
      expect(await storedH(), isNull, reason: 'precondition: no record yet');

      await enMgr.ensureHousekeepingEnrollment();

      final h = await storedH();
      expect(h, isNotNull);
      expect(h!.approval?.state, EnrollmentStatus.approved.name);
      expect(h.namespaces, {
        EnrollmentConstants.allNamespaces: 'rw',
        EnrollmentConstants.enrollManageNamespace: 'rw',
      }, reason: 'it stands for the credential the atSign was onboarded with, '
          'which has always had unrestricted access — stating that is the '
          'point of the record');
      expect(h.isRootEnrollment, isTrue,
          reason: 'so the stranding refusals count it like any other root');
      expect(h.apkamPublicKey, 'the-legacy-pkam-key',
          reason: 'the record describes the credential it stands for rather '
              'than being a bare marker');
    });

    test('carries NO approver, so no cascade can reach it', () async {
      await enMgr.ensureHousekeepingEnrollment();
      final admitted = await etu.createPendingEnrollment(
          appName: 'admitted',
          deviceName: 'device',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null);
      await etu.approveEnrollment(etu.primaryEnId, admitted);

      expect((await storedH())!.approvedByEnrollmentId, isNull,
          reason: 'nothing admitted it — the server created it for itself');

      final reachable = await enMgr.descendantsOf(etu.primaryEnId);
      expect(reachable, contains(admitted),
          reason: 'positive control: the cascade does reach what the primary '
              'admitted, so an absence below is about the approver and not '
              'about a walk that finds nothing');
      expect(
          reachable,
          isNot(contains(EnrollmentManager.housekeepingEnrollmentId)),
          reason: 'a cascade able to sweep it away would strand the very '
              'credential it exists to govern');
    });

    test('does not expire of its own accord', () async {
      await enMgr.ensureHousekeepingEnrollment();
      expect((await keyValueStore.get(hKey()))?.metaData?.expiresAt, isNull,
          reason: 'only the retrofit cap may ever put a clock on it');
    });

    test('a second authentication reads it rather than rewriting it', () async {
      await enMgr.ensureHousekeepingEnrollment();
      final int writesBefore = EnrollmentManager.cacheInvalidations;
      final String sessionBefore = (await storedH())!.sessionId;

      await enMgr.ensureHousekeepingEnrollment();

      expect(EnrollmentManager.cacheInvalidations, writesBefore,
          reason: 'every enrollment write bumps this counter, and this runs '
              'on EVERY legacy authentication — the already-created case has '
              'to cost one read and no write');
      expect((await storedH())!.sessionId, sessionBefore,
          reason: 'and it is the same record, not a freshly minted one');
    });

    test('a REVOKED one is not restored by authenticating again', () async {
      await enMgr.ensureHousekeepingEnrollment();
      await setHStatus(EnrollmentStatus.revoked);

      final returned = await enMgr.ensureHousekeepingEnrollment();

      expect(returned!.approval?.state, EnrollmentStatus.revoked.name);
      expect((await storedH())!.approval?.state,
          EnrollmentStatus.revoked.name,
          reason: 'otherwise legacy authentication is a way to undo its own '
              'revocation, and the record could never be retired at all');
    });

    test('a REVOKED one stops counting as the atSign\'s surviving root',
        () async {
      await enMgr.ensureHousekeepingEnrollment();

      expect(await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isTrue,
          reason: 'precondition: it is an approved, permanent root, so it '
              'answers the stranding question while it stands');

      await setHStatus(EnrollmentStatus.revoked);

      expect(await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isFalse,
          reason: 'it is permanent but it is REVOKABLE, so it must stop '
              'counting the moment it is revoked — counting it would report '
              'the atSign safe at exactly the moment its last usable root '
              'was taken away');
    });

    test('it is NOT re-created once the legacy key has gone', () async {
      // Absence says nothing on its own, and this is the distinction the
      // whole retirement path rests on. Removing the record always takes
      // `at_pkam_publickey` with it, so the key being gone means the
      // credential was RETIRED — and re-creating the record here would hand
      // the retired keyfile a fresh, unexpiring enrollment, every time it
      // expired, so the retirement would never complete.
      await keyValueStore.remove(AtConstants.atPkamPublicKey, skipCommit: true);

      expect(await enMgr.ensureHousekeepingEnrollment(), isNull);
      expect(await storedH(), isNull,
          reason: 'and nothing was written — a null return that still created '
              'the record would retire nothing');
    });

    test('...while the same absence WITH the key present is a bootstrap',
        () async {
      // The control, and it is what stops the guard above being satisfied by
      // "creation never happens". Identical state but for the legacy key.
      expect(await storedH(), isNull, reason: 'precondition: no record');
      expect(await enMgr.ensureHousekeepingEnrollment(), isNotNull);
      expect(await storedH(), isNotNull);
    });

    test('legacy authentication creates it and CONNECTS as it', () async {
      // The call site, not just the mechanism: a real signature, through the
      // verb handler, with no enrollment id on the wire.
      final r = await authenticateLegacy();

      expect(r.data, 'success', reason: '${r.errorMessage}');
      expect(await storedH(), isNotNull,
          reason: 'the authentication is what creates it');
      expect(inboundConnection.metaData.authType, AuthType.pkamLegacy);
      expect(inboundConnection.metaData.enrollmentId,
          EnrollmentManager.housekeepingEnrollmentId,
          reason: 'the connection carries it, so every authorisation check '
              'downstream sees a real enrollment instead of a null that used '
              'to mean unrestricted access');
    });

    test('legacy authentication is REFUSED once it is revoked', () async {
      expect((await authenticateLegacy()).data, 'success',
          reason: 'precondition: it authenticates while approved');

      await setHStatus(EnrollmentStatus.revoked);

      await expectLater(
          () => authenticateLegacy(sessionId: 'second-session'),
          throwsA(isA<UnAuthenticatedException>()),
          reason: 'revoking this record is what makes revoking the legacy '
              'keyfile possible at all — before it there was no verb that '
              'could. A valid signature is not enough if the credential it '
              'proves has been withdrawn');
    });

    test('the signing key a legacy client already published becomes its '
        'per-enrollment data', () async {
      // The whole reason the id is `primary` rather than something coined.
      // at_client publishes a legacy client's signing key at this address
      // today and nothing has ever retired it, because there was no
      // enrollment for it to belong to.
      final String approvedKey = 'public:_apsk.'
          '${EnrollmentManager.housekeepingEnrollmentId}'
          '.${EnrollmentConstants.perEnrollmentApproved}$alice';
      final String revokedKey = 'public:_apsk.'
          '${EnrollmentManager.housekeepingEnrollmentId}'
          '.${EnrollmentConstants.perEnrollmentRevoked}$alice';
      await keyValueStore.put(
          approvedKey, AtData()..data = 'the legacy signing key',
          skipCommit: true);

      await enMgr.ensureHousekeepingEnrollment();
      expect(await keyValueStore.exists(approvedKey), isTrue,
          reason: 'precondition: creation approves it, so the key stays at '
              'the live address');

      await setHStatus(EnrollmentStatus.revoked);

      expect(await keyValueStore.exists(revokedKey), isTrue,
          reason: 'revoking the legacy credential must PARK its signing key, '
              'exactly as revoking any other enrollment does');
      expect(await keyValueStore.exists(approvedKey), isFalse,
          reason: 'and it must no longer resolve at the address a verifier '
              'reads');
    });
  });

  group('APKAM authentication', () {
    test('may not name the housekeeping enrollment', () async {
      final result = await PkamVerbHandler(keyValueStore)
          .verifyEnrollmentIsActive(
              EnrollmentManager.housekeepingEnrollmentId, alice);

      expect(result.response.isError, isTrue,
          reason: 'a credential reachable both with and without an enrollment '
              'id would have two lifecycles: naming it would bypass the '
              'legacy gates, and its retirement could be sidestepped by the '
              'very keyfile it retires');
      expect(result.response.errorCode, 'AT0009');
      expect(result.response.errorMessage, contains('legacy PKAM'));
    });

    test('...but an ordinary enrollment id is unaffected', () async {
      // The control. Without it the refusal above would be satisfied by
      // "verifyEnrollmentIsActive refuses everything".
      final ordinary = (await etu.createEnrollments(n: 1)).$1.first;
      final result =
          await PkamVerbHandler(keyValueStore).verifyEnrollmentIsActive(
              ordinary, alice);
      expect(result.response.isError, isFalse,
          reason: '${result.response.errorMessage}');
    });
  });
}
