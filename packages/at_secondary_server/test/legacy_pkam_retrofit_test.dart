import 'dart:convert';

import 'dart:typed_data';

import 'package:at_chops/at_chops.dart'
    show
        AtChopsImpl,
        AtChopsKeys,
        AtChopsUtil,
        AtPkamKeyPair,
        AtSigningInput,
        AtSigningMode,
        HashingAlgoType,
        MlDsa65PureDartAlgo,
        SigningAlgoType;
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
      expect(h.apkamPublicKey, isEmpty,
          reason: 'BEHAVIOUR CHANGED — it used to snapshot the legacy key '
              'here. The record is an IDENTITY for the legacy credential, '
              'never a second copy of it: legacy PKAM verifies against the '
              'live at_pkam_publickey and reads nothing off this record, so a '
              'copy here is read by nothing and can only drift from the key '
              'that actually authenticates');
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
          throwsA(isA<UnAuthenticatedException>().having((e) => e.message,
              'message', contains('the legacy credential for this atSign is '
                  'revoked'))),
          reason: 'revoking this record is what makes revoking the legacy '
              'keyfile possible at all — before it there was no verb that '
              'could. A valid signature is not enough if the credential it '
              'proves has been withdrawn, and the refusal NAMES that rather '
              'than reporting a bad signature');

      expect(inboundConnection.metaData.isAuthenticated, isFalse,
          reason: 'the ORDERING, which is the whole reason the housekeeping '
              'enrollment is resolved before isAuthenticated is set: a '
              'refusal here must leave the connection unauthenticated, not '
              'authenticate it and then throw');
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

  group('removing it retires the legacy credential', () {
    test('the legacy PKAM public key goes with the record', () async {
      await enMgr.ensureHousekeepingEnrollment();
      expect(await keyValueStore.exists(AtConstants.atPkamPublicKey), isTrue,
          reason: 'precondition');

      await enMgr.remove(enId: EnrollmentManager.housekeepingEnrollmentId);

      expect(await keyValueStore.exists(AtConstants.atPkamPublicKey), isFalse,
          reason: 'the key is what legacy authentication verifies against, so '
              'removing it IS removing the credential — and it cannot be '
              'deleted over the wire, because the delete verb refuses '
              '`privatekey:` keys on grammar. This hook is the only path');
    });

    test('...and removing any OTHER enrollment leaves it alone', () async {
      // The control. Without it the test above would be satisfied by a hook
      // that deletes the legacy key whenever anything is removed, which would
      // let any enrollment\'s deletion lock the atSign\'s owner out.
      await enMgr.ensureHousekeepingEnrollment();
      final other = await etu.createPendingEnrollment(
          appName: 'other',
          deviceName: 'device',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null);

      await enMgr.remove(enId: other);

      expect(await keyValueStore.exists(AtConstants.atPkamPublicKey), isTrue);
    });

    test('legacy authentication is refused afterwards', () async {
      // The consequence, end to end: retirement is not a bookkeeping state,
      // it is the credential ceasing to work.
      expect((await authenticateLegacy()).data, 'success',
          reason: 'precondition: it authenticates before retirement');

      await enMgr.remove(enId: EnrollmentManager.housekeepingEnrollmentId);

      // authenticateLegacy re-seeds the key, which is what a fresh client
      // could never do, so drive the handler against the retired state
      // directly.
      inboundConnection.metaData
        ..isAuthenticated = false
        ..enrollmentId = null
        ..sessionID = 'after-retirement';
      // ⚠️ The MESSAGE, not just the type. The signature below is deliberate
      // garbage, so an `UnAuthenticatedException` alone is also what an
      // ordinary signature failure produces — a different mechanism, and one
      // that would keep this green if retirement stopped removing the key.
      // Refusal has to happen because the credential is GONE, which is a
      // decision taken before any signature is looked at.
      await expectLater(
          PkamVerbHandler(keyValueStore).processVerb(
            Response(),
            getVerbParam(VerbSyntax.pkam, 'pkam:signingAlgo:mldsa65:c2ln'),
            inboundConnection,
          ),
          throwsA(isA<UnAuthenticatedException>().having((e) => e.message,
              'message', contains('no legacy PKAM credential'))),
          reason: 'with the key gone there is nothing to verify against, and '
              'the refusal says so rather than reporting a bad signature');
    });
  });

  group('a legacy enroll:request is a retrofit of it', () {
    /// `enroll:request` over a connection whose authType is [authType] and
    /// whose enrollment id is [enrollmentId]. No OTP: an authenticated
    /// connection sends none.
    Future<Response> enrollRequest({
      required AuthType authType,
      String? enrollmentId,
      Map<String, String>? namespaces,
      String appName = 'legacy',
      String deviceName = 'legacy',
    }) async {
      final ep = EnrollParams()
        ..appName = appName
        ..deviceName = deviceName
        ..apkamPublicKey = 'a fresh apkam public key'
        ..namespaces = namespaces;
      inboundConnection.metaData
        ..isAuthenticated = true
        ..authType = authType
        ..sessionID = DateTime.now().millisecondsSinceEpoch.toString();
      inboundConnection.metadata.enrollmentId = enrollmentId;

      final r = Response();
      await etu.evh.processVerb(
        r,
        getVerbParam(
            VerbSyntax.enroll, 'enroll:request:${jsonEncode(ep.toJson())}'),
        inboundConnection,
      );
      return r;
    }

    test('it replaces the housekeeping enrollment and inherits its grants',
        () async {
      expect((await authenticateLegacy()).data, 'success');

      final r = await enrollRequest(
          authType: AuthType.pkamLegacy,
          enrollmentId: EnrollmentManager.housekeepingEnrollmentId);

      expect(r.isError, isFalse, reason: '${r.errorMessage}');
      final m = jsonDecode(r.data!);
      expect(m['status'], EnrollmentStatus.approved.name,
          reason: 'no human step and no OTP — the authenticated legacy '
              'credential is the authority, exactly as an APKAM one is');

      final successor = await enMgr.getEnrollmentById(m['enrollmentId']);
      expect(successor.parentEnrollmentId,
          EnrollmentManager.housekeepingEnrollmentId,
          reason: 'it REPLACES the legacy credential rather than descending '
              'from it');
      expect(successor.namespaces, {
        EnrollmentConstants.allNamespaces: 'rw',
        EnrollmentConstants.enrollManageNamespace: 'rw',
      }, reason: 'a retrofit carries its predecessor\'s grants exactly, and '
          'the legacy credential\'s are unrestricted');
      expect(successor.approvedByEnrollmentId, isNull,
          reason: 'it inherits the housekeeping enrollment\'s approver, which '
              'is nobody — so the legacy lineage stays outside every cascade');
    });

    test('a successor of it may not retrofit again', () async {
      expect((await authenticateLegacy()).data, 'success');
      final first = jsonDecode((await enrollRequest(
              authType: AuthType.pkamLegacy,
              enrollmentId: EnrollmentManager.housekeepingEnrollmentId))
          .data!)['enrollmentId'] as String;

      await expectLater(
          () => enrollRequest(
              authType: AuthType.apkam, enrollmentId: first),
          throwsA(isA<UnAuthorizedException>()),
          reason: 'the once-off rule applies here too: the legacy keyfile '
              'gets ONE no-approver migration, not a series that restarts the '
              'key-expiry clock every time');
    });

    test('a CRAM connection is auto-approved and NOT retrofitted', () async {
      // The pin for an ordering the code must not be allowed to rest on. A
      // CRAM connection reaches the auto-approve block first and returns
      // there; if it ever fell through to the retrofit branch it would be
      // refused for want of an enrollment id, and at_auth throws unless a
      // FIRST enrollment comes back approved — so onboarding would break for
      // every new user of the atSign, silently, from a reordering.
      final r = await enrollRequest(
          authType: AuthType.cram,
          enrollmentId: null,
          appName: 'cram-app',
          deviceName: 'cram-device');

      expect(r.isError, isFalse, reason: '${r.errorMessage}');
      final m = jsonDecode(r.data!);
      expect(m['status'], EnrollmentStatus.approved.name);
      final created = await enMgr.getEnrollmentById(m['enrollmentId']);
      expect(created.parentEnrollmentId, isNull,
          reason: 'auto-approve MINTS an enrollment; it does not replace one. '
              'A parent here would mean CRAM had received retrofit treatment');
      expect(created.namespaces, {
        EnrollmentConstants.enrollManageNamespace: 'rw',
        EnrollmentConstants.allNamespaces: 'rw',
      }, reason: 'and it carries the CRAM branch\'s own grants, not a '
          'predecessor\'s');

      // The pin for the non-write. `at_pkam_publickey` is what LEGACY
      // authentication verifies against; an `enroll:request` mints an APKAM
      // credential, which always authenticates WITH an id, so a key minted for
      // the second has no business becoming the first. The branch used to copy
      // it there "for old clients", which gave one keypair two identities AND,
      // being unconditional, destroyed whatever legacy credential the atSign
      // already had — and `enroll:request` is deliberately repeatable on a
      // CRAM connection, so every repeat clobbered it again.
      //
      // ⚠️ The raw literal is the seed `setUp` writes, and it is written
      // AFTER `etu.init()` — so this is the value a CRAM auto-approve found
      // and had to leave alone, not a value that merely happens to be there.
      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          'the-legacy-pkam-key',
          reason: 'the legacy credential is untouched, byte for byte');
    });
  });

  group('the legacy credential survives its own use', () {
    test('legacy authentication does not delete its own credential', () async {
      // A legacy credential must survive the authentication it performs and
      // still work on the next connection. A standing guard rather than the
      // test of one mechanism: creating the housekeeping enrollment READS
      // `at_pkam_publickey` — that read is how a bootstrap is told from a
      // retirement — so a legacy authentication touches the credential it
      // authenticated with, and this is what would go red first if that read
      // ever became a consuming one.
      //
      // ⚠️ Deliberately does NOT re-seed the key between authentications —
      // the helper does, and re-seeding would paper over exactly the deletion
      // under test.
      final mlDsa = await MlDsa65PureDartAlgo().generateKeyPair();
      await seedLegacyKey(base64Encode(mlDsa.publicKey));

      Future<Response> authenticate(String sessionId) async {
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

      expect((await authenticate('first')).data, 'success');
      expect(await keyValueStore.exists(AtConstants.atPkamPublicKey), isTrue,
          reason: 'the credential it authenticated WITH must survive the '
              'authentication');

      expect((await authenticate('second')).data, 'success',
          reason: 'and it must still work — a one-shot legacy credential is '
              'not a credential');
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

  /// The housekeeping enrollment stands for a credential it does not hold.
  /// Everything in this group turns on that: the record and the credential
  /// must not be able to come apart, and the way to guarantee it is for the
  /// record to carry nothing that could diverge.
  group('it holds NO credential of its own', () {
    /// An RSA legacy credential, replacing the seed `setUp` wrote.
    ///
    /// RSA rather than the ML-DSA [authenticateLegacy] uses, and that is
    /// load-bearing for the APKAM arm below. The housekeeping record carries
    /// no `signingAlgo`, and PKAM is record-authoritative for an enrollment —
    /// it resolves a null to rsa2048 EXPLICITLY rather than taking the wire's
    /// word — so an ML-DSA signature naming this enrollment would be verified
    /// as RSA and fail on the algorithm, whatever key the record held. That
    /// failure would look exactly like the refusal under test and would
    /// survive any mutation of it.
    late AtPkamKeyPair legacyPair;

    Future<void> seedRsaLegacyKey() async {
      legacyPair = AtChopsUtil.generateAtPkamKeyPair();
      await seedLegacyKey(legacyPair.atPublicKey.publicKey);
    }

    /// The PKAM signature over `<sessionId><atSign>:<challenge>` — the same
    /// framing the verb handler verifies, for both legacy and APKAM.
    String pkamSignature(String sessionId, String challenge) {
      final input = AtSigningInput('$sessionId$alice:$challenge')
        ..signingAlgoType = SigningAlgoType.rsa2048
        ..hashingAlgoType = HashingAlgoType.sha256
        ..signingMode = AtSigningMode.pkam;
      return AtChopsImpl(AtChopsKeys.create(null, legacyPair))
          .sign(input)
          .result;
    }

    /// Drives `pkam:` on a fresh connection. [idOnTheWire] null is a legacy
    /// authentication; anything else is an APKAM one naming that id.
    Future<Response> pkam(String sessionId, {String? idOnTheWire}) async {
      final challenge = 'challenge-$sessionId';
      await keyValueStore.put(
          'private:$sessionId$alice', AtData()..data = challenge);
      inboundConnection.metaData
        ..isAuthenticated = false
        ..enrollmentId = null
        ..sessionID = sessionId;
      final signature = pkamSignature(sessionId, challenge);
      final r = Response();
      await PkamVerbHandler(keyValueStore).processVerb(
        r,
        getVerbParam(
            VerbSyntax.pkam,
            idOnTheWire == null
                ? 'pkam:$signature'
                : 'pkam:enrollmentId:$idOnTheWire:$signature'),
        inboundConnection,
      );
      return r;
    }

    test('an APKAM authentication naming it fails for want of a key, not for '
        'want of a matching name', () async {
      await seedRsaLegacyKey();

      // The control, and it is drawn from the capability rather than from the
      // property under test: the SAME keypair, the SAME framing, presented
      // the way the legacy keyfile presents it. A green here says the
      // signature and the credential are both good, so the refusal below is
      // about the enrollment record and not about a fixture that cannot sign.
      expect((await pkam('control-session')).data, 'success',
          reason: 'precondition: this keypair IS the atSign\'s live legacy '
              'credential and authenticates with it');

      // ` primary`, deliberately. The refusal that compares the id against
      // the housekeeping id is EXACT, while the keystore folds a key on the
      // way in — trim, lowercase, strip spaces — so this spelling walks past
      // that comparison and still resolves to the housekeeping record.
      await expectLater(
          () => pkam('bypass-session', idOnTheWire: ' primary'),
          throwsA(isA<UnAuthenticatedException>().having((e) => e.message,
              'message', contains('pkam publickey not found'))),
          reason: 'the record carries an EMPTY apkamPublicKey, so an APKAM '
              'authentication naming it has nothing to verify against and is '
              'refused before any signature is looked at. With the legacy key '
              'snapshotted onto the record this exact call SUCCEEDS — the '
              'signature is valid against it — and the connection is APKAM '
              'authenticated as the atSign\'s legacy identity');

      expect(inboundConnection.metaData.isAuthenticated, isFalse,
          reason: 'and the connection is left unauthenticated');

      // The positive control for the bypass itself. Without this the refusal
      // above would be satisfied by ` primary` naming nothing at all, which
      // would make the whole test a statement about an unknown enrollment id.
      final resolved = await enMgr.getEnrollmentById(' primary');
      expect(resolved.appName, 'legacy',
          reason: 'the folded spelling really does reach the housekeeping '
              'record, so the exact-name refusal really was walked past');
      expect(resolved.apkamPublicKey, isEmpty,
          reason: 'and what stopped the authentication was the empty key');
    });

    test('...while the exact spelling is refused by name, before any of that',
        () async {
      // The other layer, kept honest alongside the first. Two independent
      // refusals: this one is cheap and says what is wrong, the empty key is
      // the one that cannot be spelled around.
      await seedRsaLegacyKey();
      final r = await pkam('named-session',
          idOnTheWire: EnrollmentManager.housekeepingEnrollmentId);
      expect(r.isError, isTrue);
      expect(r.errorCode, 'AT0009');
      expect(inboundConnection.metaData.isAuthenticated, isFalse);
    });

    test('a legacy connection rotates the credential through the update verb',
        () async {
      // The remedy the enroll:update refusal names, proved end to end. This
      // is why `primary` needs no writable key on its record: the credential
      // it stands for is rotated where the credential actually lives.
      await seedRsaLegacyKey();
      expect((await pkam('rotate-session')).data, 'success',
          reason: 'precondition: authenticated as the legacy credential, so '
              'the connection carries the housekeeping id');
      expect(inboundConnection.metaData.enrollmentId,
          EnrollmentManager.housekeepingEnrollmentId);

      final replacement = AtChopsUtil.generateAtPkamKeyPair();
      await etu.uvh.process(
          'update:${AtConstants.atPkamPublicKey} '
          '${replacement.atPublicKey.publicKey}',
          inboundConnection);

      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          replacement.atPublicKey.publicKey,
          reason: 'a connection that authenticated with the old key has '
              'proved possession of it, so rotating to a new one is the same '
              'act every other enrollment performs with enroll:update');

      legacyPair = replacement;
      expect((await pkam('post-rotation-session')).data, 'success',
          reason: 'and the new credential authenticates — a rotation nothing '
              'can authenticate with afterwards is a lockout');

      expect((await storedH())!.apkamPublicKey, isEmpty,
          reason: 'the record is untouched by the rotation, which is the '
              'whole reason it holds no key: there is no second copy to keep '
              'in step');
    });
  });

  group('enroll:update may not be pointed at it', () {
    /// The possession self-signature `enroll:update` demands over
    /// `<enrollmentId>|<apkamPublicKey>|<signingAlgo>`. Real crypto: a
    /// stand-in string would make the refusal below pass for want of a
    /// signature rather than because the target was refused.
    String possessionSignature(
        AtPkamKeyPair pair, String enId, String pub, String algo) {
      final input = AtSigningInput('$enId|$pub|$algo')
        ..signingAlgoType = SigningAlgoType.rsa2048
        ..hashingAlgoType = HashingAlgoType.sha256
        ..signingMode = AtSigningMode.pkam;
      return AtChopsImpl(AtChopsKeys.create(null, pair)).sign(input).result;
    }

    Future<Response> sendUpdate(String asEnrollmentId, EnrollParams p) async {
      inboundConnection.metaData
        ..isAuthenticated = true
        ..enrollmentId = asEnrollmentId;
      final r = Response();
      await etu.evh.processVerb(
        r,
        getVerbParam(
            VerbSyntax.enroll, 'enroll:update:${jsonEncode(p.toJson())}'),
        inboundConnection,
      );
      return r;
    }

    /// An `enroll:update` installing a freshly minted APKAM keypair on
    /// [target] — the attacker's request, fully formed and correctly signed.
    EnrollParams installFreshKey(String target) {
      final pair = AtChopsUtil.generateAtPkamKeyPair();
      final pub = pair.atPublicKey.publicKey;
      return EnrollParams()
        ..enrollmentId = target
        ..apkamPublicKey = pub
        ..signingAlgo = 'rsa2048'
        ..apkamPublicKeySignature =
            possessionSignature(pair, target, pub, 'rsa2048');
    }

    test('a LEGACY connection cannot install an APKAM key on it', () async {
      // The self-only gate cannot refuse this, which is the whole reason for a
      // separate one: that gate asks whether the connection is authenticated
      // as its target, and a legacy connection IS authenticated as `primary`.
      // So the one identity this verb must never be pointed at is the one
      // identity that satisfies the check.
      expect((await authenticateLegacy()).data, 'success');
      expect(inboundConnection.metaData.enrollmentId,
          EnrollmentManager.housekeepingEnrollmentId,
          reason: 'precondition: the connection carries the housekeeping id, '
              'so it is its own target');
      final keyBefore = (await storedH())!.apkamPublicKey;

      await expectLater(
          () => sendUpdate(EnrollmentManager.housekeepingEnrollmentId,
              installFreshKey(EnrollmentManager.housekeepingEnrollmentId)),
          throwsA(isA<AtEnrollmentException>().having(
              (e) => e.message,
              'message',
              contains('update:${AtConstants.atPkamPublicKey}'))),
          reason: 'without this refusal the request SUCCEEDS and answers '
              '{"enrollmentId":"primary","status":"approved"} — a legacy '
              'connection installing an APKAM key of its choosing on the '
              'atSign\'s legacy identity, which then authenticates over APKAM '
              'against a lifecycle nothing governs. The message names the '
              'remedy because the operation is legitimate and the route is '
              'not: the legacy credential is rotated where it lives');

      // Compared against what the record held BEFORE the request, not against
      // the empty string the record is created with. This test is about the
      // refusal and must stay green under any change to what the record
      // carries; asserting emptiness here would make it fail whenever the
      // record's contents moved, for reasons that have nothing to do with
      // enroll:update.
      expect((await storedH())!.apkamPublicKey, keyBefore,
          reason: 'and nothing was written — a refusal that had already '
              'installed the key would be a refusal in name only');
    });

    test('...and an ordinary enrollment can still rotate its own key',
        () async {
      // The control. Without it the refusal above would be satisfied by
      // enroll:update refusing every rotation, which would say nothing about
      // the housekeeping enrollment at all.
      final enId = (await etu.createEnrollments(n: 1)).$1.first;
      final params = installFreshKey(enId);
      final r = await sendUpdate(enId, params);

      expect(r.isError, isFalse, reason: '${r.errorMessage}');
      expect((await enMgr.getEnrollmentById(enId)).apkamPublicKey,
          params.apkamPublicKey,
          reason: 'the same request shape, correctly signed, against an '
              'ordinary enrollment: this is the operation the housekeeping '
              'enrollment is carved out of');
    });
  });

  group('a record standing over a gone credential is not a root', () {
    test('it stops counting once at_pkam_publickey is gone', () async {
      await enMgr.ensureHousekeepingEnrollment();

      expect(await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isTrue,
          reason: 'precondition: approved, fully privileged and permanent, so '
              'it answers the stranding question while its credential lives');

      // Removed on its own, leaving the record behind. That is not a shape
      // this server writes — `remove` takes both — but it is the shape the
      // atSign can be found in, and every route to it ends the same way: a
      // record that is approved, fully privileged, permanent, and impossible
      // to authenticate as.
      await keyValueStore.remove(AtConstants.atPkamPublicKey, skipCommit: true);

      expect(await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isFalse,
          reason: 'a PHANTOM root: counting it answers "this atSign can '
              'restore a root" with a record nobody holds a credential for, '
              'and the caller then revokes or caps the last root that '
              'actually works');

      // The control, and it is what stops the guard being satisfied by a walk
      // that has simply stopped finding anything.
      await seedLegacyKey();
      expect(await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isTrue,
          reason: 'the record never changed — only the credential it stands '
              'for came back');
    });

    test('...and an ordinary root is unaffected by the legacy key', () async {
      // The scope control: the extra condition applies to the housekeeping
      // enrollment ALONE. Every other enrollment carries its own key in its
      // own record, so record and credential cannot come apart for them.
      final other = await etu.createPendingEnrollment(
          appName: 'other-root',
          deviceName: 'device',
          namespaces: {
            EnrollmentConstants.allNamespaces: 'rw',
            EnrollmentConstants.enrollManageNamespace: 'rw',
          },
          apkamKeysExpiryDuration: null);
      await etu.approveEnrollment(etu.primaryEnId, other);
      await keyValueStore.remove(AtConstants.atPkamPublicKey, skipCommit: true);

      expect(
          await enMgr
              .hasUnexpiringRootEnrollment({etu.primaryEnId, 'primary'}),
          isTrue,
          reason: 'with the housekeeping enrollment excluded outright, the '
              'legacy key\'s absence must decide nothing');
    });
  });
}
