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
  }) async {
    final mlDsa = await MlDsa65PureDartAlgo().generateKeyPair();
    final ep = EnrollParams()
      ..appName = appName
      ..deviceName = deviceName
      ..apkamPublicKey = base64Encode(mlDsa.publicKey)
      ..signingAlgo = 'mldsa65'
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
      'an approved enrollment self-enrolls a subset child, auto-approved, '
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
            (e) => e.message, 'message', contains('exceeds the parent'))),
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
      'the cap never extends past the expiry the parent\'s own posture '
      'imposes', () async {
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;
    // Give the parent a key-expiry posture far shorter than the grace.
    final key = enMgr.buildEnrollmentKey(parentId);
    final atData = await keyValueStore.get(key);
    final value = EnrollDataStoreValue.fromJson(jsonDecode(atData!.data!));
    value.apkamKeysExpiryDuration = Duration(hours: 1);
    atData.data = jsonEncode(value.toJson());
    await enMgr.put(parentId, atData, EnrollmentStatus.approved);

    final r = await selfEnroll(
        parentEnrollmentId: parentId);
    expect(r.isError, false, reason: '${r.errorMessage}');

    final ttl = (await keyValueStore.get(key))!.metaData!.ttl!;
    expect(ttl, lessThanOrEqualTo(Duration(hours: 1).inMilliseconds),
        reason: 'the re-arm applies only within the enrollment\'s own '
            'key-expiry posture — a 1h apkamKeysExpiryDuration must not '
            'become a 30-day grace');
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
              (e) => e.message, 'message', contains('exceeds the parent'))),
          reason: 'asking for MORE is a different mistake from asking for '
              'less, and a caller handed one message for both cannot tell '
              'which it made');
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
