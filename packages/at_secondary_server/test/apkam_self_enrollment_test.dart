import 'dart:convert';

import 'dart:typed_data';

import 'package:at_chops/at_chops.dart'
    show AtChopsUtil, HashingAlgoType, MlDsa65PureDartAlgo, PkamSigningAlgo;
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/verb/handler/pkam_verb_handler.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
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
/// - **The successor records what it replaced**, so revocation can cascade.
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
  /// [parentEnrollmentId], with no OTP.
  /// [namespaces] is optional, mirroring the wire: a retrofit that omits it
  /// inherits its predecessor's grants, and one that states them must state
  /// exactly them.
  Future<Response> selfEnroll({
    required String parentEnrollmentId,
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
    inboundConnection.metadata.enrollmentId = parentEnrollmentId;

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
    // The parent: an ordinary approved enrollment with scoped grants.
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;
    final parentBefore = await enMgr.getEnrollmentById(parentId);
    expect(parentBefore.namespaces, {'app_1': 'rw', 'test': 'r'},
        reason: 'precondition: the parent grants this test relies on');

    final r = await selfEnroll(
        parentEnrollmentId: parentId, namespaces: {'app_1': 'rw', 'test': 'r'});

    expect(r.isError, false, reason: '${r.errorMessage}');
    final m = jsonDecode(r.data!);
    expect(m['status'], EnrollmentStatus.approved.name,
        reason: 'auto-approved: no human step, no OTP — the authenticated '
            'parent is the authority');
    final childId = m['enrollmentId'] as String;
    expect(childId, isNot(parentId));

    final child = await enMgr.getEnrollmentById(childId);
    expect(child.approval?.state, EnrollmentStatus.approved.name);
    expect(child.parentEnrollmentId, parentId,
        reason: 'the child records its parent so revocation can CASCADE — a '
            'stolen keyfile must not spawn a child that survives the '
            'parent\'s revocation');
    expect(child.namespaces.containsKey('__manage'), isFalse,
        reason: 'auto-approve must NOT carry the CRAM branch\'s __manage/* '
            'grant — that grant is what makes CRAM the atSign\'s root, and a '
            'self-enrollment is not that');
    expect(child.namespaces.containsKey('*'), isFalse);

    // The predecessor survives, and is NOT yet capped.
    final parentAfter = await enMgr.getEnrollmentById(parentId);
    expect(parentAfter.approval?.state, EnrollmentStatus.approved.name,
        reason: 'sibling clones of the same keyfile still authenticate as the '
            'predecessor until the cap elapses');
    final parentData =
        await keyValueStore.get(enMgr.buildEnrollmentKey(parentId));
    expect(parentData?.metaData?.expiresAt, isNull,
        reason: 'the cap is armed by the successor\'s first authentication, '
            'not by storing it. A successor whose keyfile write failed exists '
            'here and nowhere else, and starting a clock on the predecessor — '
            'by then the only credential that still works — on the strength '
            'of a record only this server has seen is exactly the hazard');
    expect(child.predecessorCapArmedAt, isNull,
        reason: 'and the successor records that it has armed nothing yet');
  });

  test('escalation is refused: a namespace the parent does not hold', () async {
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;

    await expectLater(
        () => selfEnroll(
            parentEnrollmentId: parentId, namespaces: {'other_ns': 'rw'}),
        throwsA(isA<UnAuthorizedException>().having(
            (e) => e.message, 'message', contains('exceeds the predecessor'))),
        reason: 'a scoped keyfile must not self-spawn grants it never held');
  });

  test('escalation is refused: broader access letters on a held namespace',
      () async {
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;
    // The parent holds test:'r'.

    await expectLater(
        () => selfEnroll(
            parentEnrollmentId: parentId, namespaces: {'test': 'rw'}),
        throwsA(isA<UnAuthorizedException>()),
        reason: 'r under rw fits; rw under r is an escalation — per letter, '
            'not merely per namespace');
  });

  test('escalation is refused: __manage via a wildcard parent', () async {
    // The primary enrollment holds *:rw (CRAM adds __manage too, but the
    // point here is that a * grant alone must never imply __manage).
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;

    await expectLater(
        () => selfEnroll(
            parentEnrollmentId: parentId, namespaces: {'__manage': 'rw'}),
        throwsA(isA<UnAuthorizedException>()),
        reason: '__manage must be held literally — * does not imply it '
            'anywhere else in the server, and must not here');
  });

  test('a wildcard predecessor is inherited verbatim, wildcard and all',
      () async {
    // The primary (CRAM) enrollment holds *:rw and __manage:rw.
    final r = await selfEnroll(parentEnrollmentId: etu.primaryEnId);

    expect(r.isError, false, reason: '${r.errorMessage}');
    final child = await enMgr
        .getEnrollmentById(jsonDecode(r.data!)['enrollmentId'] as String);
    expect(child.namespaces, {'*': 'rw', '__manage': 'rw'},
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
            parentEnrollmentId: etu.primaryEnId,
            namespaces: {'brand_new_ns': 'rw', '__manage': 'rw'}),
        throwsA(isA<UnAuthorizedException>()
            .having((e) => e.message, 'message', contains('carries its grants'))),
        reason: 'a successor holding less than its predecessor is a silent '
            'downgrade — it fails at the next thing the app does, far from '
            'the request that caused it');
  });

  test('a retrofit may keep its own (appName, deviceName)', () async {
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;
    final parent = await enMgr.getEnrollmentById(parentId);

    final r = await selfEnroll(
        parentEnrollmentId: parentId,
        appName: parent.appName,
        deviceName: parent.deviceName);

    expect(r.isError, false,
        reason: 'a retrofit is the same app re-enrolling itself, and sibling '
            'clones of one keyfile share names — the (appName, deviceName) '
            'duplicate refusal must not apply to the self-enrollment branch: '
            '${r.errorMessage}');
    final childId = jsonDecode(r.data!)['enrollmentId'] as String;
    expect(childId, isNot(parentId));
    expect((await enMgr.getEnrollmentById(childId)).approval?.state,
        EnrollmentStatus.approved.name);
  });

  test('an omitted namespaces map inherits the predecessor\'s grants',
      () async {
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;

    final r = await selfEnroll(parentEnrollmentId: parentId);

    expect(r.isError, false, reason: '${r.errorMessage}');
    final child = await enMgr
        .getEnrollmentById(jsonDecode(r.data!)['enrollmentId'] as String);
    expect(child.namespaces, {'app_1': 'rw', 'test': 'r'},
        reason: 'a retrofit does not choose its grants, so it need not state '
            'them — and a caller that cannot read its predecessor\'s record '
            'could not state them correctly anyway');
  });

  test('an empty namespaces map inherits too, rather than being refused',
      () async {
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;

    final r = await selfEnroll(parentEnrollmentId: parentId, namespaces: {});

    expect(r.isError, false, reason: '${r.errorMessage}');
    final child = await enMgr
        .getEnrollmentById(jsonDecode(r.data!)['enrollmentId'] as String);
    expect(child.namespaces, {'app_1': 'rw', 'test': 'r'},
        reason: 'an empty map states nothing, and stating nothing is how a '
            'request asks to inherit');
  });

  test(
      'the cap re-arms on each sibling\'s first authentication rather than '
      'keeping the first deadline', () async {
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;
    final (firstId, firstKey) = await retrofitWithRealKey(parentId,
        appName: 'sib1', deviceName: 'sib1-device');
    await authenticateAs(firstId, firstKey, sessionId: 'sib1-session');

    // Simulate that first retrofit having happened long ago by shrinking the
    // predecessor's remaining ttl directly.
    final key = enMgr.buildEnrollmentKey(parentId);
    final aged = await keyValueStore.get(key);
    aged!.metaData!.ttl = 60000;
    await enMgr.put(parentId, aged, EnrollmentStatus.approved);

    final (secondId, secondKey) = await retrofitWithRealKey(parentId,
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
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;
    // Give the predecessor a key-expiry posture far shorter than the grace.
    final key = enMgr.buildEnrollmentKey(parentId);
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
    await enMgr.put(parentId, atData, EnrollmentStatus.approved);

    // The successor must AUTHENTICATE, or no cap is armed at all and the
    // assertion below passes against an uncapped ttl of 0 — which is what an
    // earlier version of this test did, silently measuring nothing.
    final (childId, childKey) = await retrofitWithRealKey(parentId);
    await authenticateAs(childId, childKey, sessionId: 'posture-session');

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

  test('the child record expires per the posture it inherited', () async {
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;
    // The parent lives under a 1h key-expiry posture.
    final key = enMgr.buildEnrollmentKey(parentId);
    final atData = await keyValueStore.get(key);
    final value = EnrollDataStoreValue.fromJson(jsonDecode(atData!.data!));
    value.apkamKeysExpiryDuration = Duration(hours: 1);
    atData.data = jsonEncode(value.toJson());
    await enMgr.put(parentId, atData, EnrollmentStatus.approved);

    final r = await selfEnroll(
        parentEnrollmentId: parentId);
    expect(r.isError, false, reason: '${r.errorMessage}');
    final childId = jsonDecode(r.data!)['enrollmentId'] as String;

    final child = await enMgr.getEnrollmentById(childId);
    expect(child.apkamKeysExpiryDuration, Duration(hours: 1),
        reason: 'precondition: the inheritance itself, recorded in the value');

    final childTtl =
        (await keyValueStore.get(enMgr.buildEnrollmentKey(childId)))
            ?.metaData
            ?.ttl;
    expect(childTtl, Duration(hours: 1).inMilliseconds,
        reason: 'the retrofit copies the parent\'s expiry to the child — a '
            'posture recorded only in the JSON value while the record carries '
            'no ttl means the child never physically expires, which turns a '
            '1h key-expiry policy into immortality for every retrofitted '
            'enrollment');
  });

  test('a child expiry the request states wins over the inherited one',
      () async {
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;

    final r = await selfEnroll(
        parentEnrollmentId: parentId,
        apkamKeysExpiryDuration: Duration(hours: 2));
    expect(r.isError, false, reason: '${r.errorMessage}');
    final childId = jsonDecode(r.data!)['enrollmentId'] as String;

    final childTtl =
        (await keyValueStore.get(enMgr.buildEnrollmentKey(childId)))
            ?.metaData
            ?.ttl;
    expect(childTtl, Duration(hours: 2).inMilliseconds,
        reason: 'the request may state its own posture instead of inheriting '
            '— and the record must expire per whichever applied');

    // Control: a parent with no posture begets a child with none — ttl 0 is
    // the keystore\'s "never expires", exactly what the ordinary approve
    // path writes for an enrollment without apkamKeysExpiryDuration.
    final r2 = await selfEnroll(
        parentEnrollmentId: parentId,
        appName: 'selfapp2',
        deviceName: 'selfdevice2');
    final child2Id = jsonDecode(r2.data!)['enrollmentId'] as String;
    final child2Ttl =
        (await keyValueStore.get(enMgr.buildEnrollmentKey(child2Id)))
            ?.metaData
            ?.ttl;
    expect(child2Ttl ?? 0, 0,
        reason: 'no posture anywhere must not manufacture an expiry');
  });

  test('a child may not state an expiry that outlives its parent\'s posture',
      () async {
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;
    final key = enMgr.buildEnrollmentKey(parentId);
    final atData = await keyValueStore.get(key);
    final value = EnrollDataStoreValue.fromJson(jsonDecode(atData!.data!));
    value.apkamKeysExpiryDuration = Duration(hours: 1);
    atData.data = jsonEncode(value.toJson());
    await enMgr.put(parentId, atData, EnrollmentStatus.approved);

    final r = await selfEnroll(
        parentEnrollmentId: parentId,
        apkamKeysExpiryDuration: Duration(days: 3650));
    expect(r.isError, false, reason: '${r.errorMessage}');
    final childId = jsonDecode(r.data!)['enrollmentId'] as String;

    final child = await enMgr.getEnrollmentById(childId);
    expect(child.apkamKeysExpiryDuration, Duration(hours: 1),
        reason: 'verifyNoEscalation covers namespaces; TIME is the other axis '
            'a stolen keyfile would widen, and this is the one enrollment '
            'path with no human in the loop to notice. A child that outlives '
            'its parent defeats the very posture the parent was issued under');
    expect(
        (await keyValueStore.get(enMgr.buildEnrollmentKey(childId)))
            ?.metaData
            ?.ttl,
        Duration(hours: 1).inMilliseconds);
  });

  test('a child may not state "never expires" against a bounded parent',
      () async {
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;
    final key = enMgr.buildEnrollmentKey(parentId);
    final atData = await keyValueStore.get(key);
    final value = EnrollDataStoreValue.fromJson(jsonDecode(atData!.data!));
    value.apkamKeysExpiryDuration = Duration(hours: 1);
    atData.data = jsonEncode(value.toJson());
    await enMgr.put(parentId, atData, EnrollmentStatus.approved);

    // Zero is the keystore's "never expires" — the most valuable thing a
    // thief could ask for, and the cheapest to ask for.
    final r = await selfEnroll(
        parentEnrollmentId: parentId,
        apkamKeysExpiryDuration: Duration.zero);
    expect(r.isError, false, reason: '${r.errorMessage}');
    final childId = jsonDecode(r.data!)['enrollmentId'] as String;

    final childTtl =
        (await keyValueStore.get(enMgr.buildEnrollmentKey(childId)))
            ?.metaData
            ?.ttl;
    expect(childTtl, Duration(hours: 1).inMilliseconds,
        reason: 'ttl 0 means never-expires at both layers (_getExpiresAt '
            'returns null), so honouring a stated zero against a time-bound '
            'parent hands out a permanent credential for the asking');
  });

  test('a negative stated expiry is not honoured', () async {
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;

    // A negative ttl skips the metadata builder's ttl >= 0 branch entirely,
    // leaving expiresAt null — immortality by a different route.
    final r = await selfEnroll(
        parentEnrollmentId: parentId,
        apkamKeysExpiryDuration: Duration(milliseconds: -1));
    expect(r.isError, false, reason: '${r.errorMessage}');
    final childId = jsonDecode(r.data!)['enrollmentId'] as String;

    // The raw ttl, NOT `?? 0`: with the whole change reverted the child
    // record carries no metadata at all, and a `?? 0` would read that absence
    // as a written zero and pass for the very state this pins against.
    final childTtl =
        (await keyValueStore.get(enMgr.buildEnrollmentKey(childId)))
            ?.metaData
            ?.ttl;
    expect(childTtl, 0,
        reason: 'a negative posture is not a posture; it must fall back to '
            'the parent\'s (unbounded, written as 0) rather than reaching the '
            'keystore, where a negative ttl skips the expiry write entirely '
            'and leaves the record immortal');
  });

  test(
      'a self-enrollment publishes the apsk it composed, and none when it '
      'composes none', () async {
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;

    // The child composes its own value. signingAlgo is set too and is
    // deliberately NOT what gets published: it is the record PKAM reads, and
    // the two are now independent.
    final composed = {
      'v': 1,
      'signingAlgo': 'mldsa65',
      'publicKey': 'cHEtYXBrYW0tcHVibGlj',
    };
    final r = await selfEnroll(
        parentEnrollmentId: parentId,
        signingAlgo: 'mldsa65',
        apsk: composed);
    expect(r.isError, false, reason: '${r.errorMessage}');
    final childId = jsonDecode(r.data!)['enrollmentId'] as String;

    final childApsk = (await keyValueStore.get(
            'public:_apsk.$childId.${EnrollmentConstants.perEnrollmentApproved}$alice'))!
        .data!;
    expect(jsonDecode(childApsk), composed,
        reason: 'the value is opaque, so it is published exactly as sent — '
            'not recomposed from the record\'s apkamPublicKey, which here is '
            'a different string entirely');

    // The record still carries the algorithm PKAM verifies under, unchanged
    // by any of this.
    expect((await enMgr.getEnrollmentById(childId)).signingAlgo, 'mldsa65');

    // Control: a self-enrollment that sends no apsk gets no record. The
    // server does not fall back to composing one.
    final r2 = await selfEnroll(
        parentEnrollmentId: parentId,
        appName: 'selfapp2',
        deviceName: 'selfdevice2',
        signingAlgo: 'mldsa65');
    final child2Id = jsonDecode(r2.data!)['enrollmentId'] as String;
    expect(
        await keyValueStore.exists(
            'public:_apsk.$child2Id.${EnrollmentConstants.perEnrollmentApproved}$alice'),
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
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;
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
    inboundConnection.metadata.enrollmentId = parentId;
    final enrollResponse = Response();
    await etu.evh.processVerb(
      enrollResponse,
      getVerbParam(
          VerbSyntax.enroll, 'enroll:request:${jsonEncode(ep.toJson())}'),
      inboundConnection,
    );
    expect(enrollResponse.isError, false,
        reason: '${enrollResponse.errorMessage}');
    final childId = jsonDecode(enrollResponse.data!)['enrollmentId'] as String;

    // Seed the challenge the from: verb would have stored, sign it with the
    // child's ML-DSA secret key, and authenticate.
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
          'pkam:signingAlgo:mldsa65:enrollmentId:$childId:'
          '${base64Encode(signature)}'),
      inboundConnection,
    );

    expect(pkamResponse.isError, false, reason: '${pkamResponse.errorMessage}');
    expect(pkamResponse.data, 'success',
        reason: 'record-authoritative ML-DSA verification through the real '
            'at_chops dispatch — the whole point of the retrofit is that '
            'the new enrollment can authenticate');
    expect(inboundConnection.metaData.authType, AuthType.apkam);
    expect(inboundConnection.metadata.enrollmentId, childId);

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
                  'pkam:signingAlgo:mldsa65:enrollmentId:$childId:'
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
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;
    final rsaPair = AtChopsUtil.generateAtPkamKeyPair();

    final ep = EnrollParams()
      ..appName = 'legacy-claim-app'
      ..deviceName = 'legacy-claim-device'
      ..apkamPublicKey = rsaPair.atPublicKey.publicKey;
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.apkam
      ..sessionID = DateTime.now().millisecondsSinceEpoch.toString();
    inboundConnection.metadata.enrollmentId = parentId;
    final enrollResponse = Response();
    await etu.evh.processVerb(
      enrollResponse,
      getVerbParam(
          VerbSyntax.enroll, 'enroll:request:${jsonEncode(ep.toJson())}'),
      inboundConnection,
    );
    final childId = jsonDecode(enrollResponse.data!)['enrollmentId'] as String;

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
          'pkam:signingAlgo:mldsa65:enrollmentId:$childId:'
          '${base64Encode(signature)}'),
      inboundConnection,
    );

    expect(pkamResponse.data, 'success',
        reason: 'the record decides: absent signingAlgo = the rsa2048 '
            'default, and the lying wire claim changes nothing — a legacy '
            'client must not be locked out by a claim it never made');
  });

  test('an unapproved parent is refused', () async {
    final pendingId = await etu.createPendingEnrollment(
        appName: 'pending_app',
        deviceName: 'pending_device',
        namespaces: {'app_x': 'rw'},
        apkamKeysExpiryDuration: null);

    await expectLater(
        () => selfEnroll(
            parentEnrollmentId: pendingId, namespaces: {'app_x': 'rw'}),
        throwsA(isA<UnAuthorizedException>()),
        reason: 'a pending enrollment cannot vouch for anything — only an '
            'approved parent is an authority');
  });

  group('a retrofit carries its predecessor\'s grants and does not choose them',
      () {
    test('a narrower request is refused, loudly', () async {
      final parentId = (await etu.createEnrollments(n: 1)).$1.first;

      await expectLater(
          () => selfEnroll(
              parentEnrollmentId: parentId, namespaces: {'app_1': 'rw'}),
          throwsA(isA<UnAuthorizedException>().having(
              (e) => e.message, 'message', contains('carries its grants'))),
          reason: 'the predecessor holds app_1:rw AND test:r, so this asks '
              'for less. A successor that cannot do what it replaced is a '
              'loss that surfaces at the next thing the app does');
    });

    test('stating exactly the predecessor\'s grants is accepted', () async {
      final parentId = (await etu.createEnrollments(n: 1)).$1.first;

      final r = await selfEnroll(
          parentEnrollmentId: parentId,
          namespaces: {'app_1': 'rw', 'test': 'r'});

      // The control for every refusal in this group: the rule is equality,
      // not a ban on naming grants at all.
      expect(r.isError, false, reason: '${r.errorMessage}');
    });

    test('a narrower access LETTER is refused at the same namespaces',
        () async {
      final parentId = (await etu.createEnrollments(n: 1)).$1.first;

      await expectLater(
          () => selfEnroll(
              parentEnrollmentId: parentId,
              namespaces: {'app_1': 'r', 'test': 'r'}),
          throwsA(isA<UnAuthorizedException>()),
          reason: 'equality is per letter, not merely per namespace — app_1 '
              'drops from rw to r here while the namespace set matches');
    });

    test('an escalation keeps its own diagnosis', () async {
      final parentId = (await etu.createEnrollments(n: 1)).$1.first;

      await expectLater(
          () => selfEnroll(
              parentEnrollmentId: parentId,
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
  group('hasRootEnrollmentAliveAfter', () {
    final deadline = DateTime.now().toUtc().add(Duration(days: 30));

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
          await enMgr.hasRootEnrollmentAliveAfter(etu.primaryEnId, deadline),
          isFalse);
    });

    test('another fully-privileged enrollment counts', () async {
      await mint('probe-root', {'*': 'rw', '__manage': 'rw'});
      expect(
          await enMgr.hasRootEnrollmentAliveAfter(etu.primaryEnId, deadline),
          isTrue);
    });

    test('a __manage holder WITHOUT * does not count', () async {
      // It can admit new enrollments and can never admit one carrying `*`,
      // because approving is checked per namespace against what the approver
      // itself holds. It keeps an atSign running; it cannot give it a root.
      await mint('probe-manage', {'wavi': 'rw', '__manage': 'rw'});
      expect(
          await enMgr.hasRootEnrollmentAliveAfter(etu.primaryEnId, deadline),
          isFalse,
          reason: 'the question is who can restore full privilege, not who '
              'can approve');
    });

    test('a * holder without __manage does not count', () async {
      await mint('probe-star', {'*': 'rw'});
      expect(
          await enMgr.hasRootEnrollmentAliveAfter(etu.primaryEnId, deadline),
          isFalse,
          reason: '`*` does not imply `__manage` anywhere else in the server '
              'and must not here');
    });

    test('a root that expires before the deadline does not count', () async {
      await mint('probe-shortlived', {'*': 'rw', '__manage': 'rw'},
          ttl: Duration(minutes: 1));
      expect(
          await enMgr.hasRootEnrollmentAliveAfter(etu.primaryEnId, deadline),
          isFalse,
          reason: 'an enrollment that will be gone when the cap fires cannot '
              'be what keeps the atSign recoverable');
    });

    test('an unapproved root does not count', () async {
      await mint('probe-revoked', {'*': 'rw', '__manage': 'rw'},
          status: EnrollmentStatus.revoked);
      expect(
          await enMgr.hasRootEnrollmentAliveAfter(etu.primaryEnId, deadline),
          isFalse);
    });
  });

  /// The cap is armed by the successor's FIRST authentication and by nothing
  /// else. Storing a successor proves only that this server wrote a record:
  /// its APKAM private half is persisted client-side, so a keyfile write that
  /// fails leaves the successor existing here and nowhere else — with a clock
  /// already started on the predecessor, by then the only credential that
  /// still works.
  group('the retrofit cap is armed by the successor\'s first authentication',
      () {
    test('a successor that never authenticates leaves its predecessor alone',
        () async {
      final parentId = (await etu.createEnrollments(n: 1)).$1.first;
      await selfEnroll(parentEnrollmentId: parentId);

      final rec = await keyValueStore.get(enMgr.buildEnrollmentKey(parentId));
      expect(rec?.metaData?.expiresAt, isNull,
          reason: 'a retrofit whose keyfile never reached disk must not '
              'retire the credential that still works');
    });

    test(
        'the first authentication caps the predecessor, through the real PKAM '
        'handler', () async {
      final parentId = (await etu.createEnrollments(n: 1)).$1.first;
      final (childId, key) = await retrofitWithRealKey(parentId);

      final before =
          await keyValueStore.get(enMgr.buildEnrollmentKey(parentId));
      expect(before?.metaData?.expiresAt, isNull,
          reason: 'control: uncapped right up until the successor proves '
              'itself, so the assertion below measures the authentication');

      await authenticateAs(childId, key);

      final after =
          await keyValueStore.get(enMgr.buildEnrollmentKey(parentId));
      expect(after?.metaData?.expiresAt, isNotNull,
          reason: 'the arming is wired into the production PKAM path rather '
              'than merely implemented on EnrollmentManager — a mechanism '
              'nothing calls is not delivered');
      expect((await enMgr.getEnrollmentById(childId)).predecessorCapArmedAt,
          isNotNull,
          reason: 'and the successor records that it armed');
    });

    test('a second authentication does not push the deadline out again',
        () async {
      final parentId = (await etu.createEnrollments(n: 1)).$1.first;
      final (childId, key) = await retrofitWithRealKey(parentId);
      await authenticateAs(childId, key, sessionId: 'first-session');

      final k = enMgr.buildEnrollmentKey(parentId);
      expect((await keyValueStore.get(k))?.metaData?.expiresAt, isNotNull,
          reason: 'control: the first authentication did arm it');
      final armedAt =
          (await enMgr.getEnrollmentById(childId)).predecessorCapArmedAt;

      // Shrink the predecessor's window so a re-arm would be unmistakable.
      final aged = await keyValueStore.get(k);
      aged!.metaData!.ttl = 60000;
      await enMgr.put(parentId, aged, EnrollmentStatus.approved);

      await authenticateAs(childId, key, sessionId: 'second-session');

      expect((await keyValueStore.get(k))!.metaData!.ttl!,
          lessThanOrEqualTo(60000),
          reason: 'a successor authenticates on every reconnect. Arming on '
              'each one would rewrite a full grace period onto the '
              'predecessor forever and it would never retire at all');
      expect((await enMgr.getEnrollmentById(childId)).predecessorCapArmedAt,
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
      final parentId = (await etu.createEnrollments(n: 1)).$1.first;
      final value = await enMgr.getEnrollmentById(parentId);
      value.apkamKeysExpiryDuration = Duration(hours: 6);
      await enMgr.put(parentId,
          AtData()..data = jsonEncode(value.toJson()), EnrollmentStatus.approved);

      final (childId, key) = await retrofitWithRealKey(parentId);
      final childKey = enMgr.buildEnrollmentKey(childId);
      final expiryBefore =
          (await keyValueStore.get(childKey))!.metaData!.expiresAt;
      expect(expiryBefore, isNotNull,
          reason: 'precondition: the successor inherited a bounded posture, '
              'or this test measures nothing');

      await authenticateAs(childId, key);

      expect((await keyValueStore.get(childKey))!.metaData!.expiresAt,
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
      final parentId = (await etu.createEnrollments(n: 1)).$1.first;
      final (childId, childKey) = await retrofitWithRealKey(parentId);

      final key = enMgr.buildEnrollmentKey(parentId);
      final atData = await keyValueStore.get(key);
      final value = EnrollDataStoreValue.fromJson(jsonDecode(atData!.data!));
      value.approval = EnrollApproval(EnrollmentStatus.revoked.name);
      atData.data = jsonEncode(value.toJson());
      await enMgr.put(parentId, atData, EnrollmentStatus.revoked);

      await authenticateAs(childId, childKey, sessionId: 'revoked-session');

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
      expect((await enMgr.getEnrollmentById(childId)).predecessorCapArmedAt,
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
      final (childId, childKey) = await retrofitWithRealKey(rootId,
          apkamKeysExpiryDuration: Duration(minutes: 1));

      final childData =
          await keyValueStore.get(enMgr.buildEnrollmentKey(childId));
      expect(childData?.metaData?.expiresAt, isNotNull,
          reason: 'precondition: the successor really is short-lived, or this '
              'test measures nothing');

      await authenticateAs(childId, childKey, sessionId: 'shortlived-session');

      final rootData =
          await keyValueStore.get(enMgr.buildEnrollmentKey(rootId));
      expect(rootData?.metaData?.expiresAt, isNull,
          reason: 'the root must not acquire a 30-day clock on the word of a '
              'credential that dies in a minute — at the end of the grace the '
              'atSign would hold no enrollment able to approve a replacement');
    });

    test('a long-lived successor DOES cap the root, which is the whole reason '
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

      final (childId, childKey) = await retrofitWithRealKey(rootId);
      await authenticateAs(childId, childKey, sessionId: 'root-session');

      expect(
          (await keyValueStore.get(enMgr.buildEnrollmentKey(rootId)))
              ?.metaData
              ?.expiresAt,
          isNotNull,
          reason: 'one rule for every enrollment, the CRAM-minted root '
              'included');
      final successor = await enMgr.getEnrollmentById(childId);
      expect(successor.namespaces['__manage'], 'rw',
          reason: 'and the atSign keeps an approver: the successor holds '
              '__manage verbatim, which is what makes capping the root safe');
      expect(successor.namespaces['*'], 'rw');
    });

    test(
        'an ORDINARY predecessor is capped even by a short-lived successor',
        () async {
      // The guard spares only the last enrollment able to approve another.
      // Declining more widely than that would switch retirement off for any
      // fleet whose APKAM keys are shorter-lived than the grace — silently,
      // and with the grace knob working backwards, since a longer grace would
      // decline more often.
      final parentId = (await etu.createEnrollments(n: 1)).$1.first;
      final parentBefore = await enMgr.getEnrollmentById(parentId);
      expect(parentBefore.namespaces.containsKey('__manage'), isFalse,
          reason: 'precondition: an ordinary predecessor, not an approver, so '
              'capping it strands nothing');

      final (childId, childKey) = await retrofitWithRealKey(parentId,
          apkamKeysExpiryDuration: Duration(minutes: 1));
      await authenticateAs(childId, childKey, sessionId: 'ordinary-short');

      expect(
          (await keyValueStore.get(enMgr.buildEnrollmentKey(parentId)))
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
      // Pins the short-circuit. Without it the guard would ask "does any root
      // survive?" of every predecessor, and answer no here — declining to
      // retire an ordinary credential whose loss strands nothing. Capping an
      // enrollment that never held full privilege cannot remove full
      // privilege, so the question does not arise for it.
      //
      // The ordinary predecessor is minted FIRST: creating an enrollment goes
      // through otp:get, which needs __manage, and the root is the only holder.
      final parentId = (await etu.createEnrollments(n: 1)).$1.first;
      expect((await enMgr.getEnrollmentById(parentId)).isRootEnrollment,
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
          await enMgr.hasRootEnrollmentAliveAfter(
              parentId, DateTime.now().toUtc().add(Duration(days: 30))),
          isFalse,
          reason: 'precondition: nothing could restore a root, so only the '
              'short-circuit can be what lets the cap through');

      final (childId, childKey) = await retrofitWithRealKey(parentId,
          apkamKeysExpiryDuration: Duration(minutes: 1));
      await authenticateAs(childId, childKey, sessionId: 'ordinary-noroot');

      expect(
          (await keyValueStore.get(enMgr.buildEnrollmentKey(parentId)))
              ?.metaData
              ?.expiresAt,
          isNotNull,
          reason: 'the migration must still make progress for ordinary '
              'credentials, whatever state the atSign\'s roots are in');
    });

    test('a declined cap is re-decided on the next authentication', () async {
      // A decline is a judgement about state that can change. Freezing it into
      // the record would make an unrevoke — or simply revoking the wrong
      // enrollment and putting it back — a permanent exemption.
      final parentId = (await etu.createEnrollments(n: 1)).$1.first;
      final (childId, childKey) = await retrofitWithRealKey(parentId);

      final key = enMgr.buildEnrollmentKey(parentId);
      final atData = await keyValueStore.get(key);
      final value = EnrollDataStoreValue.fromJson(jsonDecode(atData!.data!));
      value.approval = EnrollApproval(EnrollmentStatus.revoked.name);
      atData.data = jsonEncode(value.toJson());
      await enMgr.put(parentId, atData, EnrollmentStatus.revoked);

      await authenticateAs(childId, childKey, sessionId: 'declined-1');
      expect((await enMgr.getEnrollmentById(childId)).predecessorCapArmedAt,
          isNull,
          reason: 'nothing was armed, so nothing is recorded as armed — the '
              'successor must ask again rather than carry a stale verdict');

      // Put the predecessor back the way an unrevoke would.
      final back = await keyValueStore.get(key);
      final restored = EnrollDataStoreValue.fromJson(jsonDecode(back!.data!));
      restored.approval = EnrollApproval(EnrollmentStatus.approved.name);
      back.data = jsonEncode(restored.toJson());
      await enMgr.put(parentId, back, EnrollmentStatus.approved);

      await authenticateAs(childId, childKey, sessionId: 'declined-2');
      expect((await keyValueStore.get(key))?.metaData?.expiresAt, isNotNull,
          reason: 'and once the condition clears it arms, rather than staying '
              'exempt for the life of the atSign');
      expect((await enMgr.getEnrollmentById(childId)).predecessorCapArmedAt,
          isNotNull);
    });

    test('a predecessor that is already gone is not an error', () async {
      final parentId = (await etu.createEnrollments(n: 1)).$1.first;
      final r = await selfEnroll(parentEnrollmentId: parentId);
      final childId = jsonDecode(r.data!)['enrollmentId'] as String;

      await enMgr.remove(enId: parentId);
      await enMgr.armRetrofitCapOnFirstAuth(childId);

      expect((await enMgr.getEnrollmentById(childId)).predecessorCapArmedAt,
          isNotNull,
          reason: 'stamped even with nothing to cap, or every later '
              'connection re-walks the lookup for a predecessor that is '
              'never coming back');
    });
  });
}
