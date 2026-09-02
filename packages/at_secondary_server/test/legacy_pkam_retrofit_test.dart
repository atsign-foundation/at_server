import 'dart:async';

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
import 'package:at_utils/at_logger.dart';
import 'package:logging/logging.dart' as logging;
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
    // NO primary enrollment. The LAZY mint — on a first legacy
    // authentication — is refused by any enrollment record in the store, so a
    // fixture that enrols first would refuse every such mint under test and
    // turn each of those into a test of the fixture. A test that needs an
    // approver calls `etu.initPrimaryEnrollment()` once it has minted; the
    // startup-adoption tests enrol FIRST, because a populated store is
    // exactly what that path exists for.
    await etu.init(withPrimaryEnrollment: false);
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
  /// [keyPair], when given, is the credential ALREADY at `at_pkam_publickey`:
  /// the helper re-seeds the same bytes, so the key the atSign holds does not
  /// change across the call. A test that adopted an identity for a particular
  /// credential and then wants to authenticate AS that credential needs that;
  /// everything else takes a fresh pair.
  Future<Response> authenticateLegacy(
      {String sessionId = 'legacy-session',
      ({Uint8List publicKey, Uint8List secretKey})? keyPair}) async {
    final mlDsa = keyPair ?? await MlDsa65PureDartAlgo().generateKeyPair();
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

  /// A PENDING enrollment whose OWN APKAM credential is [apkamPublicKey].
  ///
  /// `ETU.createPendingEnrollment` derives the key from the app and device
  /// names, and what these tests need to control is precisely that value.
  Future<String> enrollmentHolding(String apkamPublicKey,
      {String appName = 'holder',
      String deviceName = 'device',
      Map<String, String> namespaces = const {'wavi': 'rw'}}) async {
    final EnrollParams ep = EnrollParams()
      ..appName = appName
      ..deviceName = deviceName
      ..apkamPublicKey = apkamPublicKey
      ..encryptedAPKAMSymmetricKey = 'encrypted apkam aes key'
      ..namespaces = namespaces
      ..otp = await etu.getOtp();
    inboundConnection.metaData
      ..isAuthenticated = false
      ..authType = null
      ..sessionID = DateTime.now().millisecondsSinceEpoch.toString();
    final r = Response();
    await etu.evh.processVerb(
      r,
      getVerbParam(
          VerbSyntax.enroll, 'enroll:request:${jsonEncode(ep.toJson())}'),
      inboundConnection,
    );
    expect(r.isError, isFalse, reason: '${r.errorMessage}');
    final m = jsonDecode(r.data!);
    expect(m['status'], EnrollmentStatus.pending.name);
    return m['enrollmentId'] as String;
  }

  /// Stores a zero-length legacy key. `seedLegacyKey('')` would do the same,
  /// but naming it is what stops a reader taking it for a typo — the emptiness
  /// is the whole subject of the tests that call this.
  Future<void> seedEmptyLegacyKey() async {
    await keyValueStore.put(AtConstants.atPkamPublicKey, AtData()..data = '',
        skipCommit: true);
    expect(await keyValueStore.exists(AtConstants.atPkamPublicKey), isTrue,
        reason: 'the key IS present: presence is what must stop being the bar');
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
      await etu.initPrimaryEnrollment();
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
      await etu.initPrimaryEnrollment();

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

    test('it is NOT minted from an EMPTY legacy key', () async {
      // Zero-length is a state the atSign can be found in: `update:json`
      // carries its value inside the JSON document rather than through the
      // `update` grammar's non-empty value capture, so an owner connection can
      // store one. Authentication refuses an empty public key before it looks
      // at a signature, so a record minted here would stand over a credential
      // nobody can authenticate with.
      await seedEmptyLegacyKey();

      expect(await enMgr.ensureHousekeepingEnrollment(), isNull,
          reason: 'PRESENCE is not the bar. A zero-length value is a '
              'credential nobody can authenticate with, so it must read '
              'exactly as the key being gone reads');
      expect(await storedH(), isNull,
          reason: 'and nothing was written — an identity for a credential '
              'that cannot authenticate is the phantom root, minted');
    });

    test('it is NOT minted once the atSign holds ANY enrollment', () async {
      // RULED: a legacy credential is one that authenticated BEFORE any
      // enrollment existed, because authenticating with no enrollment id at
      // all is what the legacy flow IS. A key presented as one on a populated
      // store arrived some other way, and the commonest way is older servers'
      // CRAM auto-approve branch, which wrote the enrolling app's own APKAM
      // key here "for old clients".
      final String holder = await enrollmentHolding('a keypair the app holds');
      await seedLegacyKey('a keypair the app holds');

      expect(await enMgr.ensureHousekeepingEnrollment(), isNull,
          reason: 'declined, so legacy authentication is refused rather than '
              'granting enrollment $holder\'s own keypair a second identity');
      expect(await storedH(), isNull,
          reason: 'and nothing was written — a null return that created the '
              'record anyway would grant the identity regardless');
      expect(await keyValueStore.exists(AtConstants.atPkamPublicKey), isTrue,
          reason: 'declining is a REFUSAL, not a repair. The server cannot '
              'tell such a copy from a credential an owner provisioned with a '
              'keypair it also enrolled, so deleting one would lock an owner '
              'out instead of tidying up after an app');
    });

    test('...while an atSign holding none mints as usual', () async {
      // The control, and it is what stops the refusal above being satisfied
      // by creation never happening: the same key, the same call, differing
      // only in whether the store holds an enrollment.
      await seedLegacyKey('a keypair the app holds');

      expect(await enMgr.ensureHousekeepingEnrollment(), isNotNull);
      expect(await storedH(), isNotNull);
    });

    test('the enrollment that refuses it need not hold the legacy key',
        () async {
      // BEHAVIOUR CHANGED — the rule this replaces declined only when
      // `at_pkam_publickey` equalled some enrollment's own `apkamPublicKey`,
      // which keyed the decision on a record the holder of that key CONTROLS.
      // The question is now asked of the STORE, so an enrollment with no
      // connection to the key at all refuses the mint just the same.
      await enrollmentHolding('a keypair of the app\'s own');
      await seedLegacyKey('a key no enrollment holds');

      expect(await enMgr.ensureHousekeepingEnrollment(), isNull,
          reason: 'the previous rule minted here, because no enrollment held '
              'this key. Whether an enrollment holds it is not the question: '
              'whether the atSign had been enrolled before this credential '
              'turned up is');
    });

    test('deleting the enrollment that held the key no longer mints it',
        () async {
      // The defeat this rule was ruled for, driven through the wire verbs.
      // The previous rule protected a record the attacker owned, so four
      // commands were enough: revoke itself with the force flag, which alone
      // lifts the self-revoke refusal; delete itself, which demonstrates no
      // `__manage` because a caller may always delete its own enrollment; and
      // then a legacy authentication minted `primary` at `*:rw` +
      // `__manage:rw`, with no approver and no expiry, for the keypair whose
      // enrollment had just gone.
      await etu.initPrimaryEnrollment();
      const String stolen = 'the app\'s own keypair, also at at_pkam_publickey';
      final String app = await enrollmentHolding(stolen, namespaces: {
        EnrollmentConstants.allNamespaces: 'rw',
        EnrollmentConstants.enrollManageNamespace: 'rw',
      });
      await etu.approveEnrollment(etu.primaryEnId, app);
      await seedLegacyKey(stolen);

      // enroll:revoke:force on ITSELF.
      inboundConnection.metaData
        ..isAuthenticated = true
        ..enrollmentId = app;
      final revoke = Response();
      await etu.evh.processVerb(
        revoke,
        getVerbParam(
            VerbSyntax.enroll,
            'enroll:revoke:force:'
            '${jsonEncode((EnrollParams()..enrollmentId = app).toJson())}'),
        inboundConnection,
      );
      expect(jsonDecode(revoke.data!)['status'], EnrollmentStatus.revoked.name,
          reason: 'precondition: the force flag lifts the self-revoke refusal');

      // enroll:delete on ITSELF.
      await etu.deleteEnrollment(app, app);
      expect(await keyValueStore.exists(enMgr.buildEnrollmentKey(app)), isFalse,
          reason: 'precondition: no record now holds this keypair, which is '
              'the whole of what the previous rule looked at');

      expect(await enMgr.ensureHousekeepingEnrollment(), isNull,
          reason: 'the atSign has been enrolled — the enrollment this app '
              'destroyed was not the only one — so the key at '
              'at_pkam_publickey did not authenticate before any enrollment '
              'existed and is not a legacy credential, whatever the roster '
              'now says');
      expect(await storedH(), isNull,
          reason: 'and no unexpiring root was minted for the keypair the app '
              'still holds');
    });

    test('legacy authentication with such a key is REFUSED', () async {
      // The consequence end to end, through the verb handler, with a
      // signature that VERIFIES — so the refusal cannot be read as a bad
      // signature, and the credential really would have been granted root.
      final mlDsa = await MlDsa65PureDartAlgo().generateKeyPair();
      final String key = base64Encode(mlDsa.publicKey);
      await enrollmentHolding('a keypair of the app\'s own');
      await seedLegacyKey(key);

      const String sessionId = 'vestigial-session';
      const String challenge = 'a-per-connection-challenge';
      await keyValueStore.put(
          'private:$sessionId$alice', AtData()..data = challenge);
      final signature = await MlDsa65PureDartAlgo().signBytes(
          Uint8List.fromList(utf8.encode('$sessionId$alice:$challenge')),
          secretKey: mlDsa.secretKey);
      inboundConnection.metaData
        ..isAuthenticated = false
        ..enrollmentId = null
        ..sessionID = sessionId;

      await expectLater(
          PkamVerbHandler(keyValueStore).processVerb(
            Response(),
            getVerbParam(VerbSyntax.pkam,
                'pkam:signingAlgo:mldsa65:${base64Encode(signature)}'),
            inboundConnection,
          ),
          throwsA(isA<UnAuthenticatedException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('no usable legacy PKAM credential'),
                // BEHAVIOUR CHANGED — this used to read `a legacy credential
                // is adopted only by an atSign that holds no enrollments`,
                // which stopped being the rule when adoption moved to server
                // startup. A populated atSign DOES adopt its existing
                // credential; what is refused is a key that turns up at
                // `at_pkam_publickey` afterwards.
                contains('adopted at server startup'),
                contains('a key installed at this atSign afterwards is not '
                    'adopted'),
              ))),
          reason: 'the signature is GOOD — this keypair really does hold the '
              'key at at_pkam_publickey — so the only thing between it and a '
              'permanent root identity is this refusal. The message names the '
              'remedy because the population that hits it is an operator on '
              'an established atSign, not an attacker');

      expect(inboundConnection.metaData.isAuthenticated, isFalse,
          reason: 'and the connection is left unauthenticated rather than '
              'authenticated and then thrown out of');
      expect(await storedH(), isNull,
          reason: 'no identity was minted for it');
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

  // =====================================================================
  // What an operator is told when the identity is NOT minted.
  // =====================================================================

  /// The refusal a caller gets is deliberately one message for both causes —
  /// the caller has not authenticated and the two are not its business — so
  /// the only place the distinction exists is the manager's log. PkamVerbHandler
  /// says so in as many words ("The manager logs the distinction, naming what
  /// it found"), which makes it a claim about this code that ships, and an
  /// operator arriving at an atSign that refuses its keyfile has nothing else
  /// to read.
  group('the manager logs which refusal it took', () {
    /// Runs [act] with the manager's logger lowered to [level] and returns
    /// every record it emitted at or above that level.
    ///
    /// Lowered on the INSTANCE, not through AtSignLogger.root_level: an
    /// AtSignLogger takes its level once, at construction, and `enMgr` was
    /// built by verbTestsSetUp at the suite's 'shout' — which is above both
    /// levels used here, so without this every assertion below would be about
    /// a logger that emitted nothing. Records reach the detached logger's own
    /// stream rather than Logger.root's.
    Future<List<String>> logsWhile(
        Future<void> Function() act, String level) async {
      // Restored from AtSignLogger.root_level, which is what the suite's own
      // setUp assigns, and NOT from the instance getter: `AtSignLogger.level`
      // compares a `Level.toString()` ("SHOUT") against the lowercase name it
      // stored ("shout"), so it answers null for every level a caller ever set
      // — and `logger.level = null` throws on a detached logger.
      enMgr.logger.level = level;
      final threshold = level == 'info'
          ? logging.Level.INFO
          : logging.Level.WARNING;
      final captured = <String>[];
      final sub = enMgr.logger.logger.onRecord.listen((r) {
        if (r.level >= threshold) captured.add(r.message);
      });
      try {
        await act();
      } finally {
        await sub.cancel();
        enMgr.logger.level = AtSignLogger.root_level;
      }
      return captured;
    }

    /// The one line that says the identity was not minted. `singleWhere`
    /// deliberately: an empty capture and two lines disagreeing with each
    /// other both throw here rather than quietly satisfying a `contains`.
    String refusalIn(List<String> records) => records.singleWhere(
        (r) => r.startsWith('Not creating the housekeeping enrollment'),
        orElse: () => fail('nothing said why the identity was not minted, '
            'from ${records.length} record(s): $records'));

    test('a populated store: the line names HOW MANY records it found',
        () async {
      // The count is the whole of the diagnostic. The rule is about the STORE
      // rather than about any one record — an enrollment with no connection to
      // the key at all refuses the mint just the same — so "which enrollment"
      // is not a question this refusal can answer, and how many there are is.
      await etu.initPrimaryEnrollment();
      await enrollmentHolding('a key', appName: 'app-one');
      await enrollmentHolding('another key', appName: 'app-two');
      expect(await enMgr.getAllEnrollmentKeys(includeExpired: true),
          hasLength(3),
          reason: 'precondition: the fixture built exactly three, so the '
              'literal below is a count taken independently of the message');

      final line = refusalIn(await logsWhile(
          () => enMgr.ensureHousekeepingEnrollment(), 'warning'));

      expect(line, contains('already holds 3 enrollment record(s)'),
          reason: 'an operator reading this decides whether the atSign really '
              'has been enrolled, so a count that disagrees with the roster '
              'sends them looking for records that are not there');
      expect(line, contains(AtConstants.atPkamPublicKey),
          reason: 'and it names the key it is refusing to adopt');
      expect(line, contains('enroll:request'),
          reason: 'and the remedy, which is the same either way');
    });

    test('...at WARNING, because it is the anomalous one', () async {
      // Level is part of the diagnostic: this is an atSign refusing a
      // credential somebody is presenting as legacy, which is a thing an
      // operator should see without turning anything up. Captured at warning
      // and found there.
      await etu.initPrimaryEnrollment();

      final atWarning = await logsWhile(
          () => enMgr.ensureHousekeepingEnrollment(), 'warning');

      expect(refusalIn(atWarning), contains('already holds'));
    });

    test('a retired credential: a DIFFERENT line, naming the key', () async {
      // The other refusal, and the two must not read alike — the caller is
      // told the same thing in both cases, so an operator working out which
      // one they are in has only these lines to go on. Absent means the
      // credential was RETIRED: removing the record always takes the key with
      // it.
      await keyValueStore.remove(AtConstants.atPkamPublicKey, skipCommit: true);

      final line = refusalIn(await logsWhile(
          () => enMgr.ensureHousekeepingEnrollment(), 'info'));

      expect(line, contains('is absent or empty'),
          reason: 'this is the retirement case, and it says so');
      expect(line, contains(AtConstants.atPkamPublicKey));
      expect(line, isNot(contains('already holds')),
          reason: 'the two refusals must not be confusable: an operator told '
              'the store is populated would go looking for enrollments on an '
              'atSign whose credential was simply withdrawn');
    });

    test('CONTROL: a mint that SUCCEEDS says none of it', () async {
      // Drawn from a property the diagnostic does not touch, and it is what
      // stops the cases above being satisfied by the manager logging that
      // sentence on every call. The fixture leaves the key present and the
      // store empty, which is the one state the identity IS minted in.
      final records = await logsWhile(() async {
        expect(await enMgr.ensureHousekeepingEnrollment(), isNotNull,
            reason: 'precondition: this arrangement really does mint');
      }, 'info');

      expect(
          records.where(
              (r) => r.startsWith('Not creating the housekeeping enrollment')),
          isEmpty);
      expect(records.where((r) => r.contains('Creating the housekeeping')),
          isNotEmpty,
          reason: 'and the rig really was listening — an empty capture would '
              'satisfy the absence above for the wrong reason');
    });
  });

  group('enroll:unrevoke may not resurrect the legacy credential', () {
    test('it is refused on `primary`, and the refusal says why', () async {
      await enMgr.ensureHousekeepingEnrollment();
      await setHStatus(EnrollmentStatus.revoked);

      await expectLater(
          () => etu.unrevokeEnrollment(
              etu.primaryEnId, EnrollmentManager.housekeepingEnrollmentId),
          throwsA(isA<AtEnrollmentException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('enroll:unrevoke cannot be used on '
                    '${EnrollmentManager.housekeepingEnrollmentId}'),
                contains('untouched by that revoke'),
              ))),
          reason: 'revoking this record is the atSign\'s only way to withdraw '
              'the legacy credential, and the credential itself is left in '
              'the keystore — so the refusal has to name that, not just say '
              'no');

      expect((await storedH())!.approval?.state, EnrollmentStatus.revoked.name,
          reason: 'and the record is left exactly as the revoke left it');
    });

    test('...while an ordinary revoked enrollment un-revokes as before',
        () async {
      // The control. Without it the refusal above is satisfied by
      // `enroll:unrevoke` refusing everything, which would say nothing about
      // the housekeeping enrollment at all.
      await etu.initPrimaryEnrollment();
      final String other = await etu.createPendingEnrollment(
          appName: 'other',
          deviceName: 'device',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null);
      await etu.approveEnrollment(etu.primaryEnId, other);
      await etu.revokeEnrollment(etu.primaryEnId, other);

      await etu.unrevokeEnrollment(etu.primaryEnId, other);

      expect((await enMgr.getEnrollmentById(other)).approval?.state,
          EnrollmentStatus.approved.name,
          reason: 'the same request shape against an ordinary enrollment: '
              'this is the operation the housekeeping enrollment is carved '
              'out of');
    });

    test('so a revoked legacy credential cannot be made to work again',
        () async {
      // The consequence, end to end, and the reason the carve-out is not
      // bookkeeping: the revoke leaves `at_pkam_publickey` in place, so
      // legacy authentication is refused only because the record reads
      // `revoked`. Flipping the record back is the whole of what an attacker
      // — or a careless operator — would need.
      expect((await authenticateLegacy()).data, 'success',
          reason: 'precondition: it authenticates while approved');

      await setHStatus(EnrollmentStatus.revoked);
      expect(await keyValueStore.exists(AtConstants.atPkamPublicKey), isTrue,
          reason: 'precondition: the revoke does NOT remove the credential, '
              'which is exactly why an un-revoke would restore a working one');

      await expectLater(
          () => etu.unrevokeEnrollment(
              etu.primaryEnId, EnrollmentManager.housekeepingEnrollmentId),
          throwsA(isA<AtEnrollmentException>()),
          reason: 'the un-revoke has to be refused, or the assertion below '
              'is about a credential this command already restored');

      await expectLater(
          () => authenticateLegacy(sessionId: 'after-refused-unrevoke'),
          throwsA(isA<UnAuthenticatedException>().having((e) => e.message,
              'message', contains('the legacy credential for this atSign is '
                  'revoked'))),
          reason: 'the withdrawal stands. Getting a working credential back '
              'is a fresh enrollment, not an undo');
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

    test('reading an EXPIRED one does not retire the legacy credential',
        () async {
      // The read that used to write. `getEnrollmentByFullKey` REMOVED a
      // record whose ttl had elapsed, and for THIS record `remove` fires the
      // pre-remove hook, which takes `at_pkam_publickey` with it — so reading
      // the roster, or any authorisation check on any connection, could
      // retire the atSign's legacy credential as a side effect. Reads are
      // deliberately outside the enrollment-mutation critical section, so it
      // was also a store mutation taken while another was in flight.
      await enMgr.ensureHousekeepingEnrollment();
      final h = (await storedH())!;
      await enMgr.put(
          EnrollmentManager.housekeepingEnrollmentId,
          AtData()
            ..data = jsonEncode(h.toJson())
            ..metaData = (AtMetaData()..ttl = 1),
          EnrollmentStatus.approved);
      await Future.delayed(Duration(milliseconds: 5));

      final read = await enMgr
          .getEnrollmentById(EnrollmentManager.housekeepingEnrollmentId);

      expect(read.approval?.state, EnrollmentStatus.expired.name,
          reason: 'the read still REPORTS the expiry, which is what every '
              'caller decides on — not removing it costs them nothing');
      expect(await keyValueStore.exists(AtConstants.atPkamPublicKey), isTrue,
          reason: 'reading the record must not retire the credential it '
              'stands for. Retirement is a deliberate act — enroll:delete, or '
              'the cap having expired the record — never something a reader '
              'does on the way past');
      expect(await storedH(), isNotNull,
          reason: 'and the record itself is left for the scheduled pass');

      // The control, and it is what stops the assertions above being
      // satisfied by nothing ever removing this record: the job whose
      // business it is still retires it, hook and all.
      await keyValueStore.deleteExpiredKeys();
      expect(await storedH(), isNull);
      expect(await keyValueStore.exists(AtConstants.atPkamPublicKey), isFalse,
          reason: 'the pre-remove hook fires on the scheduled pass exactly as '
              'it does on an enroll:delete, so the guarantee is kept by the '
              'job whose business it is');
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
      await etu.initPrimaryEnrollment();
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

    test('a non-canonical spelling of its id is refused BY NAME, because the '
        'wire id is folded the way the keystore folds a key', () async {
      await seedRsaLegacyKey();

      // The control, and it is drawn from the capability rather than from the
      // property under test: the SAME keypair, the SAME framing, presented
      // the way the legacy keyfile presents it. A green here says the
      // signature and the credential are both good, so the refusal below is
      // about the enrollment record and not about a fixture that cannot sign.
      expect((await pkam('control-session')).data, 'success',
          reason: 'precondition: this keypair IS the atSign\'s live legacy '
              'credential and authenticates with it');

      // ` primary`, deliberately: the spelling that RESOLVES to the
      // housekeeping record while not being the literal id. The wire id is
      // folded to exactly the keystore\'s fold — trim, lowercase, strip
      // spaces — so the refusal that compares against the housekeeping id
      // sees the same string the keystore does, and answers about the record
      // this call actually reaches.
      final bypass = await pkam('bypass-session', idOnTheWire: ' primary');
      expect(bypass.isError, isTrue);
      expect(bypass.errorCode, 'AT0009',
          reason: 'the fold makes this the SAME id, so it lands on the '
              'by-name refusal instead of walking past it — which is the '
              'refusal that says what is wrong. Unfolded, this spelling was '
              'stopped only by the empty key, two layers further in');
      expect(bypass.errorMessage, contains('legacy PKAM'));

      expect(inboundConnection.metaData.isAuthenticated, isFalse,
          reason: 'and the connection is left unauthenticated');

      // The positive control for the spelling itself. Without this the
      // refusal above would be satisfied by ` primary` naming nothing at all,
      // which would make the whole test a statement about an unknown
      // enrollment id rather than about the housekeeping record.
      final resolved = await enMgr.getEnrollmentById(' primary');
      expect(resolved.appName, 'legacy',
          reason: 'the spelling really does reach the housekeeping record, so '
              'the by-name refusal really was answering about THAT record');
      expect(resolved.apkamPublicKey, isEmpty,
          reason: 'and the empty key is still the defence that cannot be '
              'spelled around: it is what would refuse this authentication if '
              'the id ever reached the verifier');
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

    /// The `update:json` document that rotates the legacy credential onto
    /// [pair], carrying the proof of possession the server demands.
    ///
    /// The signature is over `primary|<new public key>|<signingAlgo>`, made
    /// with the NEW private half — byte-identical framing to the one
    /// `enroll:update` demands of every other credential, which is what makes
    /// a key that can authenticate installable and a key installed here able
    /// to authenticate.
    String rotationCommand(AtPkamKeyPair pair,
        {String? signature, String signingAlgo = 'rsa2048'}) {
      final String pub = pair.atPublicKey.publicKey;
      final input = AtSigningInput(
          '${EnrollmentManager.housekeepingEnrollmentId}|$pub|$signingAlgo')
        ..signingAlgoType = SigningAlgoType.rsa2048
        ..hashingAlgoType = HashingAlgoType.sha256
        ..signingMode = AtSigningMode.pkam;
      // Built from UpdateParams, exactly as a client would: `metadata` has to
      // be a full Metadata document — `Metadata.fromJson` reads `isPublic`
      // into a non-nullable bool, so an empty object throws before the
      // handler is reached — and the two proof fields are added to the map it
      // produces, because UpdateParams does not model them.
      final document = (UpdateParams()
            ..atKey = AtConstants.atPkamPublicKey
            ..value = pub
            ..metadata = Metadata())
          .toJson();
      document['signingAlgo'] = signingAlgo;
      document['apkamPublicKeySignature'] = signature ??
          AtChopsImpl(AtChopsKeys.create(null, pair)).sign(input).result;
      return 'update:json:${jsonEncode(document)}';
    }

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
      await etu.uvh.process(rotationCommand(replacement), inboundConnection);

      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          replacement.atPublicKey.publicKey,
          reason: 'a connection that authenticated with the old key has '
              'proved possession of it, and the request proves possession of '
              'the new one — the same act every other enrollment performs '
              'with enroll:update');

      legacyPair = replacement;
      expect((await pkam('post-rotation-session')).data, 'success',
          reason: 'and the new credential authenticates — a rotation nothing '
              'can authenticate with afterwards is a lockout');

      expect((await storedH())!.apkamPublicKey, isEmpty,
          reason: 'the record is untouched by the rotation, which is the '
              'whole reason it holds no key: there is no second copy to keep '
              'in step');
    });

    test('the signable is exactly "primary|<value>|<signingAlgo>"', () async {
      // RAW LITERAL, not composed from the constants the server composes it
      // from — a comparison against the constants that define a value pins
      // nothing, and `rotationCommand` above builds the signable that way.
      //
      // FROZEN: a client makes this signature before anything reaches the
      // server, so a change to the framing is a change every rotating client
      // has to ship in the same release. An intended change edits this
      // literal, and that edit is the review.
      await seedRsaLegacyKey();
      expect((await pkam('framing-session')).data, 'success',
          reason: 'precondition: the connection is entitled to rotate the '
              'credential, so what is measured below is the framing');

      final replacement = AtChopsUtil.generateAtPkamKeyPair();
      final String pub = replacement.atPublicKey.publicKey;
      String signOver(String message) =>
          AtChopsImpl(AtChopsKeys.create(null, replacement))
              .sign(AtSigningInput(message)
                ..signingAlgoType = SigningAlgoType.rsa2048
                ..hashingAlgoType = HashingAlgoType.sha256
                ..signingMode = AtSigningMode.pkam)
              .result;

      // The NEGATIVE control first, and it is the atSign-bound framing on
      // purpose: this signable carries no atSign, deliberately, so that a
      // client implements one rule for this rotation and for enroll:update.
      // The binding is not what stops a replay — authorisation is — so the
      // server must NOT accept the bound spelling by accident.
      final String before =
          (await keyValueStore.get(AtConstants.atPkamPublicKey))!.data!;
      await expectLater(
          etu.uvh.process(
              rotationCommand(replacement,
                  signature: signOver('primary|$pub|rsa2048|$alice')),
              inboundConnection),
          throwsA(isA<UnAuthorizedException>()),
          reason: 'a signature over any other framing must not verify, or the '
              'pin below is satisfied by a server that checks nothing');
      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          before,
          reason: 'and the refusal is not one in name only');

      await etu.uvh.process(
          rotationCommand(replacement,
              signature: signOver('primary|$pub|rsa2048')),
          inboundConnection);

      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data, pub,
          reason: 'the bytes a client signs are the enrollment id, the new '
              'public key and the signing algorithm, joined by "|" in that '
              'order, with the id spelled "primary" — the same framing '
              'enroll:update demands of every other credential');
    });

    test('a rotation carrying NO proof of possession is refused', () async {
      // MEASURED: without this the same request installs a well-formed key
      // whose private half was never persisted, and `primary` goes on being
      // counted as the atSign's surviving unexpiring root — the bar is a
      // credential something can authenticate with, and a well-formed orphan
      // passes it — while nothing can authenticate as it. The last root that
      // really works then becomes revocable.
      await seedRsaLegacyKey();
      expect((await pkam('no-proof-session')).data, 'success',
          reason: 'precondition: the connection is the legacy credential\'s '
              'own holder, so it is entitled to rotate it');
      final String before =
          (await keyValueStore.get(AtConstants.atPkamPublicKey))!.data!;

      final orphan = AtChopsUtil.generateAtPkamKeyPair();
      await expectLater(
          etu.uvh.process(
              'update:${AtConstants.atPkamPublicKey} '
              '${orphan.atPublicKey.publicKey}',
              inboundConnection),
          throwsA(isA<IllegalArgumentException>().having((e) => e.message,
              'message', contains('requires proof'))),
          reason: 'the plain form has no parameter that could carry a '
              'signature, so a rotation must use update:json — and the '
              'refusal says so rather than failing a verification the request '
              'never attempted');

      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          before,
          reason: 'and the credential is untouched, so the refusal is not one '
              'in name only');
    });

    test('a rotation whose signature is by the WRONG key is refused',
        () async {
      // The other half: a request that carries a signature is not a request
      // that carries a PROOF. This one is real crypto, correctly framed, made
      // by a keypair the sender genuinely holds — just not the one it is
      // asking the atSign to trust.
      await seedRsaLegacyKey();
      expect((await pkam('wrong-key-session')).data, 'success');
      final String before =
          (await keyValueStore.get(AtConstants.atPkamPublicKey))!.data!;

      final installed = AtChopsUtil.generateAtPkamKeyPair();
      final other = AtChopsUtil.generateAtPkamKeyPair();
      final String otherSignature = AtChopsImpl(AtChopsKeys.create(null, other))
          .sign(AtSigningInput(
              '${EnrollmentManager.housekeepingEnrollmentId}|'
              '${installed.atPublicKey.publicKey}|rsa2048')
            ..signingAlgoType = SigningAlgoType.rsa2048
            ..hashingAlgoType = HashingAlgoType.sha256
            ..signingMode = AtSigningMode.pkam)
          .result;

      await expectLater(
          etu.uvh.process(
              rotationCommand(installed, signature: otherSignature),
              inboundConnection),
          throwsA(isA<UnAuthorizedException>().having((e) => e.message,
              'message', contains('does not verify'))),
          reason: 'the signature must be by the private half of the key being '
              'INSTALLED — that is the whole of what proof of possession '
              'means here');

      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          before);
    });

    test('the FIRST key needs no proof, because nothing stands over it',
        () async {
      // The bootstrap exemption, and the control that stops the refusals
      // above being satisfied by "this key can no longer be written at all" —
      // which would break onboarding on every atSign. An owner or CRAM
      // connection carries no enrollment id, and on an atSign that has never
      // minted `primary` there is no identity for an unusable value to stand
      // over: possession is proved later and by construction, because only a
      // legacy authentication that verified a signature against this key
      // mints the record.
      await keyValueStore.remove(AtConstants.atPkamPublicKey, skipCommit: true);
      expect(await storedH(), isNull,
          reason: 'precondition: no housekeeping enrollment, so this is a '
              'bootstrap and not a rotation');
      inboundConnection.metaData
        ..isAuthenticated = true
        ..authType = AuthType.cram
        ..enrollmentId = null;

      final first = AtChopsUtil.generateAtPkamKeyPair();
      await etu.uvh.process(
          'update:${AtConstants.atPkamPublicKey} '
          '${first.atPublicKey.publicKey}',
          inboundConnection);

      expect((await keyValueStore.get(AtConstants.atPkamPublicKey))?.data,
          first.atPublicKey.publicKey,
          reason: 'onboarding plants the first key over a CRAM connection in '
              'exactly this shape, and it must keep working');
    });

    test('...but the SAME connection is refused once the identity exists',
        () async {
      // The paired arm, differing from the control above only in whether the
      // housekeeping record is there. An owner or CRAM connection can strand
      // the atSign exactly as a legacy one can, so the demand is made of
      // whoever is writing rather than of a particular authentication type.
      await seedRsaLegacyKey();
      expect((await pkam('mint-session')).data, 'success',
          reason: 'precondition: this is what mints the identity');
      expect(await storedH(), isNotNull);

      inboundConnection.metaData
        ..isAuthenticated = true
        ..authType = AuthType.cram
        ..enrollmentId = null;

      final replacement = AtChopsUtil.generateAtPkamKeyPair();
      await expectLater(
          etu.uvh.process(
              'update:${AtConstants.atPkamPublicKey} '
              '${replacement.atPublicKey.publicKey}',
              inboundConnection),
          throwsA(isA<IllegalArgumentException>().having((e) => e.message,
              'message', contains('requires proof'))),
          reason: 'the exemption is about the atSign\'s state, not about who '
              'is asking — a CRAM connection installing an orphan over a live '
              '`primary` strands the atSign the same way');
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
              allOf(
                contains(AtConstants.atPkamPublicKey),
                contains('apkamPublicKeySignature'),
              ))),
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
      await etu.initPrimaryEnrollment();
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

    test('an EMPTY at_pkam_publickey is a phantom root just the same',
        () async {
      await enMgr.ensureHousekeepingEnrollment();

      expect(await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isTrue,
          reason: 'precondition: approved, fully privileged and permanent, so '
              'it answers the stranding question while its credential lives');

      // PRESENT but zero-length, which is a state `update:json` can write:
      // its value travels inside the JSON document rather than through the
      // `update` grammar's non-empty value capture.
      await seedEmptyLegacyKey();

      expect(await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isFalse,
          reason: 'authentication refuses an empty public key before it looks '
              'at any signature, so the record stands over a credential '
              'NOBODY can authenticate with — the same phantom root as a '
              'missing key, reached by a route a presence check waves '
              'through. Counting it tells the caller the atSign can restore a '
              'root, and the caller then revokes the last one that works');

      // The control, and it is what stops the guard being satisfied by a walk
      // that has simply stopped finding anything.
      await seedLegacyKey();
      expect(await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isTrue,
          reason: 'the record never changed — only the value at the key it '
              'stands over');
    });

    test('...and an ordinary root is unaffected by the legacy key', () async {
      // The scope control: the extra condition applies to the housekeeping
      // enrollment ALONE. Every other enrollment carries its own key in its
      // own record, so record and credential cannot come apart for them.
      await etu.initPrimaryEnrollment();
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

  // =====================================================================
  // Which roster a decision reads.
  // =====================================================================

  /// Moves [enId]'s record one minute past its expiry and leaves it exactly
  /// where it is on disk.
  ///
  /// This is the state every enrollment passes through: the keystore stops
  /// ENUMERATING a record the instant its ttl elapses, and the scheduled
  /// expired-keys pass removes it tens of seconds later. In between, the
  /// record is on disk, readable by key, and invisible to `getKeys` — so the
  /// roster a decision reads is a different set from the one the atSign holds.
  ///
  /// Asserts that state rather than assuming it, because the whole of every
  /// arm below is the difference between the two rosters.
  Future<void> elapseTtlOf(String enId) async {
    final String ek = enMgr.buildEnrollmentKey(enId);
    final AtData record = (await keyValueStore.get(ek))!;
    final EnrollDataStoreValue v =
        EnrollDataStoreValue.fromJson(jsonDecode(record.data!));
    await enMgr.put(
        enId, record, EnrollmentStatus.values.byName(v.approval!.state),
        assertedTimestamps: AtAssertedTimestamps(
            expiresAt: DateTime.now().toUtc().subtract(Duration(minutes: 1)),
            deriveTtl: true));

    expect(await keyValueStore.exists(ek), isTrue,
        reason: 'STILL ON DISK. If the record were gone this would be a test '
            'of deletion, and every arm below would prove nothing');
    expect(await enMgr.getAllEnrollmentKeys(includeExpired: false),
        isNot(contains(ek)),
        reason: 'and gone from the VISIBLE roster, which is the one variable');
  }

  group('the roster a decision reads', () {
    test('the two rosters disagree about an elapsed record', () async {
      // The instrument, with both colours in one test: the stored roster is
      // not simply the visible one under another name, and the visible one is
      // not simply broken.
      final String live = await enrollmentHolding('key one', appName: 'live');
      final String elapsed =
          await enrollmentHolding('key two', appName: 'elapsed');
      await elapseTtlOf(elapsed);

      expect(await enMgr.getAllEnrollmentKeys(includeExpired: false),
          [enMgr.buildEnrollmentKey(live)],
          reason: 'getKeys skips a record whose ttl has elapsed');
      expect(
          await enMgr.getAllEnrollmentKeys(includeExpired: true),
          unorderedEquals([
            enMgr.buildEnrollmentKey(live),
            enMgr.buildEnrollmentKey(elapsed),
          ]),
          reason: 'while the atSign holds both, and get() and exists() both '
              'still answer for the second');
    });

    test('ARM 1: a LIVE enrollment refuses the housekeeping mint', () async {
      await enrollmentHolding('a keypair the app holds', appName: 'holder');
      await seedLegacyKey('a keypair the app holds');

      expect(await enMgr.ensureHousekeepingEnrollment(), isNull,
          reason: 'this atSign has been enrolled, so the key at '
              'at_pkam_publickey is not a credential it authenticated with '
              'before any enrollment existed');
      expect(await storedH(), isNull,
          reason: 'and no unexpiring root was minted for the flat key');
    });

    test('ARM 2: the SAME enrollment, ttl elapsed, refuses it too', () async {
      // Identical to ARM 1 but for one line. The gate used to read the
      // VISIBLE roster, so this arm found an empty one and minted `primary`
      // at `*:rw` + `__manage:rw`, with no approver and no expiry, for
      // whoever held the flat key — an atSign could be walked into that state
      // by doing nothing at all except waiting for an enrollment to expire.
      final String holder =
          await enrollmentHolding('a keypair the app holds', appName: 'holder');
      await seedLegacyKey('a keypair the app holds');
      await elapseTtlOf(holder);

      expect(await enMgr.ensureHousekeepingEnrollment(), isNull,
          reason: 'the record is still on disk, so this atSign HAS been '
              'enrolled — a roster that empties by expiry is a roster an '
              'enrollment holder can empty on a schedule it chose');
      expect(await storedH(), isNull,
          reason: 'and no unexpiring root was minted for the flat key');
    });

    test('an elapsed enrollment keeps its encryption keys until it is reaped',
        () async {
      // `removeOrphanedApkamEncryptionKeys` deletes the per-enrollment
      // encryption keys of enrollments that no longer exist. ORPHANED has to
      // mean "no record holds it": read off the visible roster, this deleted
      // the keys of a record that was still on disk, ahead of the expiry
      // sweep — which removes them itself, through the pre-remove hook, as
      // part of removing the record.
      final String holder = await enrollmentHolding('k', appName: 'holder');
      final String pek = enMgr.keyForPEK(holder);
      final String sek = enMgr.keyForSEK(holder);
      await keyValueStore.put(pek, AtData()..data = 'pek', skipCommit: true);
      await keyValueStore.put(sek, AtData()..data = 'sek', skipCommit: true);
      await elapseTtlOf(holder);

      expect(await enMgr.removeOrphanedApkamEncryptionKeys(), isEmpty,
          reason: 'ORPHANED means no record holds it, and a record whose ttl '
              'has elapsed is still a record that holds it — the expiry sweep '
              'removes these itself, through the pre-remove hook, as part of '
              'removing the record');
      expect(await keyValueStore.exists(pek), isTrue,
          reason: 'the record that owns it is still on disk');
      expect(await keyValueStore.exists(sek), isTrue,
          reason: 'the record that owns them is still there');
    });

    test('...while a genuinely orphaned pair still goes', () async {
      // The control, and it is what stops the case above being satisfied by a
      // sweep that has stopped deleting anything.
      final String pek = enMgr.keyForPEK('no-such-enrollment');
      await keyValueStore.put(pek, AtData()..data = 'pek', skipCommit: true);

      expect(await enMgr.removeOrphanedApkamEncryptionKeys(), contains(pek),
          reason: 'no record has ever held this one, which is what orphaned '
              'means');
      expect(await keyValueStore.exists(pek), isFalse,
          reason: 'and the sweep really does still delete');
    });

    test('the app/device leak is repaired for an elapsed enrollment too',
        () async {
      // `removeLegacyApkamPublicKeys` is the atSign's only repair for the
      // public key an older server published under the app and device names.
      // Nothing else ever revisits one: the pre-remove hook does not take it,
      // so an enrollment skipped here because its ttl had elapsed is reaped
      // and leaves its names published for the life of the atSign.
      final String holder =
          await enrollmentHolding('k', appName: 'leaky', deviceName: 'device');
      final String leak = enMgr.keyForLegacyPK(
          await enMgr.getEnrollmentById(holder));
      await keyValueStore.put(leak, AtData()..data = 'pk', skipCommit: true);
      await elapseTtlOf(holder);

      expect(await enMgr.removeLegacyApkamPublicKeys(),
          contains(enMgr.buildEnrollmentKey(holder)),
          reason: 'the elapsed record is still the only thing that names the '
              'app and device this key was published under');
      expect(await keyValueStore.exists(leak), isFalse,
          reason: 'read off the visible roster this record was never reached, '
              'and the sweep that removes it takes nothing with it');
    });

    test('enroll:list reports the VISIBLE roster', () async {
      // The one caller that takes the visible view, pinned because it is a
      // WIRE answer: `enroll:list` REPORTS a roster, it decides nothing, and
      // listing a record the keystore has stopped serving would make the
      // response depend on how recently the expiry sweep happened to run.
      await etu.initPrimaryEnrollment();
      final String live = await enrollmentHolding('k1', appName: 'live-app');
      final String elapsed =
          await enrollmentHolding('k2', appName: 'elapsed-app');
      await elapseTtlOf(elapsed);

      inboundConnection.metaData
        ..isAuthenticated = true
        ..enrollmentId = etu.primaryEnId;
      final Response r = Response();
      await etu.evh.processVerb(
          r, getVerbParam(VerbSyntax.enroll, 'enroll:list'), inboundConnection);
      final Map listed = jsonDecode(r.data!);

      expect(listed.keys, contains(enMgr.buildEnrollmentKey(live)),
          reason: 'the control: the roster really is populated, so the '
              'absence below is about the elapsed record and not about a '
              'response that lists nothing');
      expect(listed.keys, isNot(contains(enMgr.buildEnrollmentKey(elapsed))),
          reason: 'a record the keystore has stopped serving is one this '
              'atSign has finished with — including it would put a row on '
              'the wire whose presence depends on sweep timing');
    });

    test('a cascade reaches a descendant whose ttl has elapsed', () async {
      await etu.initPrimaryEnrollment();
      final String child = await etu.createPendingEnrollment(
          appName: 'child',
          deviceName: 'device',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null);
      await etu.approveEnrollment(etu.primaryEnId, child);

      expect(await enMgr.descendantsOf(etu.primaryEnId), contains(child),
          reason: 'precondition: it is a descendant while it is live');

      await elapseTtlOf(child);

      expect(await enMgr.descendantsOf(etu.primaryEnId), contains(child),
          reason: 'every status is followed — the climb already reads through '
              'an elapsed record, and the candidate enumeration has to as '
              'well, or a record still holding its published `_apsk` at the '
              'approved address sits outside the cascade');
    });
  });

  // =====================================================================
  // Startup adoption: the atSign's EXISTING legacy credential.
  // =====================================================================

  group('startup adoption of the legacy credential', () {
    test('UPGRADE: enrollments present, key present, no primary', () async {
      // The population this exists for, end to end. Every atSign that has
      // ever enrolled an app is in this state on the day it upgrades:
      // enrollment records, a working legacy keyfile, and no `primary`.
      // Refusing it strands the atSign with no route back — `otp:get` needs
      // an authenticated connection, a self-retrofit may not ask for `*`, and
      // the CRAM secret is long gone.
      final mlDsa = await MlDsa65PureDartAlgo().generateKeyPair();
      await seedLegacyKey(base64Encode(mlDsa.publicKey));
      await etu.initPrimaryEnrollment();
      await enrollmentHolding('some app\'s own key', appName: 'an-app');
      expect(await storedH(), isNull, reason: 'precondition: no primary');
      expect(await enMgr.getAllEnrollmentKeys(includeExpired: true),
          hasLength(2),
          reason: 'precondition: the store is populated, which is exactly '
              'what the lazy mint refuses');

      final adopted = await enMgr.adoptLegacyCredential();

      expect(adopted, isNotNull, reason: 'the identity is minted at startup');
      final r = await authenticateLegacy(keyPair: mlDsa);
      expect(r.data, 'success', reason: '${r.errorMessage}');
      expect(inboundConnection.metaData.enrollmentId,
          EnrollmentManager.housekeepingEnrollmentId,
          reason: 'and the connection carries the identity it was adopted as');
    });

    test('...and WITHOUT adoption that same atSign is refused', () async {
      // The control for the case above, and the measurement of what the
      // ruling actually changes: identical fixture, adoption not run, and the
      // valid keyfile of an ordinary upgraded atSign cannot authenticate.
      final mlDsa = await MlDsa65PureDartAlgo().generateKeyPair();
      await seedLegacyKey(base64Encode(mlDsa.publicKey));
      await etu.initPrimaryEnrollment();
      await enrollmentHolding('some app\'s own key', appName: 'an-app');

      await expectLater(
          () => authenticateLegacy(keyPair: mlDsa),
          throwsA(isA<UnAuthenticatedException>().having((e) => e.message,
              'message', contains('no usable legacy PKAM credential'))),
          reason: 'the signature is GOOD and the keyfile is the atSign\'s '
              'own; only the missing identity stands between it and its own '
              'atSign');
    });

    test('the adopted record is the record the lazy mint would have made',
        () async {
      // One shape, whichever path made it. A record carrying which path
      // minted it would be a difference nothing reads, and every downstream
      // guard would then have to allow for two.
      await etu.initPrimaryEnrollment();
      await enMgr.adoptLegacyCredential();

      final h = (await storedH())!;
      expect(h.approval?.state, EnrollmentStatus.approved.name,
          reason: 'it stands for a credential that already works');
      expect(h.namespaces, {
        EnrollmentConstants.allNamespaces: 'rw',
        EnrollmentConstants.enrollManageNamespace: 'rw',
      }, reason: 'the credential the atSign was onboarded with has always had '
          'unrestricted access; stating that is the point of the record');
      expect(h.apkamPublicKey, isEmpty,
          reason: 'an IDENTITY for the legacy credential, never a copy of it');
      expect(h.approvedByEnrollmentId, isNull,
          reason: 'nothing admitted it, so no cascade can reach it');
      expect((await keyValueStore.get(hKey()))?.metaData?.expiresAt, isNull,
          reason: 'only the retrofit cap may ever put a clock on it');
    });

    test('VESTIGIAL: a key that is an enrollment\'s own APKAM key is refused',
        () async {
      // The one thing startup still has to decide. Older servers' CRAM
      // auto-approve branch wrote the enrolling app's APKAM key into
      // `at_pkam_publickey` "for old clients", and adopting that copy would
      // give one keypair two identities with separate lifecycles — revoking
      // the enrollment would leave the same key authenticating over the
      // legacy path, unexpiring and with no approver.
      const String appsOwn = 'the enrolling app\'s own APKAM key';
      final String app = await enrollmentHolding(appsOwn, appName: 'an-app');
      await seedLegacyKey(appsOwn);

      expect(await enMgr.adoptLegacyCredential(), isNull,
          reason: 'refused: enrollment $app already holds this keypair');
      expect(await storedH(), isNull,
          reason: 'and nothing was written — a null return that minted the '
              'record anyway would grant the identity regardless');
      expect(await keyValueStore.exists(AtConstants.atPkamPublicKey), isTrue,
          reason: 'declining is a REFUSAL, not a repair — this server cannot '
              'tell such a copy from a credential an owner provisioned with a '
              'keypair it also enrolled');
    });

    test('...while a key NO enrollment holds is adopted', () async {
      // The control, and it is what stops the refusal above being satisfied
      // by adoption never minting on a populated store. The same store, the
      // same call, differing only in whether an enrollment holds the key.
      await enrollmentHolding('the enrolling app\'s own APKAM key',
          appName: 'an-app');
      await seedLegacyKey('a key no enrollment holds');

      expect(await enMgr.adoptLegacyCredential(), isNotNull,
          reason: 'a populated store is NOT what adoption refuses — only a '
              'key some enrollment already holds is');
      expect(await storedH(), isNotNull);
    });

    test('the vestigial check sees an enrollment whose ttl has elapsed',
        () async {
      // Fix (2) reaching the decision this ruling rests on. The holder's
      // record is invisible to `getKeys` and still on disk, which is the
      // state every enrollment passes through on its way out.
      const String appsOwn = 'the enrolling app\'s own APKAM key';
      final String app = await enrollmentHolding(appsOwn, appName: 'an-app');
      await seedLegacyKey(appsOwn);
      await elapseTtlOf(app);

      expect(await enMgr.adoptLegacyCredential(), isNull,
          reason: 'the record still says whose keypair this is');
      expect(await storedH(), isNull,
          reason: 'and no unexpiring root was minted for the app\'s keypair');
    });

    test('THE SLOT: running after the expiry sweep adopts what it refuses',
        () async {
      // Why adoption is placed BEFORE `deleteExpiredKeys()` in the server's
      // start(). One store, one variable — the order of the two calls.
      //
      // The sweep DESTROYS the evidence adoption reads: it removes the
      // elapsed record, and the pre-remove hook takes `at_pkam_publickey`
      // only for `primary`, so removing any OTHER enrollment leaves the flat
      // key behind with nothing left to identify it by.
      Future<void> arrange() async {
        const String appsOwn = 'the enrolling app\'s own APKAM key';
        final String app = await enrollmentHolding(appsOwn, appName: 'an-app');
        await seedLegacyKey(appsOwn);
        await elapseTtlOf(app);
      }

      // ARM 1 — the order start() uses.
      await arrange();
      expect(await enMgr.adoptLegacyCredential(), isNull,
          reason: 'the record is still there to be recognised');
      await keyValueStore.deleteExpiredKeys();
      expect(await storedH(), isNull);

      // Back to the same starting state for ARM 2. The refusal above wrote
      // nothing, so only the reaped record and the key need restoring.
      await keyValueStore.remove(hKey(), skipCommit: true);
      await arrange();

      // ARM 2 — the two calls the other way round.
      await keyValueStore.deleteExpiredKeys();
      expect(await enMgr.getAllEnrollmentKeys(includeExpired: true), isEmpty,
          reason: 'the sweep took the only record that named this keypair');
      expect(await enMgr.adoptLegacyCredential(), isNotNull,
          reason: 'and with it gone the same key is adopted: an unexpiring, '
              'no-approver root for the app that enrolled. THIS is what the '
              'slot buys, and it is why adoption may not be moved below the '
              'sweep');
    });

    test('THE SLOT, as start() actually runs it', () async {
      // The test above shows the ORDER matters. This one shows the server
      // uses the right one, by running the same sequence start() runs —
      // `AtSecondaryServerImpl.prepareStoreForFirstConnection`, which exists
      // so that this ordering is a thing something executes rather than three
      // adjacent statements nobody drives. start() itself goes on to bind a
      // socket, so no test reaches past it.
      const String appsOwn = 'the enrolling app\'s own APKAM key';
      final String app = await enrollmentHolding(appsOwn, appName: 'an-app');
      await seedLegacyKey(appsOwn);
      final String live = 'public:_apsk.$app'
          '.${EnrollmentConstants.perEnrollmentApproved}$alice';
      final String parked = 'public:_apsk.$app'
          '.${EnrollmentConstants.perEnrollmentDeleted}$alice';
      await keyValueStore.put(live, AtData()..data = 'its signing key',
          skipCommit: true);
      await elapseTtlOf(app);

      // As start() finds it: the hook is registered by the pass itself.
      keyValueStore.preRemoveHooks.clear();

      await atServer.prepareStoreForFirstConnection();

      expect(await storedH(), isNull,
          reason: 'the pass reads the vestigial evidence BEFORE the sweep '
              'destroys it — reordered, this atSign gets an unexpiring, '
              'no-approver root for the app that enrolled');
      expect(
          await keyValueStore.exists(enMgr.buildEnrollmentKey(app)), isFalse,
          reason: 'and the sweep really did run: without this the assertion '
              'above is satisfied by a pass that stopped after adoption');
      expect(await keyValueStore.exists(parked), isTrue,
          reason: 'and the hook was registered BEFORE the sweep, so the '
              'record it removed took its published signing key out of the '
              'address a verifier reads. Registered after, the sweep removes '
              'the record and leaves that key resolving at the live address '
              'for good — nothing walks it again');
      expect(await keyValueStore.exists(live), isFalse);
    });

    test('...and that same pass adopts when there is nothing against it',
        () async {
      // The control for the slot test: the pass is not simply one that never
      // adopts. Same call, same sweep, a key no enrollment holds.
      await etu.initPrimaryEnrollment();
      await seedLegacyKey('a key no enrollment holds');
      keyValueStore.preRemoveHooks.clear();

      await atServer.prepareStoreForFirstConnection();

      expect(await storedH(), isNotNull,
          reason: 'an upgrading atSign gets its identity from this pass');
    });

    test('an atSign that already has the identity is left alone', () async {
      await enMgr.ensureHousekeepingEnrollment();
      final String sessionBefore = (await storedH())!.sessionId;
      final int writesBefore = EnrollmentManager.cacheInvalidations;

      expect(await enMgr.adoptLegacyCredential(), isNull,
          reason: 'null means THIS CALL minted nothing, not that the atSign '
              'has no identity');
      expect((await storedH())!.sessionId, sessionBefore);
      expect(EnrollmentManager.cacheInvalidations, writesBefore,
          reason: 'every enrollment write bumps this counter, and a restart '
              'must not be a write');
    });

    test('a REVOKED identity is not restored by restarting', () async {
      await enMgr.ensureHousekeepingEnrollment();
      await setHStatus(EnrollmentStatus.revoked);

      expect(await enMgr.adoptLegacyCredential(), isNull,
          reason: 'the record is PRESENT, whatever its state — adoption is a '
              'one-time act and must not re-mint over one');
      expect((await storedH())!.approval?.state, EnrollmentStatus.revoked.name,
          reason: 'revoking this record is the atSign\'s only way to withdraw '
              'the legacy credential; a restart that re-minted it would make '
              'the revocation last until the next deploy');
    });

    test('a RETIRED credential is not resurrected by restarting', () async {
      // Removing the record always takes `at_pkam_publickey` with it, so on a
      // retired atSign the record is absent AND the key is gone. Absence
      // alone says nothing; the missing key is what says retired.
      await keyValueStore.remove(AtConstants.atPkamPublicKey, skipCommit: true);

      expect(await enMgr.adoptLegacyCredential(), isNull,
          reason: 'the missing key is what says RETIRED, and re-minting would '
              'resurrect a credential the atSign has finished with');
      expect(await storedH(), isNull);
    });

    test('an EMPTY at_pkam_publickey is not adopted', () async {
      // PRESENCE is not the bar. Authentication refuses an empty public key
      // before it looks at any signature, so a record minted here would stand
      // over a credential nobody can authenticate with.
      await seedEmptyLegacyKey();

      expect(await enMgr.adoptLegacyCredential(), isNull,
          reason: 'PRESENCE is not the bar — a zero-length value is a '
              'credential nobody can authenticate with');
      expect(await storedH(), isNull);
    });

    test('an enrollment record that does not decode fails CLOSED', () async {
      // An unreadable record cannot be shown NOT to hold this key, and
      // adopting on the strength of one nobody could parse is how a vestigial
      // key becomes a permanent root. Declining leaves the atSign exactly
      // where it was — legacy authentication refused — which is the state it
      // is in before adoption runs at all.
      await keyValueStore.put(enMgr.buildEnrollmentKey('unreadable'),
          AtData()..data = 'not json at all',
          skipCommit: true);

      expect(await enMgr.adoptLegacyCredential(), isNull,
          reason: 'an unreadable record cannot be shown NOT to hold this key, '
              'and adopting on the strength of one nobody could parse is how '
              'a vestigial key becomes a permanent root');
      expect(await storedH(), isNull);
    });

    test('adoption is idempotent across restarts', () async {
      await etu.initPrimaryEnrollment();
      expect(await enMgr.adoptLegacyCredential(), isNotNull,
          reason: 'precondition: the first start adopts');
      final String sessionBefore = (await storedH())!.sessionId;

      expect(await enMgr.adoptLegacyCredential(), isNull,
          reason: 'and no later start mints again');
      expect(await enMgr.adoptLegacyCredential(), isNull);

      expect((await storedH())!.sessionId, sessionBefore,
          reason: 'the same record, not a fresh one per restart');
    });

    test('the log names which refusal it took', () async {
      // The caller of a refused legacy authentication is told one message for
      // every cause, so the manager's log is the only place the distinction
      // exists. It is what an operator arriving at an atSign that refuses its
      // own keyfile has to read.
      const String appsOwn = 'the enrolling app\'s own APKAM key';
      await enrollmentHolding(appsOwn, appName: 'an-app');
      await seedLegacyKey(appsOwn);

      final captured = <String>[];
      enMgr.logger.level = 'warning';
      final sub = enMgr.logger.logger.onRecord.listen((r) {
        if (r.level >= logging.Level.WARNING) captured.add(r.message);
      });
      try {
        await enMgr.adoptLegacyCredential();
      } finally {
        await sub.cancel();
        enMgr.logger.level = AtSignLogger.root_level;
      }

      final line = captured.singleWhere(
          (r) => r.startsWith('Not adopting a legacy PKAM credential'),
          orElse: () => fail('nothing said why: $captured'));
      expect(line, contains('own APKAM credential'),
          reason: 'an operator reading this has to be able to tell the '
              'vestigial refusal from a retired credential, which is the '
              'other reason adoption declines');
      expect(line, contains(AtConstants.atPkamPublicKey),
          reason: 'it names the key it is refusing to adopt');
      expect(line, contains('enrollment id'),
          reason: 'and the remedy — that app authenticates with its own id');
    });
  });
  /// Admitting a connection is a read-decide-write whose write is the
  /// connection's IDENTITY, so it belongs in the atSign's one
  /// enrollment-mutation critical section for the same reason every act that
  /// writes a record does.
  ///
  /// Taken outside it, an `enroll:revoke` landing between the read of the
  /// enrollment and the marking of the connection is answered `success`: the
  /// revoke sweeps open connections by the enrollment id each one CARRIES, and
  /// a connection still being authenticated has not been given one, so the
  /// sweep passes over it.
  ///
  /// Observed by HOLDING the section rather than by racing something against
  /// it: whether a race lands in the gap between the read and the marking
  /// depends on how many awaits each side happens to take, which is not a
  /// property of the code under test. Each hold has a LATENCY CONTROL — the
  /// identical act with nothing holding the section, which must have been
  /// admitted inside the same window. Without it, "not admitted" is equally
  /// satisfied by an authentication that never got that far.
  group('admitting a connection is inside the enrollment-mutation section',
      () {
    /// How long a HELD case waits before reading the connection, and how long
    /// its latency control gives the same act to finish unobstructed. Ample
    /// for a keypair that is generated once per test and reused, which is what
    /// the control measures rather than assumes.
    const Duration holdWindow = Duration(milliseconds: 300);

    /// Takes the section and holds it until the returned completer is
    /// completed. Complete the gate and await the holder, or the section is
    /// still held when the test ends.
    (Completer<void>, Future<void>) holdTheSection() {
      final gate = Completer<void>();
      return (gate, enMgr.serialiseMutation(() => gate.future));
    }

    /// Writes [state] onto the housekeeping record directly.
    ///
    /// Deliberately not `enroll:revoke`: that verb takes the section itself,
    /// so it could not land WHILE the section is held, which is the moment
    /// under test. Through [EnrollmentManager.put] rather than the keystore,
    /// so the enrollment cache goes with it — otherwise the re-read under
    /// test would answer from before this write and the test would pass
    /// whatever the handler did.
    Future<void> setHousekeepingState(String state) async {
      final EnrollDataStoreValue value = (await storedH())!;
      value.approval!.state = state;
      await enMgr.put(EnrollmentManager.housekeepingEnrollmentId,
          AtData()..data = jsonEncode(value.toJson()),
          EnrollmentStatus.values.byName(state));
    }

    test('a legacy authentication is not marked while another mutation holds '
        'the section', () async {
      final pair = await MlDsa65PureDartAlgo().generateKeyPair();
      expect(
          (await authenticateLegacy(sessionId: 'mint', keyPair: pair)).data,
          'success',
          reason: 'precondition: the housekeeping record now exists, so what '
              'is measured below is the admission and not the mint');

      final (gate, holder) = holdTheSection();
      final authenticating =
          authenticateLegacy(sessionId: 'held', keyPair: pair);
      await Future<void>.delayed(holdWindow);
      final bool markedDuringHold = inboundConnection.metaData.isAuthenticated;
      final String? idDuringHold = inboundConnection.metaData.enrollmentId;

      gate.complete();
      final Response r = await authenticating;
      await holder;

      expect(markedDuringHold, isFalse,
          reason: 'the connection must not be marked authenticated on a state '
              'another mutation is in the middle of changing');
      expect(idDuringHold, isNull,
          reason: 'and it must not be carrying the enrollment id yet either — '
              'a revoke sweeps open connections by the id each one carries, '
              'so an id set on a half-admitted connection is the only thing '
              'that sweep can see');
      expect(r.data, 'success',
          reason: 'and it is admitted once the section is free — otherwise '
              'this would be measuring an authentication that simply never '
              'ran');
    });

    test('LATENCY CONTROL: unobstructed, the same authentication is marked '
        'inside the same window', () async {
      final pair = await MlDsa65PureDartAlgo().generateKeyPair();
      expect(
          (await authenticateLegacy(sessionId: 'mint', keyPair: pair)).data,
          'success');

      final authenticating =
          authenticateLegacy(sessionId: 'unobstructed', keyPair: pair);
      await Future<void>.delayed(holdWindow);
      final bool markedDuringWindow =
          inboundConnection.metaData.isAuthenticated;
      await authenticating;

      expect(markedDuringWindow, isTrue,
          reason: 'the window is ample for the act, so "not marked" above is '
              'a statement about the section rather than about latency — and '
              'this needs no serialisation, so it stays green when the '
              'critical section is removed');
    });

    test('a legacy authentication is refused on the state a mutation left '
        'while it waited', () async {
      final pair = await MlDsa65PureDartAlgo().generateKeyPair();
      expect(
          (await authenticateLegacy(sessionId: 'mint', keyPair: pair)).data,
          'success',
          reason: 'precondition: this credential authenticates while its '
              'record is approved');

      final (gate, holder) = holdTheSection();
      final authenticating =
          authenticateLegacy(sessionId: 'raced', keyPair: pair);
      await Future<void>.delayed(holdWindow);
      await setHousekeepingState(EnrollmentStatus.revoked.name);

      gate.complete();
      Object? refusal;
      try {
        await authenticating;
      } catch (e) {
        refusal = e;
      }
      await holder;

      expect(refusal, isA<UnAuthenticatedException>(),
          reason: 'the authentication read the record before it waited; it '
              'must decide on the record as it is when it is let through, or '
              'a credential revoked in that window is answered success and '
              'the revoke\'s connection sweep never saw the connection to '
              'close it');
      expect('$refusal', contains(EnrollmentStatus.revoked.name),
          reason: 'and it names the state it refused on');
      expect(inboundConnection.metaData.isAuthenticated, isFalse,
          reason: 'and the connection is left unauthenticated');
    });

    test('SERIAL CONTROL: with nothing holding the section, the same revoked '
        'record refuses the same authentication', () async {
      // Drawn from a property the section does not touch: a record that is
      // already revoked when the authentication starts is refused by the
      // FIRST read, so this stays green when the critical section is removed.
      final pair = await MlDsa65PureDartAlgo().generateKeyPair();
      expect(
          (await authenticateLegacy(sessionId: 'mint', keyPair: pair)).data,
          'success');
      await setHousekeepingState(EnrollmentStatus.revoked.name);

      Object? refusal;
      try {
        await authenticateLegacy(sessionId: 'serial', keyPair: pair);
      } catch (e) {
        refusal = e;
      }

      expect(refusal, isA<UnAuthenticatedException>(),
          reason: 'a revoked legacy credential does not authenticate — this '
              'is the refusal the raced case has to reproduce');
      expect('$refusal', contains(EnrollmentStatus.revoked.name));
    });

    test('an APKAM authentication is refused on the state a mutation left '
        'while it waited', () async {
      // The same window, on the branch that reads an enrollment record of its
      // own. Its first read is where the public key comes from, so it happens
      // before the signature is verified — the longest step on the path — and
      // the state it read is the state from before all of it.
      final AtPkamKeyPair pair = AtChopsUtil.generateAtPkamKeyPair();
      const String enId = 'apkam-admission';
      final EnrollDataStoreValue value = EnrollDataStoreValue(
          'session', 'app', 'device', pair.atPublicKey.publicKey)
        ..namespaces = {'wavi': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      await enMgr.put(enId, AtData()..data = jsonEncode(value.toJson()),
          EnrollmentStatus.approved);

      Future<Response> apkam(String sessionId) async {
        final challenge = 'challenge-$sessionId';
        await keyValueStore.put(
            'private:$sessionId$alice', AtData()..data = challenge);
        inboundConnection.metaData
          ..isAuthenticated = false
          ..enrollmentId = null
          ..sessionID = sessionId;
        final signature = AtChopsImpl(AtChopsKeys.create(null, pair))
            .sign(AtSigningInput('$sessionId$alice:$challenge')
              ..signingAlgoType = SigningAlgoType.rsa2048
              ..hashingAlgoType = HashingAlgoType.sha256
              ..signingMode = AtSigningMode.pkam)
            .result;
        final r = Response();
        await PkamVerbHandler(keyValueStore).processVerb(
          r,
          getVerbParam(
              VerbSyntax.pkam, 'pkam:enrollmentId:$enId:$signature'),
          inboundConnection,
        );
        return r;
      }

      expect((await apkam('control')).data, 'success',
          reason: 'precondition: this keypair IS the enrollment\'s credential '
              'and authenticates with it while the record is approved');

      final (gate, holder) = holdTheSection();
      final authenticating = apkam('raced');
      await Future<void>.delayed(holdWindow);
      value.approval!.state = EnrollmentStatus.revoked.name;
      await enMgr.put(enId, AtData()..data = jsonEncode(value.toJson()),
          EnrollmentStatus.revoked);

      gate.complete();
      final Response r = await authenticating;
      await holder;

      expect(r.isError, isTrue,
          reason: 'the enrollment stopped serving while the signature was '
              'being verified, so the answer must be the refusal, not the '
              'state read before the wait');
      expect(r.errorCode, 'AT0027',
          reason: 'and code for code the refusal it would have been given had '
              'it connected a moment later');
      expect(inboundConnection.metaData.isAuthenticated, isFalse,
          reason: 'and the connection carries no authentication');
    });
  });
}
