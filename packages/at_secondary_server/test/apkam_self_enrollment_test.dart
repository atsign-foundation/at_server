import 'dart:collection';

import 'dart:convert';

import 'dart:typed_data';

import 'package:at_chops/at_chops.dart'
    show AtChopsUtil, HashingAlgoType, MlDsa65PureDartAlgo, PkamSigningAlgo;
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/verb/handler/pkam_verb_handler.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/enroll/enrollment_revocation_event.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';

import 'enrollment_test_utils.dart';
import 'test_utils.dart';

/// An APKAM-authenticated connection retrofits itself: it enrols a FRESH
/// enrollment that REPLACES the one it authenticated as.
///
/// A keyfile upgrades itself with no human step and no OTP, the connection's
/// existing approved enrollment being the whole authority. Three properties
/// make that safe rather than a privilege-escalation verb:
///
/// - **The successor carries the predecessor's grants, exactly.** It replaces
///   rather than descends, so it does not choose them: a request may omit
///   `namespaces` and inherit, or state exactly them, and anything else is
///   refused. Asking for more is refused separately, with its own message, so
///   a caller can tell which mistake it made.
/// - **The predecessor survives, and is capped only once its replacement
///   proves itself.** The cap is armed by the successor's FIRST authentication,
///   because storing a successor proves only that the server wrote a record —
///   the private half lives client-side and may never have reached disk. It
///   re-arms per successor, so a predecessor retires one grace period after
///   the last sibling clone upgrades, never past its own key-expiry posture.
/// - **The successor records what it replaced**, which is what the retrofit
///   cap reads. Revocation does NOT follow that edge — it follows the approver
///   the successor inherits.
void main() {
  verbTestsSetUpLogging();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  final etu = ETU();

  setUp(() async {
    await verbTestsSetUp();
    await etu.init();
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  /// Issues `enroll:request` on an APKAM-authenticated connection carrying
  /// [predecessorId], with no OTP.
  /// [namespaces] is optional, mirroring the wire: a retrofit that omits it
  /// inherits its predecessor's grants, and one that states them must state
  /// exactly them.
  Future<Response> selfEnroll({
    required String predecessorId,
    Map<String, String>? namespaces,
    String appName = 'selfapp',
    String deviceName = 'selfdevice',
    String? signingAlgo,
    Duration? apkamKeysExpiryDuration,
    Map<String, dynamic>? apsk,
  }) async {
    final ep = EnrollParams()
      ..appName = appName
      ..deviceName = deviceName
      ..apkamPublicKey = 'pq apkam public key $appName $deviceName'
      ..signingAlgo = signingAlgo
      ..apkamKeysExpiryDuration = apkamKeysExpiryDuration
      ..apsk = apsk
      ..namespaces = namespaces;
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.apkam
      ..sessionID = DateTime.now().millisecondsSinceEpoch.toString();
    inboundConnection.metadata.enrollmentId = predecessorId;

    final r = Response();
    await etu.evh.processVerb(
      r,
      getVerbParam(
          VerbSyntax.enroll, 'enroll:request:${jsonEncode(ep.toJson())}'),
      inboundConnection,
    );
    return r;
  }

  /// A retrofit whose successor holds a REAL ML-DSA keypair, so it can then
  /// authenticate through the production PKAM handler. Returns the successor's
  /// id and the keypair to sign with.
  Future<(String, dynamic)> retrofitWithRealKey(
    String predecessorId, {
    String appName = 'rf-app',
    String deviceName = 'rf-device',
    Map<String, String>? namespaces,
    Duration? apkamKeysExpiryDuration,
  }) async {
    final mlDsa = await MlDsa65PureDartAlgo().generateKeyPair();
    final ep = EnrollParams()
      ..appName = appName
      ..deviceName = deviceName
      ..apkamPublicKey = base64Encode(mlDsa.publicKey)
      ..signingAlgo = 'mldsa65'
      ..apkamKeysExpiryDuration = apkamKeysExpiryDuration
      ..namespaces = namespaces;
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.apkam
      ..sessionID = DateTime.now().millisecondsSinceEpoch.toString();
    inboundConnection.metadata.enrollmentId = predecessorId;
    final r = Response();
    await etu.evh.processVerb(
      r,
      getVerbParam(
          VerbSyntax.enroll, 'enroll:request:${jsonEncode(ep.toJson())}'),
      inboundConnection,
    );
    expect(r.isError, false, reason: '${r.errorMessage}');
    return (jsonDecode(r.data!)['enrollmentId'] as String, mlDsa);
  }

  /// Authenticates as [enrollmentId] through the production PKAM handler,
  /// signing a fresh per-connection challenge with [mlDsa]'s secret half.
  ///
  /// [sessionId] must differ per call: the challenge is stored under it and
  /// consumed by a successful authentication.
  Future<void> authenticateAs(String enrollmentId, dynamic mlDsa,
      {String sessionId = 'arm-session'}) async {
    const challenge = 'a-per-connection-challenge';
    await keyValueStore.put(
        'private:$sessionId$alice', AtData()..data = challenge);
    final signature = await MlDsa65PureDartAlgo().signBytes(
        Uint8List.fromList(utf8.encode('$sessionId$alice:$challenge')),
        secretKey: mlDsa.secretKey);
    inboundConnection.metaData
      ..isAuthenticated = false
      ..sessionID = sessionId;
    final pr = Response();
    await PkamVerbHandler(keyValueStore).processVerb(
      pr,
      getVerbParam(
          VerbSyntax.pkam,
          'pkam:signingAlgo:mldsa65:enrollmentId:$enrollmentId:'
          '${base64Encode(signature)}'),
      inboundConnection,
    );
    expect(pr.data, 'success', reason: '${pr.errorMessage}');
  }

  test(
      'an approved enrollment is replaced by a successor holding its grants, '
      'no OTP', () async {
    // The predecessor: an ordinary approved enrollment with scoped grants.
    final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
    final predecessorBefore = await enMgr.getEnrollmentById(predecessorId);
    expect(predecessorBefore.namespaces, {'app_1': 'rw', 'test': 'r'},
        reason: 'precondition: the predecessor grants this test relies on');

    final r = await selfEnroll(
        predecessorId: predecessorId, namespaces: {'app_1': 'rw', 'test': 'r'});

    expect(r.isError, false, reason: '${r.errorMessage}');
    final m = jsonDecode(r.data!);
    expect(m['status'], EnrollmentStatus.approved.name,
        reason: 'auto-approved: no human step, no OTP — the authenticated '
            'predecessor is the authority');
    final successorId = m['enrollmentId'] as String;
    expect(successorId, isNot(predecessorId));

    final successor = await enMgr.getEnrollmentById(successorId);
    expect(successor.approval?.state, EnrollmentStatus.approved.name);
    expect(successor.parentEnrollmentId, predecessorId,
        reason: 'the successor records what it replaced, which is what the '
            'retrofit cap reads to know whose expiry to put a clock on. NOT '
            'for revocation: that follows the approver the successor '
            'inherits, never this edge');
    expect(successor.namespaces.containsKey('__manage'), isFalse,
        reason: 'auto-approve must NOT carry the CRAM branch\'s __manage/* '
            'grant — that grant is what makes CRAM the atSign\'s root, and a '
            'self-enrollment is not that');
    expect(successor.namespaces.containsKey('*'), isFalse);

    // The predecessor survives, and is NOT yet capped.
    final predecessorAfter = await enMgr.getEnrollmentById(predecessorId);
    expect(predecessorAfter.approval?.state, EnrollmentStatus.approved.name,
        reason: 'sibling clones of the same keyfile still authenticate as the '
            'predecessor until the cap elapses');
    final predecessorData =
        await keyValueStore.get(enMgr.buildEnrollmentKey(predecessorId));
    expect(predecessorData?.metaData?.expiresAt, isNull,
        reason: 'the cap is armed by the successor\'s first authentication, '
            'not by storing it. A successor whose keyfile write failed exists '
            'here and nowhere else, and starting a clock on the predecessor — '
            'by then the only credential that still works — on the strength '
            'of a record only this server has seen is exactly the hazard');
    expect(successor.predecessorCapArmedAt, isNull,
        reason: 'and the successor records that it has armed nothing yet');
  });

  test('escalation is refused: a namespace the predecessor does not hold', () async {
    final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;

    await expectLater(
        () => selfEnroll(
            predecessorId: predecessorId, namespaces: {'other_ns': 'rw'}),
        throwsA(isA<UnAuthorizedException>().having(
            (e) => e.message, 'message', contains('exceeds the predecessor'))),
        reason: 'a scoped keyfile must not self-spawn grants it never held');
  });

  test('escalation is refused: broader access letters on a held namespace',
      () async {
    final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
    // The predecessor holds test:'r'.

    await expectLater(
        () => selfEnroll(
            predecessorId: predecessorId, namespaces: {'test': 'rw'}),
        throwsA(isA<UnAuthorizedException>()),
        reason: 'r under rw fits; rw under r is an escalation — per letter, '
            'not merely per namespace');
  });

  test('escalation is refused: __manage via a wildcard predecessor', () async {
    // The primary enrollment holds *:rw (CRAM adds __manage too, but the
    // point here is that a * grant alone must never imply __manage).
    final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;

    await expectLater(
        () => selfEnroll(
            predecessorId: predecessorId, namespaces: {'__manage': 'rw'}),
        throwsA(isA<UnAuthorizedException>()),
        reason: '__manage must be held literally — * does not imply it '
            'anywhere else in the server, and must not here');
  });

  test('a wildcard predecessor is inherited verbatim, wildcard and all',
      () async {
    // The primary (CRAM) enrollment holds *:rw and __manage:rw.
    final r = await selfEnroll(predecessorId: etu.primaryEnId);

    expect(r.isError, false, reason: '${r.errorMessage}');
    final successor = await enMgr
        .getEnrollmentById(jsonDecode(r.data!)['enrollmentId'] as String);
    expect(successor.namespaces, {'*': 'rw', '__manage': 'rw'},
        reason: 'a retrofit replaces its predecessor, so it carries those '
            'grants exactly — __manage included, which is what leaves the '
            'atSign able to approve a replacement once the predecessor is '
            'capped');
  });

  test('naming a subset of a wildcard predecessor is refused', () async {
    // A * predecessor used to be able to grant any ordinary namespace at its
    // letters, so this succeeded and produced a successor that could not do
    // what the enrollment it replaced could.
    await expectLater(
        () => selfEnroll(
            predecessorId: etu.primaryEnId,
            namespaces: {'brand_new_ns': 'rw', '__manage': 'rw'}),
        throwsA(isA<UnAuthorizedException>()
            .having((e) => e.message, 'message', contains('carries its grants'))),
        reason: 'a successor holding less than its predecessor is a silent '
            'downgrade — it fails at the next thing the app does, far from '
            'the request that caused it');
  });

  test('a retrofit may keep its own (appName, deviceName)', () async {
    final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
    final predecessor = await enMgr.getEnrollmentById(predecessorId);

    final r = await selfEnroll(
        predecessorId: predecessorId,
        appName: predecessor.appName,
        deviceName: predecessor.deviceName);

    expect(r.isError, false,
        reason: 'a retrofit is the same app re-enrolling itself, and sibling '
            'clones of one keyfile share names — the (appName, deviceName) '
            'duplicate refusal must not apply to the self-enrollment branch: '
            '${r.errorMessage}');
    final successorId = jsonDecode(r.data!)['enrollmentId'] as String;
    expect(successorId, isNot(predecessorId));
    expect((await enMgr.getEnrollmentById(successorId)).approval?.state,
        EnrollmentStatus.approved.name);
  });

  test('an omitted namespaces map inherits the predecessor\'s grants',
      () async {
    final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;

    final r = await selfEnroll(predecessorId: predecessorId);

    expect(r.isError, false, reason: '${r.errorMessage}');
    final successor = await enMgr
        .getEnrollmentById(jsonDecode(r.data!)['enrollmentId'] as String);
    expect(successor.namespaces, {'app_1': 'rw', 'test': 'r'},
        reason: 'a retrofit does not choose its grants, so it need not state '
            'them — and a caller that cannot read its predecessor\'s record '
            'could not state them correctly anyway');
  });

  test('an empty namespaces map inherits too, rather than being refused',
      () async {
    final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;

    final r = await selfEnroll(predecessorId: predecessorId, namespaces: {});

    expect(r.isError, false, reason: '${r.errorMessage}');
    final successor = await enMgr
        .getEnrollmentById(jsonDecode(r.data!)['enrollmentId'] as String);
    expect(successor.namespaces, {'app_1': 'rw', 'test': 'r'},
        reason: 'an empty map states nothing, and stating nothing is how a '
            'request asks to inherit');
  });

  test(
      'the cap re-arms on each sibling\'s first authentication rather than '
      'keeping the first deadline', () async {
    final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
    final (firstId, firstKey) = await retrofitWithRealKey(predecessorId,
        appName: 'sib1', deviceName: 'sib1-device');
    await authenticateAs(firstId, firstKey, sessionId: 'sib1-session');

    // Simulate that first retrofit having happened long ago by shrinking the
    // predecessor's remaining ttl directly.
    final key = enMgr.buildEnrollmentKey(predecessorId);
    final aged = await keyValueStore.get(key);
    aged!.metaData!.ttl = 60000;
    await enMgr.put(predecessorId, aged, EnrollmentStatus.approved);

    final (secondId, secondKey) = await retrofitWithRealKey(predecessorId,
        appName: 'sib2', deviceName: 'sib2-device');
    await authenticateAs(secondId, secondKey, sessionId: 'sib2-session');

    final graceMillis =
        Duration(hours: AtSecondaryConfig.apkamSelfEnrollmentGraceHours)
            .inMilliseconds;
    final ttl = (await keyValueStore.get(key))!.metaData!.ttl!;
    expect(ttl, greaterThan(60000),
        reason: 'a min-fold against the previously capped ttl keeps the '
            'first sibling\'s deadline and strands every later one — the cap '
            'must re-arm to a full grace period from the moment the newest '
            'sibling proves itself');
    expect(ttl, lessThanOrEqualTo(graceMillis));
  });

  test(
      'the cap never extends past the expiry the predecessor\'s own posture '
      'imposes', () async {
    final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
    // Give the predecessor a key-expiry posture far shorter than the grace.
    final key = enMgr.buildEnrollmentKey(predecessorId);
    final atData = await keyValueStore.get(key);
    final value = EnrollDataStoreValue.fromJson(jsonDecode(atData!.data!));
    value.apkamKeysExpiryDuration = Duration(hours: 1);
    atData.data = jsonEncode(value.toJson());
    // Both halves, because that is what enroll:approve writes: the posture
    // into the value AND a ttl onto the record, from which the metadata
    // builder derives the expiry the record actually carries. Setting only
    // the value produces the CRAM shape — a posture the record never had —
    // which the fold deliberately ignores.
    atData.metaData!.ttl = Duration(hours: 1).inMilliseconds;
    await enMgr.put(predecessorId, atData, EnrollmentStatus.approved);

    // The successor must AUTHENTICATE, or no cap is armed at all and the
    // assertion below passes against an uncapped ttl of 0 — which is what an
    // earlier version of this test did, silently measuring nothing.
    final (successorId, successorKey) = await retrofitWithRealKey(predecessorId);
    await authenticateAs(successorId, successorKey, sessionId: 'posture-session');

    final ttl = (await keyValueStore.get(key))!.metaData!.ttl!;
    expect(ttl, greaterThan(0),
        reason: 'control: a cap was actually written, so the bound below is '
            'measuring the fold and not an uncapped record');
    expect(ttl, lessThanOrEqualTo(Duration(hours: 1).inMilliseconds),
        reason: 'the re-arm applies only within the enrollment\'s own '
            'key-expiry posture — a 1h apkamKeysExpiryDuration must not '
            'become a 30-day grace');
    expect(ttl, greaterThan(Duration(minutes: 55).inMilliseconds),
        reason: 'and it is the posture\'s REMAINING life, not an arbitrary '
            'smaller number: an upper bound alone is satisfied by any '
            'mistake that shortens the cap, including writing 1ms');
  });

  test('the successor record expires per the posture it inherited', () async {
    final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
    // The predecessor lives under a 1h key-expiry posture.
    final key = enMgr.buildEnrollmentKey(predecessorId);
    final atData = await keyValueStore.get(key);
    final value = EnrollDataStoreValue.fromJson(jsonDecode(atData!.data!));
    value.apkamKeysExpiryDuration = Duration(hours: 1);
    atData.data = jsonEncode(value.toJson());
    await enMgr.put(predecessorId, atData, EnrollmentStatus.approved);

    final r = await selfEnroll(
        predecessorId: predecessorId);
    expect(r.isError, false, reason: '${r.errorMessage}');
    final successorId = jsonDecode(r.data!)['enrollmentId'] as String;

    final successor = await enMgr.getEnrollmentById(successorId);
    expect(successor.apkamKeysExpiryDuration, Duration(hours: 1),
        reason: 'precondition: the inheritance itself, recorded in the value');

    final successorTtl =
        (await keyValueStore.get(enMgr.buildEnrollmentKey(successorId)))
            ?.metaData
            ?.ttl;
    expect(successorTtl, Duration(hours: 1).inMilliseconds,
        reason: 'the retrofit copies the predecessor\'s expiry to the successor — a '
            'posture recorded only in the JSON value while the record carries '
            'no ttl means the successor never physically expires, which turns a '
            '1h key-expiry policy into immortality for every retrofitted '
            'enrollment');
  });

  test('a successor expiry the request states wins over the inherited one',
      () async {
    final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;

    final r = await selfEnroll(
        predecessorId: predecessorId,
        apkamKeysExpiryDuration: Duration(hours: 2));
    expect(r.isError, false, reason: '${r.errorMessage}');
    final successorId = jsonDecode(r.data!)['enrollmentId'] as String;

    final successorTtl =
        (await keyValueStore.get(enMgr.buildEnrollmentKey(successorId)))
            ?.metaData
            ?.ttl;
    expect(successorTtl, Duration(hours: 2).inMilliseconds,
        reason: 'the request may state its own posture instead of inheriting '
            '— and the record must expire per whichever applied');

    // Control: a predecessor with no posture begets a successor with none — ttl 0 is
    // the keystore's "never expires", exactly what the ordinary approve
    // path writes for an enrollment without apkamKeysExpiryDuration.
    final r2 = await selfEnroll(
        predecessorId: predecessorId,
        appName: 'selfapp2',
        deviceName: 'selfdevice2');
    final successor2Id = jsonDecode(r2.data!)['enrollmentId'] as String;
    final successor2Ttl =
        (await keyValueStore.get(enMgr.buildEnrollmentKey(successor2Id)))
            ?.metaData
            ?.ttl;
    expect(successor2Ttl ?? 0, 0,
        reason: 'no posture anywhere must not manufacture an expiry');
  });

  test('a successor may not state an expiry that outlives its predecessor\'s posture',
      () async {
    final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
    final key = enMgr.buildEnrollmentKey(predecessorId);
    final atData = await keyValueStore.get(key);
    final value = EnrollDataStoreValue.fromJson(jsonDecode(atData!.data!));
    value.apkamKeysExpiryDuration = Duration(hours: 1);
    atData.data = jsonEncode(value.toJson());
    await enMgr.put(predecessorId, atData, EnrollmentStatus.approved);

    final r = await selfEnroll(
        predecessorId: predecessorId,
        apkamKeysExpiryDuration: Duration(days: 3650));
    expect(r.isError, false, reason: '${r.errorMessage}');
    final successorId = jsonDecode(r.data!)['enrollmentId'] as String;

    final successor = await enMgr.getEnrollmentById(successorId);
    expect(successor.apkamKeysExpiryDuration, Duration(hours: 1),
        reason: 'verifyNoEscalation covers namespaces; TIME is the other axis '
            'a stolen keyfile would widen, and this is the one enrollment '
            'path with no human in the loop to notice. A successor that outlives '
            'its predecessor defeats the very posture the predecessor was issued under');
    expect(
        (await keyValueStore.get(enMgr.buildEnrollmentKey(successorId)))
            ?.metaData
            ?.ttl,
        Duration(hours: 1).inMilliseconds);
  });

  test('a successor may not state "never expires" against a bounded predecessor',
      () async {
    final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
    final key = enMgr.buildEnrollmentKey(predecessorId);
    final atData = await keyValueStore.get(key);
    final value = EnrollDataStoreValue.fromJson(jsonDecode(atData!.data!));
    value.apkamKeysExpiryDuration = Duration(hours: 1);
    atData.data = jsonEncode(value.toJson());
    await enMgr.put(predecessorId, atData, EnrollmentStatus.approved);

    // Zero is the keystore's "never expires" — the most valuable thing a
    // thief could ask for, and the cheapest to ask for.
    final r = await selfEnroll(
        predecessorId: predecessorId,
        apkamKeysExpiryDuration: Duration.zero);
    expect(r.isError, false, reason: '${r.errorMessage}');
    final successorId = jsonDecode(r.data!)['enrollmentId'] as String;

    final successorTtl =
        (await keyValueStore.get(enMgr.buildEnrollmentKey(successorId)))
            ?.metaData
            ?.ttl;
    expect(successorTtl, Duration(hours: 1).inMilliseconds,
        reason: 'ttl 0 means never-expires at both layers (_getExpiresAt '
            'returns null), so honouring a stated zero against a time-bound '
            'predecessor hands out a permanent credential for the asking');
  });

  test('a negative stated expiry is not honoured', () async {
    final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;

    // A negative ttl skips the metadata builder's ttl >= 0 branch entirely,
    // leaving expiresAt null — immortality by a different route.
    final r = await selfEnroll(
        predecessorId: predecessorId,
        apkamKeysExpiryDuration: Duration(milliseconds: -1));
    expect(r.isError, false, reason: '${r.errorMessage}');
    final successorId = jsonDecode(r.data!)['enrollmentId'] as String;

    // The raw ttl, NOT `?? 0`: with the whole change reverted the successor
    // record carries no metadata at all, and a `?? 0` would read that absence
    // as a written zero and pass for the very state this pins against.
    final successorTtl =
        (await keyValueStore.get(enMgr.buildEnrollmentKey(successorId)))
            ?.metaData
            ?.ttl;
    expect(successorTtl, 0,
        reason: 'a negative posture is not a posture; it must fall back to '
            'the predecessor\'s (unbounded, written as 0) rather than reaching the '
            'keystore, where a negative ttl skips the expiry write entirely '
            'and leaves the record immortal');
  });

  test(
      'a self-enrollment publishes the apsk it composed, and none when it '
      'composes none', () async {
    final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;

    // The successor composes its own value. signingAlgo is set too and is
    // deliberately NOT what gets published: it is the record PKAM reads, and
    // the two are now independent.
    final composed = {
      'v': 1,
      'signingAlgo': 'mldsa65',
      'publicKey': 'cHEtYXBrYW0tcHVibGlj',
    };
    final r = await selfEnroll(
        predecessorId: predecessorId,
        signingAlgo: 'mldsa65',
        apsk: composed);
    expect(r.isError, false, reason: '${r.errorMessage}');
    final successorId = jsonDecode(r.data!)['enrollmentId'] as String;

    final successorApsk = (await keyValueStore.get(
            'public:_apsk.$successorId.'
            '${EnrollmentConstants.perEnrollmentApproved}$alice'))!
        .data!;
    expect(jsonDecode(successorApsk), composed,
        reason: 'the value is opaque, so it is published exactly as sent — '
            'not recomposed from the record\'s apkamPublicKey, which here is '
            'a different string entirely');

    // The record still carries the algorithm PKAM verifies under, unchanged
    // by any of this.
    expect((await enMgr.getEnrollmentById(successorId)).signingAlgo, 'mldsa65');

    // Control: a self-enrollment that sends no apsk gets no record. The
    // server does not fall back to composing one.
    final r2 = await selfEnroll(
        predecessorId: predecessorId,
        appName: 'selfapp2',
        deviceName: 'selfdevice2',
        signingAlgo: 'mldsa65');
    final successor2Id = jsonDecode(r2.data!)['enrollmentId'] as String;
    expect(
        await keyValueStore.exists(
            'public:_apsk.$successor2Id.'
            '${EnrollmentConstants.perEnrollmentApproved}$alice'),
        false);
  });

  test(
      'an mldsa65 self-enrollment then AUTHENTICATES with a genuine ML-DSA '
      'signature through the production verify dispatch', () async {
    // The first end-to-end ML-DSA PKAM in this package: earlier coverage
    // asserted record storage and enrollment status only, which is how a
    // resolved at_chops without an mldsa65 verification branch could sit
    // green while the live wire died in RSA ASN1 parsing of a raw ML-DSA
    // key (caught 2026-08-05 by the at_client_sdk retrofit live test).
    final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
    final mlDsa = await MlDsa65PureDartAlgo().generateKeyPair();

    final ep = EnrollParams()
      ..appName = 'mldsa-auth-app'
      ..deviceName = 'mldsa-auth-device'
      ..apkamPublicKey = base64Encode(mlDsa.publicKey)
      ..signingAlgo = 'mldsa65';
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.apkam
      ..sessionID = DateTime.now().millisecondsSinceEpoch.toString();
    inboundConnection.metadata.enrollmentId = predecessorId;
    final enrollResponse = Response();
    await etu.evh.processVerb(
      enrollResponse,
      getVerbParam(
          VerbSyntax.enroll, 'enroll:request:${jsonEncode(ep.toJson())}'),
      inboundConnection,
    );
    expect(enrollResponse.isError, false,
        reason: '${enrollResponse.errorMessage}');
    final successorId = jsonDecode(enrollResponse.data!)['enrollmentId'] as String;

    // Seed the challenge the from: verb would have stored, sign it with the
    // successor's ML-DSA secret key, and authenticate.
    const sessionId = 'mldsa-auth-session';
    const challenge = 'a-per-connection-challenge';
    await keyValueStore.put(
        'private:$sessionId$alice', AtData()..data = challenge);
    final signature = await MlDsa65PureDartAlgo().signBytes(
        Uint8List.fromList(utf8.encode('$sessionId$alice:$challenge')),
        secretKey: mlDsa.secretKey);

    inboundConnection.metaData
      ..isAuthenticated = false
      ..sessionID = sessionId;
    final pkamResponse = Response();
    await PkamVerbHandler(keyValueStore).processVerb(
      pkamResponse,
      getVerbParam(
          VerbSyntax.pkam,
          'pkam:signingAlgo:mldsa65:enrollmentId:$successorId:'
          '${base64Encode(signature)}'),
      inboundConnection,
    );

    expect(pkamResponse.isError, false, reason: '${pkamResponse.errorMessage}');
    expect(pkamResponse.data, 'success',
        reason: 'record-authoritative ML-DSA verification through the real '
            'at_chops dispatch — the whole point of the retrofit is that '
            'the new enrollment can authenticate');
    expect(inboundConnection.metaData.authType, AuthType.apkam);
    expect(inboundConnection.metadata.enrollmentId, successorId);

    // Control: a tampered signature must be refused, or the assertion above
    // proves routing rather than verification.
    await keyValueStore.put(
        'private:$sessionId$alice', AtData()..data = challenge);
    final tampered = Uint8List.fromList(signature)..[0] ^= 0xff;
    inboundConnection.metaData.isAuthenticated = false;
    await expectLater(
        () => PkamVerbHandler(keyValueStore).processVerb(
              Response(),
              getVerbParam(
                  VerbSyntax.pkam,
                  'pkam:signingAlgo:mldsa65:enrollmentId:$successorId:'
                  '${base64Encode(tampered)}'),
              inboundConnection,
            ),
        throwsA(isA<UnAuthenticatedException>()));
  });

  test(
      'an enrollment with NO recorded signingAlgo keeps the rsa2048 default '
      'even when the wire claims mldsa65', () async {
    // A legacy enrollment predates the signingAlgo field, so its record has
    // none — and record-authoritative means ABSENT resolves to the rsa2048
    // default, never to the wire claim. Before this was explicit, the null
    // fell through to the claim, which picked the verify routine for
    // exactly the enrollments that predate the field; the hole was masked
    // while at_chops had no mldsa65 routine to mis-pick.
    final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
    final rsaPair = AtChopsUtil.generateAtPkamKeyPair();

    final ep = EnrollParams()
      ..appName = 'legacy-claim-app'
      ..deviceName = 'legacy-claim-device'
      ..apkamPublicKey = rsaPair.atPublicKey.publicKey;
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.apkam
      ..sessionID = DateTime.now().millisecondsSinceEpoch.toString();
    inboundConnection.metadata.enrollmentId = predecessorId;
    final enrollResponse = Response();
    await etu.evh.processVerb(
      enrollResponse,
      getVerbParam(
          VerbSyntax.enroll, 'enroll:request:${jsonEncode(ep.toJson())}'),
      inboundConnection,
    );
    final successorId = jsonDecode(enrollResponse.data!)['enrollmentId'] as String;

    const sessionId = 'legacy-claim-session';
    const challenge = 'another-per-connection-challenge';
    await keyValueStore.put(
        'private:$sessionId$alice', AtData()..data = challenge);
    final signature = PkamSigningAlgo(rsaPair, HashingAlgoType.sha256)
        .sign(Uint8List.fromList(utf8.encode('$sessionId$alice:$challenge')));

    inboundConnection.metaData
      ..isAuthenticated = false
      ..sessionID = sessionId;
    final pkamResponse = Response();
    await PkamVerbHandler(keyValueStore).processVerb(
      pkamResponse,
      getVerbParam(
          VerbSyntax.pkam,
          'pkam:signingAlgo:mldsa65:enrollmentId:$successorId:'
          '${base64Encode(signature)}'),
      inboundConnection,
    );

    expect(pkamResponse.data, 'success',
        reason: 'the record decides: absent signingAlgo = the rsa2048 '
            'default, and the lying wire claim changes nothing — a legacy '
            'client must not be locked out by a claim it never made');
  });

  test('an unapproved predecessor is refused', () async {
    final pendingId = await etu.createPendingEnrollment(
        appName: 'pending_app',
        deviceName: 'pending_device',
        namespaces: {'app_x': 'rw'},
        apkamKeysExpiryDuration: null);

    await expectLater(
        () => selfEnroll(
            predecessorId: pendingId, namespaces: {'app_x': 'rw'}),
        throwsA(isA<UnAuthorizedException>()),
        reason: 'a pending enrollment cannot vouch for anything — only an '
            'approved predecessor is an authority');
  });

  group('a retrofit carries its predecessor\'s grants and does not choose them',
      () {
    test('a narrower request is refused, loudly', () async {
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;

      await expectLater(
          () => selfEnroll(
              predecessorId: predecessorId, namespaces: {'app_1': 'rw'}),
          throwsA(isA<UnAuthorizedException>().having(
              (e) => e.message, 'message', contains('carries its grants'))),
          reason: 'the predecessor holds app_1:rw AND test:r, so this asks '
              'for less. A successor that cannot do what it replaced is a '
              'loss that surfaces at the next thing the app does');
    });

    test('stating exactly the predecessor\'s grants is accepted', () async {
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;

      final r = await selfEnroll(
          predecessorId: predecessorId,
          namespaces: {'app_1': 'rw', 'test': 'r'});

      // The control for every refusal in this group: the rule is equality,
      // not a ban on naming grants at all.
      expect(r.isError, false, reason: '${r.errorMessage}');
    });

    test('a narrower access LETTER is refused at the same namespaces',
        () async {
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;

      await expectLater(
          () => selfEnroll(
              predecessorId: predecessorId,
              namespaces: {'app_1': 'r', 'test': 'r'}),
          throwsA(isA<UnAuthorizedException>()),
          reason: 'equality is per letter, not merely per namespace — app_1 '
              'drops from rw to r here while the namespace set matches');
    });

    test('an escalation keeps its own diagnosis', () async {
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;

      await expectLater(
          () => selfEnroll(
              predecessorId: predecessorId,
              namespaces: {'app_1': 'rw', 'test': 'r', 'other_ns': 'rw'}),
          throwsA(isA<UnAuthorizedException>().having(
              (e) => e.message, 'message', contains('exceeds the predecessor'))),
          reason: 'asking for MORE is a different mistake from asking for '
              'less, and a caller handed one message for both cannot tell '
              'which it made');
    });
  });

  /// The fold the cap writes, asserted directly.
  ///
  /// Through the arming path this is not cleanly measurable: shortening a
  /// deadline can trip the shorter-lived-successor guard instead, so a broken
  /// fold shows up as "no cap written" rather than as a wrong number.
  /// A retrofit is a ONCE-OFF: a device gets one no-approver migration, not a
  /// series. What follows from letting it repeat is the key-expiry clock: each
  /// link restarts it, so an enrollment with a one-hour term could retrofit
  /// itself every fifty-five minutes indefinitely and the posture would not be
  /// enforceable across a chain at all. (A lost link severing the revocation
  /// cascade was a second reason once; revocation travels the approval edge
  /// now, and a successor inherits its predecessor's approver, so losing a
  /// replacement link orphans nothing.)
  ///
  /// The guard is about DEPTH along the predecessor edge, never breadth — see
  /// the control below.
  /// Revocation cascades along the APPROVAL edge and NOT along the
  /// replacement edge. A retrofit produces a peer — the same principal
  /// re-keyed — so revoking a superseded credential must not take the one that
  /// superseded it, or an operator retiring an old key kills the device's
  /// current one.
  group('the cascade follows approval, not replacement', () {
    Future<Response> revokeAsPrimary(String targetId) async {
      inboundConnection.metaData
        ..isAuthenticated = true
        ..authType = AuthType.apkam;
      inboundConnection.metadata.enrollmentId = etu.primaryEnId;
      final r = Response();
      await etu.evh.processVerb(
          r,
          getVerbParam(VerbSyntax.enroll,
              'enroll:revoke:{"enrollmentId":"$targetId"}'),
          inboundConnection);
      return r;
    }

    test('enroll:approve records the enrollment that approved', () async {
      // The edge the cascade walks, written by the production path rather
      // than by a fixture. Without this the cascade tests stand entirely on
      // records the tests wrote themselves.
      final approverId = (await etu.createEnrollments(n: 1)).$1.first;
      final pendingId = await etu.createPendingEnrollment(
          appName: 'admitted-app',
          deviceName: 'admitted-device',
          namespaces: {'test': 'r'},
          apkamKeysExpiryDuration: null);
      await etu.approveEnrollment(etu.primaryEnId, pendingId);

      expect((await enMgr.getEnrollmentById(pendingId)).approvedByEnrollmentId,
          etu.primaryEnId,
          reason: 'read off the CONNECTION, so an approver cannot name '
              'somebody else as the admitting party');
      expect(
          (await enMgr.getEnrollmentById(approverId)).approvedByEnrollmentId,
          etu.primaryEnId,
          reason: 'control: the fixture\'s own enrollments carry it too, so '
              'the assertion above is not satisfied by a field nothing sets');
    });

    test('a retrofit INHERITS its predecessor\'s approver', () async {
      // The successor is a peer, so it stands where its predecessor stood.
      // Naming the predecessor instead — or leaving it null — would make a
      // retrofit an escape hatch: revoking the approver would reach the
      // predecessor and stop, while the successor went on authenticating.
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      final r = await selfEnroll(
          predecessorId: predecessorId,
          appName: 'inherit-app',
          deviceName: 'inherit-device');
      expect(r.isError, false, reason: '${r.errorMessage}');
      final successorId = jsonDecode(r.data!)['enrollmentId'] as String;

      final successor = await enMgr.getEnrollmentById(successorId);
      expect(successor.approvedByEnrollmentId, etu.primaryEnId,
          reason: 'whoever admitted the predecessor admitted this');
      expect(successor.parentEnrollmentId, predecessorId,
          reason: 'control: the replacement edge is still recorded, because '
              'the retrofit cap needs to know what it replaced');
    });

    test('revoking a predecessor does NOT revoke what replaced it', () async {
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      final r = await selfEnroll(
          predecessorId: predecessorId,
          appName: 'peer-app',
          deviceName: 'peer-device');
      expect(r.isError, false, reason: '${r.errorMessage}');
      final successorId = jsonDecode(r.data!)['enrollmentId'] as String;

      final rev = await revokeAsPrimary(predecessorId);
      expect(rev.isError, false, reason: '${rev.errorMessage}');

      expect((await enMgr.getEnrollmentById(predecessorId)).approval?.state,
          EnrollmentStatus.revoked.name,
          reason: 'precondition: the predecessor really was revoked');
      expect((await enMgr.getEnrollmentById(successorId)).approval?.state,
          EnrollmentStatus.approved.name,
          reason: 'the successor is a PEER, not a child: retiring the old key '
              'must not kill the credential that replaced it');
      expect(jsonDecode(rev.data!).containsKey('cascadedEnrollmentIds'), false,
          reason: 'and nothing was reported as cascaded');
    });

    test('the successor is still in its APPROVER\'s cascade', () async {
      // The other half, and the reason inheritance matters. The successor
      // stands where its predecessor stood, so revoking whoever admitted the
      // predecessor still reaches it — a retrofit is not an escape hatch from
      // revocation, it just is not reached by revoking the credential it
      // replaced.
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      final r = await selfEnroll(
          predecessorId: predecessorId,
          appName: 'reach-app',
          deviceName: 'reach-device');
      expect(r.isError, false, reason: '${r.errorMessage}');
      final successorId = jsonDecode(r.data!)['enrollmentId'] as String;

      final reachable = await enMgr.descendantsOf(etu.primaryEnId);
      expect(reachable, contains(successorId),
          reason: 'the successor inherited the primary as its approver');
      expect(reachable, contains(predecessorId),
          reason: 'control: so does the predecessor, which the primary '
              'admitted directly');
      expect(await enMgr.descendantsOf(predecessorId), isNot(contains(successorId)),
          reason: 'and the predecessor itself reaches nothing — that is the '
              'replacement edge, which no longer cascades');
    });
  });

  /// A successor's term restarts its clock at its OWN write, so an equal term
  /// always expires later in absolute time than the credential it replaced.
  /// The mint-time term check cannot see this: it reads the posture off the
  /// predecessor's VALUE, and a cap never touches that — it writes the
  /// record's metadata. So a capped predecessor bounded nothing at all.
  ///
  /// ⚠️ These tests set `metaData.ttl` as well as the value. Every other
  /// predecessor in this pack carries a posture in the value only, which is
  /// the CRAM shape, so it has no stored `expiresAt` and the bound is a no-op
  /// for it — the pack would stay green whether the bound worked or not.
  group('a successor may not outlive its predecessor\'s deadline', () {
    Future<DateTime?> expiryOf(String id) async =>
        (await keyValueStore.get(enMgr.buildEnrollmentKey(id)))
            ?.metaData
            ?.expiresAt;

    /// A predecessor whose RECORD carries a deadline — the shape a capped
    /// enrollment has, and the one the value-only fixtures elsewhere in this
    /// pack cannot produce.
    Future<void> mintUnder(String id, String? predecessorId,
        {Duration? ttl}) async {
      final v = EnrollDataStoreValue('s', 'app-$id', 'device-$id', 'pk')
        ..namespaces = {'*': 'rw', '__manage': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name)
        ..parentEnrollmentId = predecessorId;
      await enMgr.put(
          id,
          AtData()
            ..data = jsonEncode(v.toJson())
            ..metaData = (AtMetaData()..ttl = ttl?.inMilliseconds ?? 0),
          EnrollmentStatus.approved);
    }

    test('a stated "never expires" is bounded by the predecessor\'s record',
        () async {
      await mintUnder('bound-root', null, ttl: Duration(hours: 1));
      final rootExpiry = await expiryOf('bound-root');
      expect(rootExpiry, isNotNull,
          reason: 'precondition: the predecessor really does carry a stored '
              'deadline — without this the bound has nothing to read and the '
              'test passes whatever the production code does');

      final r = await selfEnroll(
          predecessorId: 'bound-root',
          appName: 'bound-app',
          deviceName: 'bound-device',
          apkamKeysExpiryDuration: Duration.zero);
      expect(r.isError, false, reason: '${r.errorMessage}');
      final successorId = jsonDecode(r.data!)['enrollmentId'] as String;

      final successorExpiry = await expiryOf(successorId);
      expect(successorExpiry, isNotNull,
          reason: 'a stated 0 is the keystore\'s "never expires"; against a '
              'bounded predecessor it must not be honoured');
      expect(successorExpiry!.isAfter(rootExpiry!), isFalse,
          reason: 'the successor must not outlive the credential it replaced. '
              'Bounded to $rootExpiry, got $successorExpiry');
    });

    test('the bound is exact, not the deadline plus the work in between',
        () async {
      // A ttl is re-anchored at the instant of the write, so carrying the
      // bound as a DURATION lands it past the predecessor's deadline by
      // however long the intervening work took — small, and in the one
      // direction that matters. It is carried as an absolute instead.
      await mintUnder('exact-root', null, ttl: Duration(hours: 2));
      final rootExpiry = await expiryOf('exact-root');

      final r = await selfEnroll(
          predecessorId: 'exact-root',
          appName: 'exact-app',
          deviceName: 'exact-device',
          apkamKeysExpiryDuration: Duration(days: 30));
      final successorId = jsonDecode(r.data!)['enrollmentId'] as String;

      expect(await expiryOf(successorId), rootExpiry,
          reason: 'exactly the predecessor\'s deadline, to the millisecond');
    });

    test('control: a SHORTER stated term is left alone', () async {
      // The bound is a ceiling, not an assignment. Without this the two above
      // are satisfied by an implementation that overwrites every successor's
      // posture with its predecessor's.
      await mintUnder('short-ask-root', null, ttl: Duration(hours: 5));
      final r = await selfEnroll(
          predecessorId: 'short-ask-root',
          appName: 'short-ask-app',
          deviceName: 'short-ask-device',
          apkamKeysExpiryDuration: Duration(minutes: 10));
      final successorId = jsonDecode(r.data!)['enrollmentId'] as String;

      final successorExpiry = await expiryOf(successorId);
      final rootExpiry = await expiryOf('short-ask-root');
      expect(successorExpiry!.isBefore(rootExpiry!), isTrue,
          reason: 'a successor asking for less than the predecessor has left '
              'keeps its own shorter life');
    });
  });

  group('a retrofit is a once-off', () {
    test('a successor may not itself retrofit', () async {
      final rootId = (await etu.createEnrollments(n: 1)).$1.first;
      final first = await selfEnroll(
          predecessorId: rootId, appName: 'once-app', deviceName: 'once-dev');
      expect(first.isError, false, reason: '${first.errorMessage}');
      final successorId = jsonDecode(first.data!)['enrollmentId'] as String;

      await expectLater(
          () => selfEnroll(
              predecessorId: successorId,
              appName: 'once-app-2',
              deviceName: 'once-dev-2'),
          throwsA(isA<UnAuthorizedException>().having((e) => e.message,
              'message', contains('is itself a replacement'))),
          reason: 'a replacement may not be replaced without an approver');
    });

    test('control: several siblings may still retrofit ONE predecessor',
        () async {
      // Breadth, not depth. Sibling clones of a single keyfile each retrofit
      // the SAME enrollment — none of them has a predecessor that is itself a
      // replacement — and that is the behaviour the retrofit cap re-arms for.
      // Without this control the guard above is satisfied by one that refuses
      // every second retrofit on the atSign.
      final rootId = (await etu.createEnrollments(n: 1)).$1.first;
      for (final i in [1, 2, 3]) {
        final r = await selfEnroll(
            predecessorId: rootId,
            appName: 'sibling-app-$i',
            deviceName: 'sibling-dev-$i');
        expect(r.isError, false,
            reason: 'sibling $i must still be able to retrofit the root: '
                '${r.errorMessage}');
      }
    });
  });

  group('the retrofit cap fold', () {
    final now = DateTime.utc(2026, 1, 1, 12);
    final graceMs =
        Duration(hours: AtSecondaryConfig.apkamSelfEnrollmentGraceHours)
            .inMilliseconds;

    EnrollDataStoreValue withPosture(Duration d) =>
        EnrollDataStoreValue('s', 'app', 'device', 'pk')
          ..apkamKeysExpiryDuration = d;

    test('a record that never expires is bounded only by the grace', () {
      expect(
          enMgr.retrofitCapTtlMillis(
              AtMetaData()..createdAt = now, withPosture(Duration.zero), now),
          graceMs);
      expect(enMgr.retrofitCapTtlMillis(null, withPosture(Duration.zero), now),
          graceMs,
          reason: 'and a record with no metadata at all is the same case');
    });

    test('a POSTURE with no stored expiry does not bound anything', () {
      // The CRAM shape, and the one that made this dangerous. The root record
      // is written with no metadata at all, so it never expires — while its
      // VALUE carries whatever posture the request stated. Folding against a
      // posture the record never had puts the deadline in the past for any
      // root older than that posture, and the 1ms floor then kills it
      // instantly, locking every sibling clone out of the migration.
      expect(
          enMgr.retrofitCapTtlMillis(
              AtMetaData()..createdAt = now.subtract(Duration(days: 60)),
              withPosture(Duration(days: 7)),
              now),
          graceMs,
          reason: 'the record stores no expiry, so it does not expire, and '
              'only the migration grace bounds the cap');
    });

    test('a stored expiry sooner than the grace wins', () {
      expect(
          enMgr.retrofitCapTtlMillis(
              AtMetaData()
                ..createdAt = now.subtract(Duration(minutes: 10))
                ..expiresAt = now.add(Duration(minutes: 50)),
              withPosture(Duration(hours: 1)),
              now),
          Duration(minutes: 50).inMilliseconds,
          reason: 'the cap may never outlive the expiry the enrollment '
              'already carries');
    });

    test('a stored expiry later than the grace does not extend it', () {
      expect(
          enMgr.retrofitCapTtlMillis(
              AtMetaData()
                ..createdAt = now
                ..expiresAt = now.add(Duration(days: 3650)),
              withPosture(Duration(days: 3650)),
              now),
          graceMs,
          reason: 'the fold is a min, not a max');
    });

    test('an elapsed expiry is floored at 1ms, never at zero', () {
      expect(
          enMgr.retrofitCapTtlMillis(
              AtMetaData()
                ..createdAt = now.subtract(Duration(hours: 5))
                ..expiresAt = now.subtract(Duration(hours: 4)),
              withPosture(Duration(hours: 1)),
              now),
          1,
          reason: 'a ttl of zero is the keystore\'s "never expires", so an '
              'elapsed record must not be written as 0 — that would turn a '
              'spent credential into a permanent one');
    });

    test('the deadline is taken from approval, not from creation', () {
      // enroll:approve starts the posture's clock at APPROVAL, writing
      // expiresAt = approvedAt + posture, while createdAt stays at the moment
      // the request was made. Anchoring on creation is short by the approval
      // latency, and NEGATIVE for a record retrofitted between the two — which
      // the floor turns into a 1ms cap on a record with hours of life left.
      expect(
          enMgr.retrofitCapTtlMillis(
              AtMetaData()
                ..createdAt = now.subtract(Duration(hours: 8))
                ..expiresAt = now.add(Duration(hours: 7)),
              withPosture(Duration(hours: 1)),
              now),
          Duration(hours: 7).inMilliseconds,
          reason: 'createdAt + posture is 7 hours in the PAST here; the '
              'stored expiry is what the record actually carries');
    });

    test('an expiry already shortened by a previous cap does not bound the '
        're-arm', () {
      // The other direction of the same max, and the laggard case. A first
      // sibling capped this predecessor to a minute from now; a second sibling
      // upgrading later must be able to push that out, or the first sibling's
      // deadline is final and every laggard is stranded.
      expect(
          enMgr.retrofitCapTtlMillis(
              AtMetaData()
                ..createdAt = now.subtract(Duration(minutes: 10))
                ..expiresAt = now.add(Duration(minutes: 1)),
              withPosture(Duration(hours: 1)),
              now),
          Duration(minutes: 50).inMilliseconds,
          reason: 'a previously written cap is not the posture: the posture '
              'still has 50 minutes to run, and the re-arm may use them');
    });
  });

  /// What `enroll:approve` writes onto the record, for postures that are not
  /// a positive number of milliseconds.
  group('a non-positive key-expiry posture', () {
    Future<AtMetaData?> approveWithPosture(Duration? posture) async {
      final id = await etu.createPendingEnrollment(
          appName: 'posture-app',
          deviceName: 'posture-device-${posture?.inMilliseconds}',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: posture);
      final pending =
          await keyValueStore.get(enMgr.buildEnrollmentKey(id));
      expect(pending?.metaData?.expiresAt, isNotNull,
          reason: 'precondition: a PENDING enrollment carries the window it '
              'has to be approved in, and that is the value that must not '
              'survive approval');
      await etu.approveEnrollment(etu.primaryEnId, id);
      return (await keyValueStore.get(enMgr.buildEnrollmentKey(id)))?.metaData;
    }

    test('a NEGATIVE posture leaves no expiry, not the pending window\'s',
        () async {
      // The metadata builder derives `expiresAt` only for `ttl >= 0`, so a
      // negative ttl skipped the derivation and left the pending record's
      // approval window standing on the approved enrollment. The credential
      // then carried a deadline nobody asked for — and a later retrofit cap,
      // measured against that stale value, looked like an EXTENSION rather
      // than a shortening.
      final md = await approveWithPosture(Duration(milliseconds: -1));

      expect(md?.expiresAt, isNull,
          reason: 'a negative posture asks for a credential that does not '
              'expire, and must not silently inherit the approval window');
      expect(md?.ttl, 0,
          reason: 'and it is written as the keystore\'s "never expires", not '
              'passed through as a negative the builder ignores');
    });

    test('a ZERO posture leaves no expiry either', () async {
      final md = await approveWithPosture(Duration.zero);
      expect(md?.expiresAt, isNull);
      expect(md?.ttl, 0);
    });

    test('a POSITIVE posture is honoured, and starts at approval', () async {
      // The control: the clamp does not swallow real postures.
      final md = await approveWithPosture(Duration(hours: 1));
      expect(md?.ttl, Duration(hours: 1).inMilliseconds);
      expect(md?.expiresAt, isNotNull);
      expect(
          md!.expiresAt!
              .difference(DateTime.now().toUtc())
              .inMinutes,
          greaterThan(55),
          reason: 'measured from approval, so nearly the whole hour remains');
    });
  });

  /// A write that says nothing about expiry must not MOVE expiry.
  ///
  /// The metadata builder re-derives `expiresAt = now + ttl` from the RETAINED
  /// ttl unless the stored absolute is asserted back, so without a carry every
  /// revoke, unrevoke and self-amendment would silently push an enrollment's
  /// deadline out — and with it any retrofit cap standing on the record. These
  /// live here rather than only in the functional pack because the carry is
  /// what makes the cap a deadline rather than advice, and the functional pack
  /// needs Docker.
  group('writes that say nothing about expiry do not move it', () {
    Future<DateTime> expiryOf(String enrollmentId) async {
      final rec = await keyValueStore.get(enMgr.buildEnrollmentKey(enrollmentId));
      final at = rec?.metaData?.expiresAt;
      expect(at, isNotNull,
          reason: 'precondition: $enrollmentId has a deadline to move');
      return at!;
    }

    Future<String> boundedEnrollment() async {
      final id = (await etu.createEnrollments(n: 1)).$1.first;
      final key = enMgr.buildEnrollmentKey(id);
      final atData = await keyValueStore.get(key);
      atData!.metaData!.ttl = Duration(hours: 1).inMilliseconds;
      await enMgr.put(id, atData, EnrollmentStatus.approved);
      return id;
    }

    test('revoke does not restart the clock', () async {
      final id = await boundedEnrollment();
      final before = await expiryOf(id);

      await Future.delayed(Duration(milliseconds: 20));
      await etu.revokeEnrollment(etu.primaryEnId, id);

      expect(await expiryOf(id), before,
          reason: 'revoking says nothing about expiry, so it must move '
              'nothing — a re-derivation from "now" would show as drift');
    });

    test('unrevoke does not restart the clock', () async {
      final id = await boundedEnrollment();
      final before = await expiryOf(id);
      await etu.revokeEnrollment(etu.primaryEnId, id);

      await Future.delayed(Duration(milliseconds: 20));
      await etu.unrevokeEnrollment(etu.primaryEnId, id);

      expect(await expiryOf(id), before,
          reason: 'and neither does putting it back: an enrollment must not '
              'be able to renew itself by cycling its own state');
    });
  });

  /// Who could still restore this atSign, asserted directly.
  ///
  /// Through the arming path only one branch is reachable — the successor
  /// itself — so the question this asks of OTHER enrollments has to be put to
  /// it here. Every case asks about `etu.primaryEnId`, the CRAM root, which
  /// excludes it from its own answer and leaves the minted probe deciding.
  group('hasUnexpiringRootEnrollment', () {
    Future<void> mint(String id, Map<String, String> namespaces,
        {Duration? ttl,
        EnrollmentStatus status = EnrollmentStatus.approved}) async {
      final v = EnrollDataStoreValue('s', 'app-$id', 'device-$id', 'pk')
        ..namespaces = namespaces
        ..approval = EnrollApproval(status.name);
      await enMgr.put(
          id,
          AtData()
            ..data = jsonEncode(v.toJson())
            ..metaData = (AtMetaData()..ttl = ttl?.inMilliseconds ?? 0),
          status);
    }

    test('an enrollment does not count itself', () async {
      // Nothing else fully privileged exists, so a true here could only mean
      // the root vouched for itself — and the guard could then never fire.
      expect(
          await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isFalse);
    });

    test('another fully-privileged enrollment counts', () async {
      await mint('probe-root', {'*': 'rw', '__manage': 'rw'});
      expect(
          await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isTrue);
    });

    test('a __manage holder WITHOUT * does not count', () async {
      // It can admit new enrollments and can never admit one carrying `*`,
      // because approving is checked per namespace against what the approver
      // itself holds. It keeps an atSign running; it cannot give it a root.
      await mint('probe-manage', {'wavi': 'rw', '__manage': 'rw'});
      expect(
          await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isFalse,
          reason: 'the question is who can restore full privilege, not who '
              'can approve');
    });

    test('a * holder without __manage does not count', () async {
      await mint('probe-star', {'*': 'rw'});
      expect(
          await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isFalse,
          reason: '`*` does not imply `__manage` anywhere else in the server '
              'and must not here');
    });

    test('a short-lived root does not count', () async {
      await mint('probe-shortlived', {'*': 'rw', '__manage': 'rw'},
          ttl: Duration(minutes: 1));
      expect(await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isFalse,
          reason: 'an enrollment that will be gone cannot be what keeps the '
              'atSign recoverable');
    });

    test('nor does a root that expires in ten years', () async {
      // The case that separates this rule from the one it replaced. A root
      // 3650 days out satisfied every deadline anyone would compute, so the
      // atSign read as safe — and then stopped being recoverable on a date
      // nothing reported at the time of the act that relied on it.
      await mint('probe-longlived', {'*': 'rw', '__manage': 'rw'},
          ttl: Duration(days: 3650));
      expect(await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isFalse,
          reason: 'a finite root defers the stranding rather than preventing '
              'it, so it must not answer the question');
    });

    test('...while the same root with no expiry does', () async {
      // The control for both cases above: identical grants and status, and
      // the only difference is the ttl, so a false there is about expiry and
      // not about the mint helper producing something unrecognisable.
      await mint('probe-permanent', {'*': 'rw', '__manage': 'rw'});
      expect(await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isTrue);
    });

    test('an unapproved root does not count', () async {
      await mint('probe-revoked', {'*': 'rw', '__manage': 'rw'},
          status: EnrollmentStatus.revoked);
      expect(
          await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isFalse);
    });
  });

  /// Revoking an enrollment revokes everything that replaced it, to any depth.
  ///
  /// A stolen keyfile can mint a successor before the theft is noticed, and a
  /// successor that survived the revocation of what it replaced would defeat
  /// revocation through the very feature that created it. Revocation is also
  /// what binds a HOLDER: `enroll:listns` answers with approved enrollments
  /// only, so a revoked descendant leaves every roster at once, on every
  /// client, including ones that never heard about the revocation.
  group('revocation cascades to descendants', () {
    Future<String?> statusOf(String id) async =>
        (await enMgr.getEnrollmentById(id)).approval?.state;

    Future<Response> revoke(String revokerId, String targetId,
        {bool force = false}) async {
      inboundConnection.metaData
        ..isAuthenticated = true
        ..authType = AuthType.apkam;
      inboundConnection.metadata.enrollmentId = revokerId;
      final p = EnrollParams()..enrollmentId = targetId;
      final r = Response();
      await etu.evh.processVerb(
        r,
        getVerbParam(
            VerbSyntax.enroll,
            'enroll:revoke:${force ? 'force:' : ''}'
            '${jsonEncode(p.toJson())}'),
        inboundConnection,
      );
      return r;
    }

    /// A record written straight to the store, for shapes the verbs cannot
    /// currently produce.
    Future<void> mintUnder(String id, String? predecessorId,
        {EnrollmentStatus status = EnrollmentStatus.approved,
        Duration? ttl}) async {
      final v = EnrollDataStoreValue('s', 'app-$id', 'device-$id', 'pk')
        ..namespaces = {'*': 'rw', '__manage': 'rw'}
        ..approval = EnrollApproval(status.name)
        ..parentEnrollmentId = predecessorId;
      await enMgr.put(
          id,
          AtData()
            ..data = jsonEncode(v.toJson())
            ..metaData = (AtMetaData()..ttl = ttl?.inMilliseconds ?? 0),
          status);
    }

    /// A record written straight to the store, approved BY [approverId].
    /// [namespaces] defaults to full privilege; pass a narrower set for a
    /// link that can approve but is not itself a root.
    Future<void> mintApprovedBy(String id, String? approverId,
        {EnrollmentStatus status = EnrollmentStatus.approved,
        Map<String, String> namespaces = const {'*': 'rw', '__manage': 'rw'},
        Duration? ttl}) async {
      final v = EnrollDataStoreValue('s', 'app-$id', 'device-$id', 'pk')
        ..namespaces = Map<String, String>.from(namespaces)
        ..approval = EnrollApproval(status.name)
        ..approvedByEnrollmentId = approverId;
      await enMgr.put(
          id,
          AtData()
            ..data = jsonEncode(v.toJson())
            ..metaData = (AtMetaData()..ttl = ttl?.inMilliseconds ?? 0),
          status);
    }

    /// An enrollment admitted by [approverId] through the real
    /// `enroll:request` + `enroll:approve` path, so the approval edge is
    /// recorded by production code rather than written by the fixture.
    Future<String> admittedBy(String approverId,
        {Map<String, String> namespaces = const {'test': 'r'},
        String suffix = '',
        Map<String, dynamic>? apsk}) async {
      final id = await etu.createPendingEnrollment(
          appName: 'admitted$suffix',
          deviceName: 'device$suffix',
          namespaces: namespaces,
          apkamKeysExpiryDuration: null,
          apsk: apsk);
      await etu.approveEnrollment(approverId, id);
      return id;
    }

    /// An approved enrollment that can itself approve — it holds `__manage`.
    /// `etu.createEnrollments` grants only an app namespace and `test`, so an
    /// enrollment from there cannot act as an approver at all.
    Future<String> anApprover({String suffix = ''}) async {
      final id = await etu.createPendingEnrollment(
          appName: 'approver$suffix',
          deviceName: 'device$suffix',
          namespaces: {'__manage': 'rw', 'test': 'r'},
          apkamKeysExpiryDuration: null);
      await etu.approveEnrollment(etu.primaryEnId, id);
      return id;
    }

    /// [rootId] → a0 → a1 → …, links along the APPROVAL edge: each enrollment
    /// admitted by the one before it.
    ///
    /// This is the edge revocation cascades along. The replacement edge does
    /// NOT cascade — a retrofit produces a peer, the same principal re-keyed,
    /// so revoking a superseded credential must not take the one that
    /// superseded it.
    ///
    /// Written straight to the store rather than driven through
    /// `enroll:approve`, because what these tests exercise is the cascade's
    /// behaviour over stored data. That the approve path RECORDS the edge is
    /// pinned separately, over the verb.
    Future<List<String>> chainFrom(String rootId, int depth) async {
      final ids = <String>[];
      var current = rootId;
      for (var i = 0; i < depth; i++) {
        final id = 'chain-link-$i';
        await mintApprovedBy(id, current);
        current = id;
        ids.add(current);
      }
      return ids;
    }

    test('an enrollment is revoked with the one that APPROVED it', () async {
      final chain = await chainFrom(etu.primaryEnId, 2);
      final r = await revoke(etu.primaryEnId, chain[0]);
      expect(r.isError, false, reason: '${r.errorMessage}');

      expect(await statusOf(chain[0]), EnrollmentStatus.revoked.name);
      expect(await statusOf(chain[1]), EnrollmentStatus.revoked.name,
          reason: 'an enrollment that outlives the revocation of the one '
              'that admitted it keeps authenticating on an authority already '
              'withdrawn');
    });

    test('the cascade is transitive, not one level deep', () async {
      final chain = await chainFrom(etu.primaryEnId, 3);
      await revoke(etu.primaryEnId, chain[0]);

      expect(await statusOf(chain[1]), EnrollmentStatus.revoked.name);
      expect(await statusOf(chain[2]), EnrollmentStatus.revoked.name,
          reason: 'an enrollment holding __manage may admit another that '
              'holds it too, so approval chains are arbitrarily deep and a '
              'one-level cascade leaves the enrollment beyond it approved');
    });

    test('a revoked link does not hide the enrollment behind it', () async {
      // The walk has to link enrollments of EVERY status. If it followed
      // approved ones only, a revoked enrollment part-way down a chain would
      // conceal the approved enrollment behind it, which is precisely the
      // orphan being removed.
      await mintApprovedBy('link-a', null);
      await mintApprovedBy('link-b', 'link-a',
          status: EnrollmentStatus.revoked);
      await mintApprovedBy('link-c', 'link-b');

      final r = await revoke(etu.primaryEnId, 'link-a');
      expect(r.isError, false, reason: '${r.errorMessage}');
      expect(await statusOf('link-c'), EnrollmentStatus.revoked.name);
    });

    test('the cascade crosses an EXPIRED link', () async {
      // The hole this closes: key enumeration hides records whose ttl has
      // elapsed, so a downward walk lost the expired link's edge and every
      // enrollment behind it survived. The lifetime of that link is chosen by
      // whoever mints it — a never-expiring root may admit a short-lived
      // enrollment that admits others in turn — so it was reachable through
      // the very act the cascade exists to contain.
      await mintApprovedBy('exp-root', null);
      await mintApprovedBy('exp-mid', 'exp-root',
          ttl: Duration(milliseconds: 1));
      await mintApprovedBy('exp-leaf', 'exp-mid');
      await Future.delayed(Duration(milliseconds: 30));

      expect(
          (await enMgr.getAllEnrollmentKeys())
              .any((k) => k.contains('exp-mid')),
          isFalse,
          reason: 'precondition: the middle link is expired and therefore '
              'invisible to enumeration — without this the test passes for '
              'the wrong reason');

      final r = await revoke(etu.primaryEnId, 'exp-root');
      expect(r.isError, false, reason: '${r.errorMessage}');
      expect(await statusOf('exp-leaf'), EnrollmentStatus.revoked.name,
          reason: 'the walk climbs from each live candidate and fetches each '
              'link BY KEY, which returns an expired record, so an expired '
              'enrollment part-way up no longer severs the chain');
    });

    test('capping refuses on a record that is no longer approved', () async {
      // capEnrollmentExpiry is handed a value object read much earlier — the
      // caller awaits a keystore walk and a write in between. If it wrote on
      // the strength of that stale snapshot it would move a revoked
      // enrollment's per-enrollment data back to the approved location,
      // republishing the signing key the revocation had just parked.
      await mintUnder('cap-target', null);
      final stale = await enMgr.getEnrollmentById('cap-target');
      expect(stale.approval?.state, EnrollmentStatus.approved.name,
          reason: 'precondition: the snapshot says approved');

      await revoke(etu.primaryEnId, 'cap-target');
      final key = enMgr.buildEnrollmentKey('cap-target');
      final before = (await keyValueStore.get(key))?.metaData?.expiresAt;

      await enMgr.capEnrollmentExpiry('cap-target');

      expect((await keyValueStore.get(key))?.metaData?.expiresAt, before,
          reason: 'the cap must read the status off the record it just read, '
              'not off the caller\'s snapshot, and must not write at all once '
              'the record is no longer approved');
      expect(await statusOf('cap-target'), EnrollmentStatus.revoked.name);
    });

    test('a revoke whose cascade would remove the caller is refused', () async {
      // A fully privileged enrollment admits administrators holding EXACTLY
      // the grants it holds, so the one it admitted passes the authorisation
      // check against it — and descends from it. Nothing else on this path
      // notices: no one self-revoked, so the self-revoke refusal never fires,
      // and the atSign is stranded by its own cascade.
      final chain = await chainFrom(etu.primaryEnId, 1);

      await expectLater(() => revoke(chain[0], etu.primaryEnId),
          throwsA(isA<AtEnrollmentRevokeException>()),
          reason: 'a revoker has to survive its own act');
      expect(await statusOf(etu.primaryEnId), EnrollmentStatus.approved.name,
          reason: 'refused before anything is written');
      expect(await statusOf(chain[0]), EnrollmentStatus.approved.name);
    });

    test('an id in another case behaves exactly like the canonical one',
        () async {
      // The keystore lowercases every key, so a non-canonical spelling
      // resolves to the SAME record while comparing unequal to the id held on
      // the connection. Unfolded, the record is still written `revoked` while
      // the descendant walk returns nothing and every refusal goes vacuous —
      // the revoke reports success and cascades to no one.
      final approverId = await anApprover(suffix: '-case');
      final admittedId = await admittedBy(approverId, suffix: '-case');

      final r = await revoke(etu.primaryEnId, approverId.toUpperCase());
      expect(r.isError, false, reason: '${r.errorMessage}');
      expect(jsonDecode(r.data!)['cascadedEnrollmentIds'], [admittedId],
          reason: 'the cascade must run for a mixed-case spelling exactly as '
              'it does for the canonical one');
      expect(await statusOf(admittedId), EnrollmentStatus.revoked.name);
    });

    test('a short-lived root may not revoke the last root that outlives it',
        () async {
      // Not a self-revoke, and the target has no descendants, so neither of
      // the other two refusals can see this. The caller revokes the only root
      // that outlives it and then expires, and nothing can approve a
      // replacement.
      await mintUnder('short-root', null, ttl: Duration(minutes: 5));

      await expectLater(() => revoke('short-root', etu.primaryEnId),
          throwsA(isA<AtEnrollmentRevokeException>()),
          reason: 'the liveness question has to be asked for every revoke of '
              'a fully privileged enrollment, not only a self-revoke');
      expect(await statusOf(etu.primaryEnId), EnrollmentStatus.approved.name,
          reason: 'refused before anything is written');
    });

    test('…but a root that outlives the one it revokes may proceed', () async {
      // The control, and it is what stops the refusal above being satisfied
      // by "roots may never revoke roots". Same shape, same target, and the
      // only difference is that this caller carries no expiry.
      await mintUnder('long-root', null);

      final r = await revoke('long-root', etu.primaryEnId);
      expect(r.isError, false, reason: '${r.errorMessage}');
      expect(await statusOf(etu.primaryEnId), EnrollmentStatus.revoked.name);
    });

    test('the last fully privileged enrollment may not revoke itself, even '
        'with force', () async {
      await expectLater(
          () => revoke(etu.primaryEnId, etu.primaryEnId, force: true),
          throwsA(isA<AtEnrollmentRevokeException>()));
      expect(await statusOf(etu.primaryEnId), EnrollmentStatus.approved.name);
    });

    test('…but it may once another fully privileged enrollment exists',
        () async {
      // The control. Without it the refusal above would be satisfied by
      // "self-revocation is refused", which is a different rule and already
      // has its own.
      await mintUnder('spare-root', null);
      final r = await revoke(etu.primaryEnId, etu.primaryEnId, force: true);
      expect(r.isError, false, reason: '${r.errorMessage}');
      expect(await statusOf(etu.primaryEnId), EnrollmentStatus.revoked.name);
    });

    test('an enrollment about to be cascaded away is not counted as the '
        'survivor', () async {
      // It is fully privileged and alive, so a liveness question asked over
      // STORED state answers "somebody survives". It descends by approval
      // from the enrollment being revoked, so the same act removes it.
      final chain = await chainFrom(etu.primaryEnId, 1);
      expect(await statusOf(chain[0]), EnrollmentStatus.approved.name,
          reason: 'precondition: it is alive and fully privileged, so it is '
              'exactly what a cascade-blind check would count');

      await expectLater(
          () => revoke(etu.primaryEnId, etu.primaryEnId, force: true),
          throwsA(isA<AtEnrollmentRevokeException>()),
          reason: 'the question must be asked over what SURVIVES the cascade, '
              'or it reports the atSign safe at the moment it is stranded');
    });

    /// The atSign's original root, rewritten with a finite life, so that the
    /// only PERMANENT root in these two tests is the one the cascade reaches.
    /// It stays approved and fully privileged, so it is still the caller.
    Future<void> makeTheOriginalRootShortLived() async {
      await mintUnder(etu.primaryEnId, null, ttl: Duration(minutes: 5));
    }

    /// [mid] approves but is not itself a root; [root] hangs off it and is.
    Future<void> aRootBehindANonRootApprover(String mid, String root) async {
      await mintApprovedBy(mid, null, namespaces: {'__manage': 'rw'});
      await mintApprovedBy(root, mid);
    }

    test('a cascade through a NON-root target may not remove the last root',
        () async {
      // The command names an enrollment holding no full privilege, so a guard
      // that asks whether the TARGET is a root sees nothing to protect. The
      // root sits BEHIND it, and the cascade takes it: the act removes the
      // atSign's last root while every other refusal on this path stays
      // quiet, because the caller neither is the target nor descends from it.
      await makeTheOriginalRootShortLived();
      await aRootBehindANonRootApprover('mid-approver', 'root-behind-mid');

      expect(
          (await enMgr.getEnrollmentById('mid-approver')).isRootEnrollment,
          isFalse,
          reason: 'precondition: the target is NOT fully privileged, so a '
              'guard reading only the target has nothing to fire on');
      expect(
          (await enMgr.getEnrollmentById('root-behind-mid')).isRootEnrollment,
          isTrue);
      expect(
          await enMgr
              .hasUnexpiringRootEnrollment({'mid-approver', 'root-behind-mid'}),
          isFalse,
          reason: 'precondition: nothing surviving this act is a permanent '
              'root, so the act really does strand the atSign');

      await expectLater(
          () => revoke(etu.primaryEnId, 'mid-approver'),
          throwsA(isA<AtEnrollmentRevokeException>()),
          reason: 'the question is whether the ACT removes a root, not '
              'whether the enrollment it names is one');
      expect(await statusOf('root-behind-mid'), EnrollmentStatus.approved.name,
          reason: 'refused before anything is written');
      expect(await statusOf('mid-approver'), EnrollmentStatus.approved.name);
    });

    test('…and may proceed once a permanent root survives it', () async {
      // The control, and it has to be here: without it the refusal above is
      // equally satisfied by "a revoke through a non-root approver is always
      // refused", which would break every ordinary administrative cascade.
      // Same caller, same target, same subtree — the only difference is a
      // permanent root that the act leaves alone.
      await makeTheOriginalRootShortLived();
      await aRootBehindANonRootApprover('mid-approver', 'root-behind-mid');
      await mintUnder('surviving-root', null);

      final r = await revoke(etu.primaryEnId, 'mid-approver');
      expect(r.isError, false, reason: '${r.errorMessage}');
      expect(await statusOf('mid-approver'), EnrollmentStatus.revoked.name);
      expect(await statusOf('root-behind-mid'), EnrollmentStatus.revoked.name,
          reason: 'the cascade still runs; the guard decides whether the act '
              'is allowed, not what it does');
    });

    test('a root already revoked is not something the act removes', () async {
      // The cascade rewrites only what is currently approved, so a root
      // revoked before this command is not taken away by it. Counting it
      // would refuse a revoke on the strength of an enrollment that had
      // already gone — and the refusal is the only thing standing between an
      // operator and a subtree they are entitled to clear up.
      await makeTheOriginalRootShortLived();
      await mintApprovedBy('mid-approver', null,
          namespaces: {'__manage': 'rw'});
      await mintApprovedBy('spent-root', 'mid-approver',
          status: EnrollmentStatus.revoked);

      expect(await statusOf('spent-root'), EnrollmentStatus.revoked.name,
          reason: 'precondition: the only root in the cascade is already '
              'gone, so the act removes no fully privileged enrollment');
      expect(await enMgr.hasUnexpiringRootEnrollment({}), isFalse,
          reason: 'precondition: no permanent root exists at all, so the '
              'liveness half cannot be what allows this — only the question '
              'of what the act REMOVES can');

      final r = await revoke(etu.primaryEnId, 'mid-approver');
      expect(r.isError, false, reason: '${r.errorMessage}');
      expect(await statusOf('mid-approver'), EnrollmentStatus.revoked.name);
    });

    test('un-revoking a descendant is refused while its approver is not '
        'approved', () async {
      final chain = await chainFrom(etu.primaryEnId, 2);
      await revoke(etu.primaryEnId, chain[0]);
      expect(await statusOf(chain[1]), EnrollmentStatus.revoked.name);

      await expectLater(
          () => etu.unrevokeEnrollment(etu.primaryEnId, chain[1]),
          throwsA(isA<IllegalStateException>()),
          reason: 'without this the cascade is one-way: un-revoking a '
              'descendant while its approver stays revoked restores exactly '
              'the orphan the cascade removed');
    });

    test('…and is allowed once the approver is back', () async {
      final chain = await chainFrom(etu.primaryEnId, 2);
      await revoke(etu.primaryEnId, chain[0]);

      await etu.unrevokeEnrollment(etu.primaryEnId, chain[0]);
      await etu.unrevokeEnrollment(etu.primaryEnId, chain[1]);
      expect(await statusOf(chain[1]), EnrollmentStatus.approved.name);
    });

    test('an enrollment nothing approved is untouched by the guard',
        () async {
      // The exemption the guard cannot do without. An enrollment admitted
      // over an OWNER connection carries no approver — there is no enrollment
      // there to revoke — and "its approver is not approved" is vacuously
      // TRUE of a record with none. A guard phrased without the null test
      // bars un-revoking every one of them.
      await mintApprovedBy('owner-admitted', null,
          status: EnrollmentStatus.revoked);
      await etu.unrevokeEnrollment(etu.primaryEnId, 'owner-admitted');
      expect(await statusOf('owner-admitted'), EnrollmentStatus.approved.name);
    });

    test('…and neither is one whose approver is still approved', () async {
      // The control, and the reason the test above had to stop using this
      // fixture: `createEnrollments` approves over the primary's connection,
      // so this record DOES carry an approver. It passes on the approver
      // being approved, not on the null test — which is a different branch.
      final ordinary = (await etu.createEnrollments(n: 1)).$1.first;
      await revoke(etu.primaryEnId, ordinary);
      await etu.unrevokeEnrollment(etu.primaryEnId, ordinary);
      expect(await statusOf(ordinary), EnrollmentStatus.approved.name);
    });

    test('an approver that no longer exists does not bar un-revoking',
        () async {
      await mintApprovedBy('orphan', 'an-approver-since-deleted',
          status: EnrollmentStatus.revoked);
      await etu.unrevokeEnrollment(etu.primaryEnId, 'orphan');
      expect(await statusOf('orphan'), EnrollmentStatus.approved.name);
    });

    test('approving an enrollment whose approver is unapproved is refused',
        () async {
      // Synthetic, and deliberately so: the approver is written from the
      // connection DURING the approve, after this check has run, so a first
      // approval reads none and this cannot be reached through the verbs. It
      // pins the invariant at the OTHER transition into an active state, so
      // the guard is already in place if that ever changes.
      await mintApprovedBy('dead-approver', null,
          status: EnrollmentStatus.revoked);
      await mintApprovedBy('pending-admitted', 'dead-approver',
          status: EnrollmentStatus.pending);

      await expectLater(
          () => etu.approveEnrollment(etu.primaryEnId, 'pending-admitted'),
          throwsA(isA<IllegalStateException>()));
    });

    test('the response names what the cascade took', () async {
      final chain = await chainFrom(etu.primaryEnId, 2);
      final r = await revoke(etu.primaryEnId, chain[0]);
      expect(jsonDecode(r.data!)['cascadedEnrollmentIds'], [chain[1]]);
    });

    test('and says nothing at all when nothing cascaded', () async {
      final ordinary = (await etu.createEnrollments(n: 1)).$1.first;
      final r = await revoke(etu.primaryEnId, ordinary);
      expect(
          (jsonDecode(r.data!) as Map).containsKey('cascadedEnrollmentIds'),
          isFalse,
          reason: 'an ordinary revoke response must not change shape');
    });

    test('a cascaded enrollment\'s per-enrollment data moves with it',
        () async {
      // The mechanism the cascade's whole security argument rests on, and it
      // had no test: revoking a descendant must PARK its published `_apsk`,
      // the signing key a verifier resolves. If the data stayed at the
      // approved address the enrollment would be revoked on paper and still
      // vouched for on the wire.
      //
      // It is also the invariant the batched move could regress — one pass
      // now serves the whole cascade, so it must reach every listed
      // enrollment and no other.
      // Two approvers, each admitting one enrollment: the cascade must reach
      // what the revoked approver admitted and nothing the other did.
      final approverId = await anApprover(suffix: '-park');
      final bystanderId = await anApprover(suffix: '-bystander');

      final admittedId = await admittedBy(approverId,
          suffix: '-park',
          apsk: {'signingPublicKey': 'k', 'signingAlgo': 'mldsa65'});
      final bystanderAdmittedId = await admittedBy(bystanderId,
          suffix: '-bystander',
          apsk: {'signingPublicKey': 'k2', 'signingAlgo': 'mldsa65'});

      final approvedKey = 'public:_apsk.$admittedId'
          '.${EnrollmentConstants.perEnrollmentApproved}$alice';
      final revokedKey = 'public:_apsk.$admittedId'
          '.${EnrollmentConstants.perEnrollmentRevoked}$alice';
      final bystanderKey = 'public:_apsk.$bystanderAdmittedId'
          '.${EnrollmentConstants.perEnrollmentApproved}$alice';
      expect(await keyValueStore.exists(approvedKey), isTrue,
          reason: 'precondition: the admitted enrollment published a signing '
              'key');
      expect(await keyValueStore.exists(bystanderKey), isTrue,
          reason: 'precondition: so did the bystander');

      await revoke(etu.primaryEnId, approverId);

      expect(await keyValueStore.exists(revokedKey), isTrue,
          reason: 'the cascaded enrollment\'s signing key must be parked');
      expect(await keyValueStore.exists(approvedKey), isFalse,
          reason: 'and must no longer be resolvable at the live address');
      expect(await keyValueStore.exists(bystanderKey), isTrue,
          reason: 'one pass now serves the whole cascade, so it must touch '
              'every enrollment in it and NO enrollment outside it');
    });

    test('a cascaded revoke does not move the expiry it found', () async {
      await mintApprovedBy('exp-approver', null);
      await mintApprovedBy('exp-admitted', 'exp-approver',
          ttl: Duration(days: 2));
      final ek = enMgr.buildEnrollmentKey('exp-admitted');
      final before = (await keyValueStore.get(ek))!.metaData!.expiresAt;

      // Long enough that a re-derived `expiresAt = now + ttl` lands visibly
      // later than the stored one. Without it the drift is the duration of
      // the call, which can be under a millisecond and round to equal.
      await Future.delayed(Duration(milliseconds: 50));
      await revoke(etu.primaryEnId, 'exp-approver');

      expect(await statusOf('exp-admitted'), EnrollmentStatus.revoked.name,
          reason: 'precondition: the cascade actually wrote this record');
      expect((await keyValueStore.get(ek))!.metaData!.expiresAt, before,
          reason: 'a revoke says nothing about expiry, and the metadata '
              'builder re-derives it from the retained ttl unless the stored '
              'value is asserted back — so a cascade would hand every '
              'enrollment it revoked a fresh full lifetime, and restart any '
              'retrofit cap standing on it');
    });

    /// The revocation history: one record per moment an enrollment's
    /// revocation state changed, written as a record of its OWN so the fact
    /// outlives the enrollment it describes.
    ///
    /// A field on the enrollment could not do that. An enrollment record
    /// carries the APKAM key-expiry posture as its ttl, so a revoked
    /// enrollment is reaped on the schedule its own credential was issued
    /// under — and a stamp living there disappears with it, taking the answer
    /// to "when was anything holding this namespace last revoked" backwards on
    /// a timetable chosen by whoever set that posture.
    group('the revocation event log', () {
      Future<List<EnrollmentRevocationEvent>> eventsFor(String id) async =>
          (await enMgr.revocationEvents())
              .where((e) => e.enrollmentId == id)
              .toList();

      test('nothing is written until something is revoked', () async {
        // The control. Without it every assertion below is satisfied by a log
        // that records every enrollment operation there is.
        await etu.createEnrollments(n: 1);
        expect(await enMgr.revocationEvents(), isEmpty);
      });

      test('a revoke writes one event, naming who did it and what it held',
          () async {
        final ordinary = (await etu.createEnrollments(n: 1)).$1.first;
        final grants =
            Map<String, String>.from((await enMgr.getEnrollmentById(ordinary))
                .namespaces);
        expect(grants, isNotEmpty, reason: 'precondition: there ARE grants to '
            'record, so the assertion below is not vacuous');
        final before = DateTime.now().toUtc();
        await revoke(etu.primaryEnId, ordinary);

        final es = await eventsFor(ordinary);
        expect(es, hasLength(1));
        expect(es.single.type, EnrollmentRevocationEventType.revoked);
        expect(es.single.at.isBefore(before), isFalse,
            reason: 'the moment of the revoke, not something carried over '
                'from the record it was read out of');
        expect(es.single.byEnrollmentId, etu.primaryEnId,
            reason: 'the enrollment on the connection that issued it');
        expect(es.single.cascadedFrom, isNull,
            reason: 'an operator named this one, so there is no other '
                'enrollment to explain why it went');
        expect(es.single.namespaces, grants,
            reason: 'copied at the revocation, because the enrollment record '
                'is the thing that may be gone by the time anyone reads this '
                '— and its grants are the only evidence of which namespaces '
                'the revocation touched');
      });

      test('a cascade writes one event each, naming the enrollment whose '
          'revocation swept them up', () async {
        final chain = await chainFrom(etu.primaryEnId, 2);
        await revoke(etu.primaryEnId, chain[0]);

        final named = await eventsFor(chain[0]);
        final swept = await eventsFor(chain[1]);
        expect(named, hasLength(1));
        expect(swept, hasLength(1));
        expect(named.single.cascadedFrom, isNull);
        expect(swept.single.cascadedFrom, chain[0],
            reason: 'why THIS enrollment was revoked is not visible from its '
                'own record — nobody named it');
        expect(swept.single.byEnrollmentId, etu.primaryEnId,
            reason: 'who did it, which is a different question from why this '
                'one went, and a cascade is exactly where the two differ');
        expect(swept.single.at, named.single.at,
            reason: 'one act, one moment: stamping each with the instant its '
                'own write happened would invite a reader to order them '
                'against one another as separate decisions');
      });

      test('un-revoking writes a counter-event rather than erasing the '
          'revocation', () async {
        final ordinary = (await etu.createEnrollments(n: 1)).$1.first;
        await revoke(etu.primaryEnId, ordinary);
        await etu.unrevokeEnrollment(etu.primaryEnId, ordinary);

        final es = await eventsFor(ordinary);
        expect(es, hasLength(2));
        expect(
            es
                .where((e) => e.type == EnrollmentRevocationEventType.revoked)
                .length,
            1,
            reason: 'the revocation still stands in the history. Withdrawing '
                'it is a second fact, not the removal of the first — which is '
                'the case an audit most wants to see');
        final withdrawal = es
            .singleWhere((e) => e.type == EnrollmentRevocationEventType.unrevoked);
        expect(withdrawal.byEnrollmentId, etu.primaryEnId);
        expect(withdrawal.namespaces, isNotEmpty,
            reason: 'a withdrawal has to say which namespaces it affects '
                'without the enrollment, for the same reason a revocation '
                'does');
      });

      test('and on an enrollment the cascade swept up', () async {
        final chain = await chainFrom(etu.primaryEnId, 2);
        await revoke(etu.primaryEnId, chain[0]);
        await etu.unrevokeEnrollment(etu.primaryEnId, chain[0]);
        await etu.unrevokeEnrollment(etu.primaryEnId, chain[1]);

        expect(
            (await eventsFor(chain[1]))
                .where((e) => e.type == EnrollmentRevocationEventType.unrevoked)
                .length,
            1,
            reason: 'the counter-event is a property of the transition, not '
                'of how the record came to be revoked');
      });

      test('an event record is not enumerated as an enrollment', () async {
        // `EnrollmentConstants.enrollmentsRegex` is an UNANCHORED substring,
        // so a key carrying `.new.enrollments.__manage@` anywhere in it is
        // swept up by `getAllEnrollmentKeys` and handed to a decoder
        // expecting an EnrollDataStoreValue. Nearly every enrollment walk in
        // the server goes through that enumeration — the roster, the liveness
        // check, the legacy-key sweeps.
        final ordinary = (await etu.createEnrollments(n: 1)).$1.first;
        await revoke(etu.primaryEnId, ordinary);

        final enrollmentKeys = await enMgr.getAllEnrollmentKeys();
        expect(enrollmentKeys, contains(enMgr.buildEnrollmentKey(ordinary)),
            reason: 'the positive control: this enumeration really does find '
                'enrollment records, so the absence below is about the event '
                'key rather than about a walk that found nothing');

        final List<String> eventKeys = await (await keyValueStore.getKeys(
                regex: EnrollmentManager.revocationEventsRegex))
            .toList();
        expect(eventKeys, hasLength(1),
            reason: 'precondition: there IS an event record on disk to be '
                'wrongly enumerated');
        expect(enrollmentKeys, isNot(contains(eventKeys.single)));
        expect(eventKeys.single, contains('.__manage@'),
            reason: 'and it stays inside __manage, so the scan rule that '
                'already hides enrollment records hides this too');
      });

      test('the history outlives the enrollment it describes', () async {
        // The whole reason the log exists. A stamp on the enrollment record
        // goes when the record goes, and the record goes on a schedule the
        // enrollment's own key-expiry posture chose.
        final holders = (await etu.createEnrollments(n: 2)).$1;
        await revoke(etu.primaryEnId, holders[1]);
        final DateTime at = (await eventsFor(holders[1])).single.at;
        expect(await enMgr.lastRevocationForNamespace('test'), at,
            reason: 'precondition');

        // Deleting the record is the end state a reap arrives at.
        await enMgr.remove(enId: holders[1]);
        await expectLater(() => enMgr.getEnrollmentById(holders[1]),
            throwsA(isA<KeyNotFoundException>()),
            reason: 'precondition: the enrollment really is gone');

        expect((await eventsFor(holders[1])).single.at, at,
            reason: 'the event is a record of its own and nothing reaped it');
        expect(await enMgr.lastRevocationForNamespace('test'), at,
            reason: 'and the namespace still reports the revocation. Read off '
                'the enrollments, this answer would now be null — the '
                'namespace would report that nothing had ever been revoked, '
                'which is what a client polling for a reason to re-fetch '
                'reads as "nothing has changed"');
      });
    });

    /// `enroll:infons:<ns>` answers facts about a NAMESPACE, as opposed to
    /// `enroll:listns`, which answers who holds it. The distinction is what
    /// gives the last revocation a shape it fits: a roster is a list of
    /// members, and "when was something holding this namespace last revoked"
    /// is not a fact about any member.
    ///
    /// It is also the only answer that reaches the clients a revocation
    /// backstop exists for. `enroll:list` narrows to the caller's OWN record
    /// unless the caller is legacy-PKAM or holds `__manage`, so an ordinary
    /// app enrollment asking "has anything holding my namespace been revoked?"
    /// through that verb is told, vacuously and forever, no.
    group('enroll:infons carries the last revocation affecting a namespace',
        () {
      Future<Map<String, dynamic>> infons(
          String callerId, String namespace) async {
        inboundConnection.metaData.isAuthenticated = true;
        inboundConnection.metadata.enrollmentId = callerId;
        final r = Response();
        await etu.evh.processVerb(
            r,
            HashMap<String, String?>.from(
                {'operation': 'infons', 'listNamespace': namespace}),
            inboundConnection);
        expect(r.isError, false, reason: '${r.errorMessage}');
        return jsonDecode(r.data!) as Map<String, dynamic>;
      }

      /// The moment the LOG says [id] was revoked, read straight off the
      /// stored event rather than through the derivation under test — so a
      /// derivation that agreed with itself would not satisfy it.
      Future<DateTime> soleRevocationOf(String id) async {
        final es = (await enMgr.revocationEvents())
            .where((e) =>
                e.enrollmentId == id &&
                e.type == EnrollmentRevocationEventType.revoked)
            .toList();
        expect(es, hasLength(1),
            reason: 'meaningful only for an enrollment revoked exactly once');
        return es.single.at;
      }

      Future<List<dynamic>> listns(String callerId, String namespace) async {
        inboundConnection.metaData.isAuthenticated = true;
        inboundConnection.metadata.enrollmentId = callerId;
        final r = Response();
        await etu.evh.processVerb(
            r,
            HashMap<String, String?>.from(
                {'operation': 'listns', 'listNamespace': namespace}),
            inboundConnection);
        expect(r.isError, false, reason: '${r.errorMessage}');
        return jsonDecode(r.data!) as List;
      }

      test('nothing revoked answers an explicit null, not an absent key',
          () async {
        // The control, and the shape. An absent key and a key the client
        // failed to parse are the same thing to a careless reader; an explicit
        // null is an answer to the question that was asked.
        final holders = (await etu.createEnrollments(n: 2)).$1;
        final info = await infons(holders[0], 'test');
        expect(info.containsKey('lastRevokedAt'), isTrue,
            reason: 'the key is always present');
        expect(info['lastRevokedAt'], isNull);
      });

      test('a revoked holder is reported', () async {
        final holders = (await etu.createEnrollments(n: 2)).$1;
        await revoke(etu.primaryEnId, holders[1]);
        final at = await soleRevocationOf(holders[1]);

        expect((await infons(holders[0], 'test'))['lastRevokedAt'],
            at.toIso8601String());
      });

      test('the roster keeps exactly the shape it always had', () async {
        // `enroll:listns` must not change at all. A deployed client decodes it
        // as `if (decoded is! List) return const []`, so an unrecognised shape
        // there is silently an empty namespace rather than an error — which is
        // the whole reason this fact lives on its own verb.
        final holders = (await etu.createEnrollments(n: 2)).$1;
        await revoke(etu.primaryEnId, holders[1]);

        final roster = await listns(holders[0], 'test');
        expect(roster, isNotEmpty);
        for (final row in roster) {
          expect((row as Map).keys.toSet(),
              {'enrollmentId', 'access', 'apkamPubKey', 'metadata'},
              reason: 'no key added, none removed');
        }
        expect(roster.any((r) => (r as Map)['enrollmentId'] == holders[1]),
            isFalse,
            reason: 'a revoked enrollment leaves the roster, which is what '
                'makes revocation bind a holder');
      });

      test('a revoked enrollment holding a DIFFERENT namespace is not '
          'reported', () async {
        // Without this the derivation could ignore the namespace entirely and
        // report the atSign's most recent revocation for every namespace —
        // which would order a rotation on every namespace every time anything
        // anywhere was revoked, and no other test here would notice.
        final holders = (await etu.createEnrollments(n: 2)).$1;
        // holders[1] holds app_2 and test. Revoke it and ask about app_1,
        // which it does NOT hold.
        await revoke(etu.primaryEnId, holders[1]);
        await soleRevocationOf(holders[1]); // precondition: there IS a
        // revocation to be wrongly reported.

        // holders[0] holds app_1, so it may ask about it.
        expect((await infons(holders[0], 'app_1'))['lastRevokedAt'], isNull,
            reason: 'the revoked enrollment does not hold app_1, so it says '
                'nothing about app_1');
        // The control: the same revocation IS reported for a namespace it did
        // hold, so this is about the filter and not about the stamp missing.
        expect((await infons(holders[0], 'test'))['lastRevokedAt'], isNotNull);
      });

      test('the latest of several revocations is the one reported', () async {
        final holders = (await etu.createEnrollments(n: 3)).$1;
        await revoke(etu.primaryEnId, holders[1]);
        // Long enough that the two stamps are distinguishable; without it
        // "latest" can pass on two equal values.
        await Future.delayed(Duration(milliseconds: 20));
        await revoke(etu.primaryEnId, holders[2]);

        final first = await soleRevocationOf(holders[1]);
        final second = await soleRevocationOf(holders[2]);
        expect(second.isAfter(first), isTrue, reason: 'precondition');

        expect((await infons(holders[0], 'test'))['lastRevokedAt'],
            second.toIso8601String());
      });

      test('an enrollment the CASCADE revoked is reported on its own',
          () async {
        final holders = [
          (await etu.createEnrollments(n: 1)).$1.first,
          await anApprover(suffix: '-infons'),
        ];
        // An enrollment ADMITTED by holders[1], holding 'test' as it does, so
        // revoking holders[1] cascades to it.
        final successorId = await admittedBy(holders[1], suffix: '-infons');

        await revoke(etu.primaryEnId, holders[1]);

        // Un-revoke the NAMED target so the only revocation still standing is
        // the one the cascade made. Without this the target is written last,
        // its stamp wins the maximum, and the cascade's contribution is
        // invisible whether it is counted or not.
        await etu.unrevokeEnrollment(etu.primaryEnId, holders[1]);
        expect(
            (await enMgr.revocationEvents())
                .where((e) =>
                    e.enrollmentId == holders[1] &&
                    e.type == EnrollmentRevocationEventType.unrevoked)
                .length,
            1,
            reason: 'precondition: the named target is withdrawn, so it no '
                'longer contributes');
        final cascadedAt = await soleRevocationOf(successorId);

        expect((await infons(holders[0], 'test'))['lastRevokedAt'],
            cascadedAt.toIso8601String(),
            reason: 'a cascade revokes a successor holding its predecessor\'s '
                'namespaces exactly, so a revocation reaches this answer '
                'through the descendant as readily as through the enrollment '
                'an operator named — which is what makes recording the '
                'cascaded ones load-bearing rather than tidy');
      });

      test('un-revoking the last revoked holder takes it back to null',
          () async {
        final holders = (await etu.createEnrollments(n: 2)).$1;
        await revoke(etu.primaryEnId, holders[1]);
        expect((await infons(holders[0], 'test'))['lastRevokedAt'], isNotNull,
            reason: 'precondition');

        await etu.unrevokeEnrollment(etu.primaryEnId, holders[1]);
        expect((await infons(holders[0], 'test'))['lastRevokedAt'], isNull,
            reason: 'the counter-event withdraws the revocation, so the '
                'derivation nets to nothing — the history keeps both facts, '
                'and only this derived answer moves back');
      });

      test('it is gated exactly as the roster is', () async {
        // Same authorisation question, so the two verbs share one gate rather
        // than restating it: what a caller may learn ABOUT a namespace and
        // who it may learn holds that namespace cannot drift apart.
        final holders = (await etu.createEnrollments(n: 2)).$1;

        // app_2 holds app_2 and test, but not app_1.
        await expectLater(() => infons(holders[1], 'app_1'),
            throwsA(isA<UnAuthorizedException>()));

        // The control: the same caller may ask about a namespace it holds.
        expect(await infons(holders[1], 'app_2'), isA<Map>());
      });

      test('it requires APKAM authentication', () async {
        inboundConnection.metaData.isAuthenticated = true;
        inboundConnection.metadata.enrollmentId = null;
        await expectLater(
            etu.evh.processVerb(
                Response(),
                HashMap<String, String?>.from(
                    {'operation': 'infons', 'listNamespace': 'test'}),
                inboundConnection),
            throwsA(isA<UnAuthenticatedException>()));
      });
    });
  });

  /// The cap is armed by the successor's FIRST authentication and by nothing
  /// else. Storing a successor proves only that this server wrote a record:
  /// its APKAM private half is persisted client-side, so a keyfile write that
  /// fails leaves the successor existing here and nowhere else — with a clock
  /// already started on the predecessor, by then the only credential that
  /// still works.
  /// `enroll:listns` and `enroll:infons` share one gate, and that gate asks
  /// the same namespace matcher the rest of the server asks. Two ways the
  /// matcher disagreed with the atServer's own rule, both reachable from those
  /// verbs, and neither pinned before now.
  group('the namespace matcher agrees with the server\'s own rule', () {
    Future<String> enrollmentHolding(
        String id, Map<String, String> namespaces) async {
      final v = EnrollDataStoreValue('sid-$id', 'app-$id', 'device-$id', 'pk')
        ..namespaces = Map<String, String>.from(namespaces)
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      await enMgr.put(id, AtData()..data = jsonEncode(v.toJson()),
          EnrollmentStatus.approved);
      return id;
    }

    Future<Response> rosterVerb(
        String operation, String callerId, String namespace) async {
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metadata.enrollmentId = callerId;
      final r = Response();
      try {
        await etu.evh.processVerb(
            r,
            HashMap<String, String?>.from(
                {'operation': operation, 'listNamespace': namespace}),
            inboundConnection);
      } on AtException catch (e) {
        r.isError = true;
        r.errorMessage = e.message;
      }
      return r;
    }

    test('an explicit grant wins over the wildcard, whichever is stored first',
        () async {
      // The grants map is insertion-ordered off `jsonDecode`, so a matcher
      // that tests `*` inside its loop answers differently depending on which
      // grant happened to be written first. The server's own rule has no such
      // dependence: it looks for an explicit suffix match across every
      // enrolled namespace and reaches for `*` only when none matched.
      expect(enMgr.accessInNamespaces({'*': 'r', 'wavi': 'rw'}, 'wavi'), 'rw',
          reason: 'the explicit grant is the one the server would act on, '
              'even though the wildcard is stored first');
      expect(enMgr.accessInNamespaces({'wavi': 'rw', '*': 'r'}, 'wavi'), 'rw',
          reason: 'control: the order the grants are stored in must not '
              'change the answer');
      expect(enMgr.accessInNamespaces({'*': 'r', 'wavi': 'rw'}, 'buzz'), 'r',
          reason: 'control: the wildcard is still the fallback for a '
              'namespace no explicit grant covers');
      expect(enMgr.accessInNamespaces({'*': 'r'}, 'data.wavi'), 'r',
          reason: 'control: and it still covers a dotted namespace');
      expect(enMgr.accessInNamespaces({'wavi': 'rw'}, 'buzz'), isNull,
          reason: 'control: no grant at all is still no access');
    });

    test('a `*` grant does not confer `__manage` on the roster verbs',
        () async {
      final caller = await enrollmentHolding('fg-star-only', {'*': 'rw'});
      for (final operation in ['listns', 'infons']) {
        final r = await rosterVerb(operation, caller,
            EnrollmentConstants.enrollManageNamespace);
        expect(r.isError, true,
            reason: '`*` does not imply `__manage` anywhere else in the '
                'server and enroll:$operation must not be the exception: the '
                '__manage roster and its revocation history are exactly what '
                'a caller holding only `*` may not read');
      }
    });

    test('control: the same caller still reaches an ordinary namespace',
        () async {
      // Without this the refusal above is satisfied by a caller that cannot
      // use the verb at all, rather than by one refused `__manage` alone.
      final caller = await enrollmentHolding('fg-star-control', {'*': 'rw'});
      final r = await rosterVerb('listns', caller, 'wavi');
      expect(r.isError, false,
          reason: 'the wildcard still admits an ordinary namespace; only '
              '__manage is withheld. Got: ${r.errorMessage}');
    });
  });

  group('the retrofit cap is armed by the successor\'s first authentication',
      () {
    test('a successor that never authenticates leaves its predecessor alone',
        () async {
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      await selfEnroll(predecessorId: predecessorId);

      final rec = await keyValueStore.get(enMgr.buildEnrollmentKey(predecessorId));
      expect(rec?.metaData?.expiresAt, isNull,
          reason: 'a retrofit whose keyfile never reached disk must not '
              'retire the credential that still works');
    });

    test(
        'the first authentication caps the predecessor, through the real PKAM '
        'handler', () async {
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      final (successorId, key) = await retrofitWithRealKey(predecessorId);

      final before =
          await keyValueStore.get(enMgr.buildEnrollmentKey(predecessorId));
      expect(before?.metaData?.expiresAt, isNull,
          reason: 'control: uncapped right up until the successor proves '
              'itself, so the assertion below measures the authentication');

      await authenticateAs(successorId, key);

      final after =
          await keyValueStore.get(enMgr.buildEnrollmentKey(predecessorId));
      expect(after?.metaData?.expiresAt, isNotNull,
          reason: 'the arming is wired into the production PKAM path rather '
              'than merely implemented on EnrollmentManager — a mechanism '
              'nothing calls is not delivered');
      expect((await enMgr.getEnrollmentById(successorId)).predecessorCapArmedAt,
          isNotNull,
          reason: 'and the successor records that it armed');
    });

    test('a second authentication does not push the deadline out again',
        () async {
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      final (successorId, key) = await retrofitWithRealKey(predecessorId);
      await authenticateAs(successorId, key, sessionId: 'first-session');

      final k = enMgr.buildEnrollmentKey(predecessorId);
      expect((await keyValueStore.get(k))?.metaData?.expiresAt, isNotNull,
          reason: 'control: the first authentication did arm it');
      final armedAt =
          (await enMgr.getEnrollmentById(successorId)).predecessorCapArmedAt;

      // Shrink the predecessor's window so a re-arm would be unmistakable.
      final aged = await keyValueStore.get(k);
      aged!.metaData!.ttl = 60000;
      await enMgr.put(predecessorId, aged, EnrollmentStatus.approved);

      await authenticateAs(successorId, key, sessionId: 'second-session');

      expect((await keyValueStore.get(k))!.metaData!.ttl!,
          lessThanOrEqualTo(60000),
          reason: 'a successor authenticates on every reconnect. Arming on '
              'each one would rewrite a full grace period onto the '
              'predecessor forever and it would never retire at all');
      expect((await enMgr.getEnrollmentById(successorId)).predecessorCapArmedAt,
          armedAt,
          reason: 'the stamp records the FIRST arming and does not move');
    });

    test('an enrollment that replaced nothing arms nothing', () async {
      // The primary CRAM enrollment has no predecessor, and every ordinary
      // enrollment authenticates through this same path.
      await enMgr.armRetrofitCapOnFirstAuth(etu.primaryEnId);

      final rec =
          await keyValueStore.get(enMgr.buildEnrollmentKey(etu.primaryEnId));
      expect(rec?.metaData?.expiresAt, isNull,
          reason: 'an enrollment with no predecessor must pass through the '
              'arming untouched');
    });

    test('the successor\'s OWN expiry is not restarted by the stamp',
        () async {
      // A predecessor with a key-expiry posture, so the successor inherits a
      // bounded lifetime and therefore has an expiresAt to preserve.
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      final value = await enMgr.getEnrollmentById(predecessorId);
      value.apkamKeysExpiryDuration = Duration(hours: 6);
      await enMgr.put(predecessorId,
          AtData()..data = jsonEncode(value.toJson()), EnrollmentStatus.approved);

      final (successorId, key) = await retrofitWithRealKey(predecessorId);
      final successorKey = enMgr.buildEnrollmentKey(successorId);
      final expiryBefore =
          (await keyValueStore.get(successorKey))!.metaData!.expiresAt;
      expect(expiryBefore, isNotNull,
          reason: 'precondition: the successor inherited a bounded posture, '
              'or this test measures nothing');

      await authenticateAs(successorId, key);

      expect((await keyValueStore.get(successorKey))!.metaData!.expiresAt,
          expiryBefore,
          reason: 'stamping the successor is a read-modify-write of its own '
              'record, and a plain write re-derives expiresAt from the '
              'retained ttl — silently extending the credential by however '
              'long it waited to authenticate');
    });

    test('a REVOKED predecessor is not capped, and is not written back',
        () async {
      // A revoked predecessor is already retired. Capping it would write the
      // record back and hand it a fresh ttl it has no business carrying, and
      // an enrollment that is on no retirement clock must not acquire one by
      // being superseded.
      //
      // Before the cap moved to authentication time this could not arise: the
      // cap ran microseconds after the handler had checked the predecessor was
      // approved. The window is now unbounded, so the check has to be here.
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      final (successorId, successorKey) = await retrofitWithRealKey(predecessorId);

      final key = enMgr.buildEnrollmentKey(predecessorId);
      final atData = await keyValueStore.get(key);
      final value = EnrollDataStoreValue.fromJson(jsonDecode(atData!.data!));
      value.approval = EnrollApproval(EnrollmentStatus.revoked.name);
      atData.data = jsonEncode(value.toJson());
      await enMgr.put(predecessorId, atData, EnrollmentStatus.revoked);

      await authenticateAs(successorId, successorKey, sessionId: 'revoked-session');

      final after = await keyValueStore.get(key);
      expect(after?.metaData?.expiresAt, isNull,
          reason: 'a revoked predecessor is not on a retirement clock — it is '
              'already retired, and capping it would rewrite the record');
      expect(
          EnrollDataStoreValue.fromJson(jsonDecode(after!.data!))
              .approval
              ?.state,
          EnrollmentStatus.revoked.name,
          reason: 'and it stays revoked');
      expect((await enMgr.getEnrollmentById(successorId)).predecessorCapArmedAt,
          isNull,
          reason: 'and nothing is recorded as armed, because nothing was: an '
              'unrevoke restores an ordinary predecessor and the decision has '
              'to be re-made rather than frozen');
    });

    test('a successor that dies before the cap deadline does not arm it',
        () async {
      // Grants alone do not make a successor a replacement: it has to outlive
      // what it replaces. Retiring a working credential in favour of a
      // shorter-lived one is how an atSign ends up with neither — and the
      // predecessor here is the CRAM root, which nothing else can re-issue.
      final rootId = etu.primaryEnId;
      final (successorId, successorKey) = await retrofitWithRealKey(rootId,
          apkamKeysExpiryDuration: Duration(minutes: 1));

      final successorData =
          await keyValueStore.get(enMgr.buildEnrollmentKey(successorId));
      expect(successorData?.metaData?.expiresAt, isNotNull,
          reason: 'precondition: the successor really is short-lived, or this '
              'test measures nothing');

      await authenticateAs(successorId, successorKey, sessionId: 'shortlived-session');

      final rootData =
          await keyValueStore.get(enMgr.buildEnrollmentKey(rootId));
      expect(rootData?.metaData?.expiresAt, isNull,
          reason: 'the root must not acquire a 30-day clock on the word of a '
              'credential that dies in a minute — at the end of the grace the '
              'atSign would hold no enrollment able to approve a replacement');
    });

    test('an UNEXPIRING successor DOES cap the root, which is the whole reason '
        'the first-enrollment exemption could be retired', () async {
      // The control for the test above, and the argument for deleting
      // preserveFirstEnrollmentOnRetrofit: the root is capped like anything
      // else, and the atSign is not stranded because the successor inherited
      // __manage verbatim and can approve a replacement.
      final rootId = etu.primaryEnId;
      final rootBefore = await enMgr.getEnrollmentById(rootId);
      expect(rootBefore.namespaces['__manage'], 'rw',
          reason: 'precondition: the root is the privileged enrollment whose '
              'capping the retired exemption existed to prevent');

      final (successorId, successorKey) = await retrofitWithRealKey(rootId);
      await authenticateAs(successorId, successorKey, sessionId: 'root-session');

      expect(
          (await keyValueStore.get(enMgr.buildEnrollmentKey(rootId)))
              ?.metaData
              ?.expiresAt,
          isNotNull,
          reason: 'one rule for every enrollment, the CRAM-minted root '
              'included');
      final successor = await enMgr.getEnrollmentById(successorId);
      expect(successor.namespaces['__manage'], 'rw',
          reason: 'and the atSign keeps an approver: the successor holds '
              '__manage verbatim, which is what makes capping the root safe');
      expect(successor.namespaces['*'], 'rw');
    });

    test(
        'an ORDINARY predecessor is capped even by a short-lived successor',
        () async {
      // The guard spares only a ROOT predecessor. An ordinary credential
      // never held full privilege, so capping it cannot take full privilege
      // away and the liveness walk is never reached for it — which is what
      // keeps retirement making progress for a fleet whose APKAM keys all
      // expire.
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      final predecessorBefore = await enMgr.getEnrollmentById(predecessorId);
      expect(predecessorBefore.namespaces.containsKey('__manage'), isFalse,
          reason: 'precondition: an ordinary predecessor, not an approver, so '
              'capping it strands nothing');

      final (successorId, successorKey) = await retrofitWithRealKey(predecessorId,
          apkamKeysExpiryDuration: Duration(minutes: 1));
      await authenticateAs(successorId, successorKey, sessionId: 'ordinary-short');

      expect(
          (await keyValueStore.get(enMgr.buildEnrollmentKey(predecessorId)))
              ?.metaData
              ?.expiresAt,
          isNotNull,
          reason: 'a short-lived successor still retires an ordinary '
              'predecessor: there are other approvers behind it, so nothing '
              'is stranded and the migration must still make progress');
    });

    test(
        'an ordinary predecessor is capped even when NOTHING could restore a '
        'root', () async {
      // Pins the isRootEnrollment conjunct. Without it the guard would ask
      // "does any unexpiring root survive?" of every predecessor and answer no
      // here — declining to retire an ordinary credential whose loss strands
      // nothing. Capping an enrollment that never held full privilege cannot
      // remove full privilege, so the question does not arise for it.
      //
      // The ordinary predecessor is minted FIRST: creating an enrollment goes
      // through otp:get, which needs __manage, and the root is the only holder.
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      expect((await enMgr.getEnrollmentById(predecessorId)).isRootEnrollment,
          isFalse,
          reason: 'precondition: an ordinary predecessor');

      // Now revoke the atSign's only root, so a guard that skipped the
      // short-circuit would have no surviving root to find. Written directly:
      // the server refuses an enrollment revoking itself, and there is no
      // other approver here to do it.
      final rootKey = enMgr.buildEnrollmentKey(etu.primaryEnId);
      final rootData = await keyValueStore.get(rootKey);
      final rootValue =
          EnrollDataStoreValue.fromJson(jsonDecode(rootData!.data!));
      rootValue.approval = EnrollApproval(EnrollmentStatus.revoked.name);
      rootData.data = jsonEncode(rootValue.toJson());
      await enMgr.put(etu.primaryEnId, rootData, EnrollmentStatus.revoked);

      expect(
          await enMgr.hasUnexpiringRootEnrollment({predecessorId}),
          isFalse,
          reason: 'precondition: nothing could restore a root, so the '
              'isRootEnrollment conjunct is the only thing that can let the '
              'cap through');

      final (successorId, successorKey) = await retrofitWithRealKey(predecessorId,
          apkamKeysExpiryDuration: Duration(minutes: 1));
      await authenticateAs(successorId, successorKey, sessionId: 'ordinary-noroot');

      expect(
          (await keyValueStore.get(enMgr.buildEnrollmentKey(predecessorId)))
              ?.metaData
              ?.expiresAt,
          isNotNull,
          reason: 'the migration must still make progress for ordinary '
              'credentials, whatever state the atSign\'s roots are in');
    });

    // The successor's own posture must not enter this decision at all, and it
    // once did: a deadline-relative short-circuit skipped the liveness walk
    // whenever the successor outlived the cap. That kept the OLD meaning of
    // "safe" after the walk was given a stricter one, so the outcome inverted
    // on the grace boundary — a successor expiring just INSIDE the grace
    // spared the root, and one expiring past it, or in ten years, capped the
    // atSign's last unexpiring root and left nothing able to restore it.
    // Asking for a longer-lived credential switched the protection off.
    //
    // The control for all three is the UNEXPIRING successor above, which must
    // still cap: these arms differ from it in the successor's expiry and in
    // nothing else.
    for (final (label, posture) in const [
      ('29 days, just inside the grace', Duration(days: 29)),
      ('31 days, just past the grace', Duration(days: 31)),
      ('ten years', Duration(days: 3650)),
    ]) {
      test('a successor expiring in $label does not cap the last unexpiring root',
          () async {
        final rootId = etu.primaryEnId;
        expect((await enMgr.getEnrollmentById(rootId)).isRootEnrollment, isTrue,
            reason: 'precondition: the predecessor is the root this refusal '
                'exists to protect');

        final (successorId, successorKey) = await retrofitWithRealKey(rootId,
            apkamKeysExpiryDuration: posture);
        final successorData =
            await keyValueStore.get(enMgr.buildEnrollmentKey(successorId));
        expect(successorData?.metaData?.expiresAt, isNotNull,
            reason: 'precondition: the successor really does expire, or this '
                'arm is the unexpiring control in disguise');

        await authenticateAs(successorId, successorKey,
            sessionId: 'posture-${posture.inDays}d');

        expect(
            (await keyValueStore.get(enMgr.buildEnrollmentKey(rootId)))
                ?.metaData
                ?.expiresAt,
            isNull,
            reason: 'a successor that expires is not an unexpiring root and '
                'cannot stand in for the one being capped, whatever date its '
                'expiry falls on');
        expect(await enMgr.hasUnexpiringRootEnrollment({}), isTrue,
            reason: 'the atSign is never left without a root it can restore '
                'itself from');
      });
    }

    test('a cap that declines LATE takes its stamp back', () async {
      // The stamp goes on before the cap, deliberately — a capped predecessor
      // with no stamp is re-capped with a fresh grace forever. The cost is
      // that a cap which declines at the write leaves a stamp claiming the
      // question is settled. The reason for that decline is transient (an
      // unrevoke restores the predecessor) while the stamp is durable, so it
      // has to be taken back or the predecessor is exempt for good.
      //
      // Deterministic, no concurrency: the manager's cache is seeded with the
      // approved snapshot the arming path reads, while the record underneath
      // says revoked. That is exactly the state a revoke landing mid-arm
      // produces.
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      final (successorId, successorKey) =
          await retrofitWithRealKey(predecessorId);

      final key = enMgr.buildEnrollmentKey(predecessorId);
      final approved = (await keyValueStore.get(key))!;
      final approvedJson = jsonDecode(approved.data!) as Map<String, dynamic>;

      // Written underneath the manager, so no cascade runs and the successor
      // stays usable — the verb path would revoke it too.
      final revokedValue = EnrollDataStoreValue.fromJson(approvedJson)
        ..approval = EnrollApproval(EnrollmentStatus.revoked.name);
      await keyValueStore.put(
          key, AtData()..data = jsonEncode(revokedValue.toJson()));
      enMgr.atDataCache[key] = (approved, approvedJson);

      await authenticateAs(successorId, successorKey,
          sessionId: 'late-decline');

      expect((await enMgr.getEnrollmentById(successorId)).predecessorCapArmedAt,
          isNull,
          reason: 'the cap did not happen, so the stamp saying it did must not '
              'stand — otherwise the early exit short-circuits every later '
              'authentication and the predecessor is never capped again');
    });

    test('a declined cap does not re-walk the keystore on every '
        'authentication', () async {
      // The last-root decline deliberately records nothing durable, so without
      // an in-process memo its expensive half — a whole-keystore walk looking
      // for another fully privileged enrollment — re-ran on every
      // authentication, forever. The answer that repeats is the expensive one:
      // the walk returns early on the first surviving root, so only the
      // "nobody survives" case pays for all of it.
      await etu.createEnrollments(n: 8); // give the walk something to walk
      final (successorId, successorKey) = await retrofitWithRealKey(
          etu.primaryEnId,
          apkamKeysExpiryDuration: Duration(minutes: 1));

      int reads() =>
          EnrollmentManager.cacheHits + EnrollmentManager.cacheMisses;

      final before = reads();
      await authenticateAs(successorId, successorKey, sessionId: 'memo-1');
      final afterFirst = reads();
      await authenticateAs(successorId, successorKey, sessionId: 'memo-2');
      final afterSecond = reads();

      expect(afterFirst - before, greaterThan(5),
          reason: 'precondition: the first authentication really did walk the '
              'keystore, or the comparison below is vacuous');
      expect(afterSecond - afterFirst, lessThan(afterFirst - before),
          reason: 'the second authentication must not repeat the walk — '
              'nothing has been written, so the answer cannot have changed');
    });

    test('a declined cap is re-decided on the next authentication', () async {
      // A decline is a judgement about state that can change. Freezing it into
      // the record would make an unrevoke — or simply revoking the wrong
      // enrollment and putting it back — a permanent exemption.
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      final (successorId, successorKey) = await retrofitWithRealKey(predecessorId);

      final key = enMgr.buildEnrollmentKey(predecessorId);
      final atData = await keyValueStore.get(key);
      final value = EnrollDataStoreValue.fromJson(jsonDecode(atData!.data!));
      value.approval = EnrollApproval(EnrollmentStatus.revoked.name);
      atData.data = jsonEncode(value.toJson());
      await enMgr.put(predecessorId, atData, EnrollmentStatus.revoked);

      await authenticateAs(successorId, successorKey, sessionId: 'declined-1');
      expect((await enMgr.getEnrollmentById(successorId)).predecessorCapArmedAt,
          isNull,
          reason: 'nothing was armed, so nothing is recorded as armed — the '
              'successor must ask again rather than carry a stale verdict');

      // Put the predecessor back the way an unrevoke would.
      final back = await keyValueStore.get(key);
      final restored = EnrollDataStoreValue.fromJson(jsonDecode(back!.data!));
      restored.approval = EnrollApproval(EnrollmentStatus.approved.name);
      back.data = jsonEncode(restored.toJson());
      await enMgr.put(predecessorId, back, EnrollmentStatus.approved);

      await authenticateAs(successorId, successorKey, sessionId: 'declined-2');
      expect((await keyValueStore.get(key))?.metaData?.expiresAt, isNotNull,
          reason: 'and once the condition clears it arms, rather than staying '
              'exempt for the life of the atSign');
      expect((await enMgr.getEnrollmentById(successorId)).predecessorCapArmedAt,
          isNotNull);
    });

    test('a predecessor that is already gone is not an error', () async {
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      final r = await selfEnroll(predecessorId: predecessorId);
      final successorId = jsonDecode(r.data!)['enrollmentId'] as String;

      await enMgr.remove(enId: predecessorId);
      await enMgr.armRetrofitCapOnFirstAuth(successorId);

      expect((await enMgr.getEnrollmentById(successorId)).predecessorCapArmedAt,
          isNotNull,
          reason: 'stamped even with nothing to cap, or every later '
              'connection re-walks the lookup for a predecessor that is '
              'never coming back');
    });

    test('two first-authentications at once do not cap BOTH of the roots',
        () async {
      // The decision is read-modify-write across the whole keystore: "would
      // any unexpiring root survive capping this predecessor?", and then the
      // cap. Run two at once and both walks finished before either write, so
      // each saw the other's root still uncapped, each concluded it was safe,
      // and both were capped — leaving the atSign with no root it could
      // restore itself from. Two devices reconnecting together is enough, and
      // the re-read before the write narrows the lost update on the
      // successor's own record without ever re-taking the decision.
      //
      // SHORT-LIVED successors are load-bearing. An unexpiring successor is
      // itself a root, so capping both predecessors would strand nothing and
      // the interleaving would not matter.
      final rootData =
          await keyValueStore.get(enMgr.buildEnrollmentKey(etu.primaryEnId));
      final secondRoot =
          EnrollDataStoreValue.fromJson(jsonDecode(rootData!.data!));
      const secondRootId = 'a-second-root';
      await enMgr.put(
          secondRootId,
          AtData()..data = jsonEncode(secondRoot.toJson()),
          EnrollmentStatus.approved);

      Future<DateTime?> expiryOf(String id) async =>
          (await keyValueStore.get(enMgr.buildEnrollmentKey(id)))
              ?.metaData
              ?.expiresAt;

      expect(await expiryOf(etu.primaryEnId), isNull);
      expect(await expiryOf(secondRootId), isNull);
      expect(await enMgr.hasUnexpiringRootEnrollment({}), isTrue,
          reason: 'precondition: the atSign has two unexpiring roots');

      final (firstSuccessor, _) = await retrofitWithRealKey(etu.primaryEnId,
          appName: 'rf-one', apkamKeysExpiryDuration: Duration(minutes: 1));
      final (secondSuccessor, _) = await retrofitWithRealKey(secondRootId,
          appName: 'rf-two', apkamKeysExpiryDuration: Duration(minutes: 1));

      await Future.wait([
        enMgr.armRetrofitCapOnFirstAuth(firstSuccessor),
        enMgr.armRetrofitCapOnFirstAuth(secondSuccessor),
      ]);

      final capped = [
        await expiryOf(etu.primaryEnId),
        await expiryOf(secondRootId),
      ].where((e) => e != null).length;

      expect(capped, 1,
          reason: 'one root retires and the other is spared: whichever walk '
              'runs second has to see the first one\'s cap. Both capped is the '
              'race; neither capped would mean retirement had stopped');
      expect(await enMgr.hasUnexpiringRootEnrollment({}), isTrue,
          reason: 'the atSign is never left without a root it can restore '
              'itself from, whatever the interleaving');
    });

    test('capping an approver moves what it admitted onto its successor',
        () async {
      // Nothing records ancestry beyond an enrollment's immediate approver, so
      // a severed link orphans everything behind it. `enroll:delete` and the
      // expiry sweep could already sever one; the cap would make it ROUTINE,
      // putting a thirty-day deadline on an administrator without asking what
      // sits behind it. A month later the chain breaks: a revoke of the root
      // reaches the first live candidate and stops, and the reactivation
      // refusal then permits un-revoking exactly what the cascade had swept.
      final middleId = await etu.createPendingEnrollment(
          appName: 'middle',
          deviceName: 'device',
          namespaces: {'*': 'rw', '__manage': 'rw'},
          apkamKeysExpiryDuration: null);
      await etu.approveEnrollment(etu.primaryEnId, middleId);

      final behindId = await etu.createPendingEnrollment(
          appName: 'behind',
          deviceName: 'device',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null);
      await etu.approveEnrollment(middleId, behindId);

      expect(await enMgr.descendantsOf(middleId), contains(behindId),
          reason: 'precondition: behind really does hang off the middle link');

      final r = await selfEnroll(
          predecessorId: middleId, appName: 'middle', deviceName: 'device');
      expect(r.isError, false, reason: '${r.errorMessage}');
      final successorId = jsonDecode(r.data!)['enrollmentId'] as String;

      await enMgr.armRetrofitCapOnFirstAuth(successorId);

      expect(
          (await keyValueStore.get(enMgr.buildEnrollmentKey(middleId)))
              ?.metaData
              ?.expiresAt,
          isNotNull,
          reason: 'precondition: the cap really did arm — otherwise nothing '
              'was adopted because nothing was being retired');
      expect(await enMgr.descendantsOf(successorId), contains(behindId),
          reason: 'the successor stands where its predecessor stood, so what '
              'the predecessor admitted hangs off it now');
      expect(await enMgr.descendantsOf(middleId), isNot(contains(behindId)),
          reason: 'and no longer off the record that is on its way out');

      // The harm itself. Once the sweep takes the capped record, the chain
      // above still has to reach what that link admitted.
      await enMgr.remove(enId: middleId);
      expect(await enMgr.descendantsOf(etu.primaryEnId), contains(behindId),
          reason: 'revoking the root still reaches it, because the link the '
              'walk climbs through is the successor and the successor is live');
    });
  });
}
