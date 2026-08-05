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

/// RF-SRV: an APKAM-authenticated connection self-enrolls a FRESH enrollment.
///
/// This is the "upgrade the enrollment" step every migration scenario in
/// `at_client_sdk docs/projects/pq/decisions.md` 36-40 conjugates — a keyfile
/// upgrades itself with no human step and no OTP, the connection's existing
/// approved enrollment being the whole authority. The two properties that
/// make it safe rather than a privilege-escalation verb:
///
/// - **No escalation**: the child's grants must be a subset of the parent's,
///   per namespace and per access letter, or any scoped keyfile could
///   self-spawn a fully privileged enrollment.
/// - **The parent survives, capped**: sibling clones of the same keyfile
///   retrofit on their own schedules, so the parent keeps authenticating
///   until one grace period after the NEWEST retrofit (the cap re-arms each
///   time, never past the parent's own key-expiry posture) — and the child
///   records its parent so revocation can cascade.
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
  Future<Response> selfEnroll({
    required String parentEnrollmentId,
    required Map<String, String> namespaces,
    String appName = 'selfapp',
    String deviceName = 'selfdevice',
    String? signingAlgo,
    Duration? apkamKeysExpiryDuration,
  }) async {
    final ep = EnrollParams()
      ..appName = appName
      ..deviceName = deviceName
      ..apkamPublicKey = 'pq apkam public key $appName $deviceName'
      ..signingAlgo = signingAlgo
      ..apkamKeysExpiryDuration = apkamKeysExpiryDuration
      ..namespaces = namespaces;
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.apkam
      ..sessionID = DateTime.now().millisecondsSinceEpoch.toString();
    inboundConnection.metadata.enrollmentId = parentEnrollmentId;

    final r = Response();
    await etu.evh.processVerb(
      r,
      getVerbParam(VerbSyntax.enroll, 'enroll:request:${jsonEncode(ep.toJson())}'),
      inboundConnection,
    );
    return r;
  }

  test('an approved enrollment self-enrolls a subset child, auto-approved, '
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

    // The parent survives — capped, not removed.
    final parentAfter = await enMgr.getEnrollmentById(parentId);
    expect(parentAfter.approval?.state, EnrollmentStatus.approved.name,
        reason: 'sibling clones of the same keyfile still authenticate as the '
            'parent until the cap elapses');
    final parentData =
        await keyValueStore.get(enMgr.buildEnrollmentKey(parentId));
    final graceMillis =
        Duration(hours: AtSecondaryConfig.apkamSelfEnrollmentGraceHours)
            .inMilliseconds;
    expect(parentData?.metaData?.ttl, isNotNull,
        reason: 'the cap is real: the parent record now carries an expiry');
    expect(parentData!.metaData!.ttl!, lessThanOrEqualTo(graceMillis + 60000),
        reason: 'and it is min(now + grace, existing expiry), not unbounded');
  });

  test('escalation is refused: a namespace the parent does not hold',
      () async {
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
        () =>
            selfEnroll(parentEnrollmentId: parentId, namespaces: {'test': 'rw'}),
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

  test('a wildcard parent covers ordinary namespaces it never named',
      () async {
    // The primary (CRAM) enrollment holds *:rw and __manage:rw.
    final r = await selfEnroll(
        parentEnrollmentId: etu.primaryEnId,
        namespaces: {'brand_new_ns': 'rw', '__manage': 'rw'});

    expect(r.isError, false, reason: '${r.errorMessage}');
    final child = await enMgr
        .getEnrollmentById(jsonDecode(r.data!)['enrollmentId'] as String);
    expect(child.namespaces['brand_new_ns'], 'rw',
        reason: 'a * parent can grant any ordinary namespace at its letters');
    expect(child.namespaces['__manage'], 'rw',
        reason: 'and __manage passes here only because the primary holds it '
            'LITERALLY — the wildcard test above is the control');
  });

  test('a retrofit may keep its own (appName, deviceName)', () async {
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;
    final parent = await enMgr.getEnrollmentById(parentId);

    final r = await selfEnroll(
        parentEnrollmentId: parentId,
        namespaces: {'app_1': 'rw'},
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

  test('empty namespaces are refused', () async {
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;

    await expectLater(
        () => selfEnroll(parentEnrollmentId: parentId, namespaces: {}),
        throwsA(isA<IllegalArgumentException>()),
        reason: 'an approved credential that can do nothing is always a '
            'caller bug — the child holds exactly what it names');
  });

  test('the cap re-arms on each sibling retrofit rather than keeping the '
      'first deadline', () async {
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;
    await selfEnroll(parentEnrollmentId: parentId, namespaces: {'app_1': 'rw'});

    // Simulate that first retrofit having happened long ago by shrinking the
    // parent's remaining ttl directly.
    final key = enMgr.buildEnrollmentKey(parentId);
    final aged = await keyValueStore.get(key);
    aged!.metaData!.ttl = 60000;
    await enMgr.put(parentId, aged, EnrollmentStatus.approved);

    final r = await selfEnroll(
        parentEnrollmentId: parentId,
        namespaces: {'app_1': 'rw'},
        appName: 'selfapp2',
        deviceName: 'selfdevice2');
    expect(r.isError, false, reason: '${r.errorMessage}');

    final graceMillis =
        Duration(hours: AtSecondaryConfig.apkamSelfEnrollmentGraceHours)
            .inMilliseconds;
    final ttl = (await keyValueStore.get(key))!.metaData!.ttl!;
    expect(ttl, greaterThan(60000),
        reason: 'a min-fold against the previously capped ttl keeps the '
            'first sibling\'s deadline and strands every later one — the cap '
            'must re-arm to a full grace period from now');
    expect(ttl, lessThanOrEqualTo(graceMillis));
  });

  test('the cap never extends past the expiry the parent\'s own posture '
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
        parentEnrollmentId: parentId, namespaces: {'app_1': 'rw'});
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
        parentEnrollmentId: parentId, namespaces: {'app_1': 'rw'});
    expect(r.isError, false, reason: '${r.errorMessage}');
    final childId = jsonDecode(r.data!)['enrollmentId'] as String;

    final child = await enMgr.getEnrollmentById(childId);
    expect(child.apkamKeysExpiryDuration, Duration(hours: 1),
        reason: 'precondition: the inheritance itself, recorded in the value');

    final childTtl = (await keyValueStore.get(enMgr.buildEnrollmentKey(childId)))
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
        namespaces: {'app_1': 'rw'},
        apkamKeysExpiryDuration: Duration(hours: 2));
    expect(r.isError, false, reason: '${r.errorMessage}');
    final childId = jsonDecode(r.data!)['enrollmentId'] as String;

    final childTtl = (await keyValueStore.get(enMgr.buildEnrollmentKey(childId)))
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
        namespaces: {'app_1': 'rw'},
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
        namespaces: {'app_1': 'rw'},
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
        namespaces: {'app_1': 'rw'},
        apkamKeysExpiryDuration: Duration.zero);
    expect(r.isError, false, reason: '${r.errorMessage}');
    final childId = jsonDecode(r.data!)['enrollmentId'] as String;

    final childTtl = (await keyValueStore.get(enMgr.buildEnrollmentKey(childId)))
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
        namespaces: {'app_1': 'rw'},
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
      'an mldsa65 self-enrollment publishes the tagged _apsk; an rsa one '
      'stays bare', () async {
    final parentId = (await etu.createEnrollments(n: 1)).$1.first;

    final r = await selfEnroll(
        parentEnrollmentId: parentId,
        namespaces: {'app_1': 'rw'},
        signingAlgo: 'mldsa65');
    expect(r.isError, false, reason: '${r.errorMessage}');
    final childId = jsonDecode(r.data!)['enrollmentId'] as String;

    final childApsk = (await keyValueStore.get(
            'public:_apsk.$childId.${EnrollmentConstants.perEnrollmentApproved}$alice'))!
        .data!;
    final tagged = jsonDecode(childApsk) as Map<String, dynamic>;
    expect(tagged['signingAlgo'], 'mldsa65',
        reason: 'a verifier fetching this _apsk must learn the algorithm '
            'from the value itself, or it would parse a raw ML-DSA key as '
            'RSA and fail on every signature');
    expect(tagged['publicKey'], 'pq apkam public key selfapp selfdevice');
    expect(tagged['v'], 1);

    // Control: an enrollment without signingAlgo publishes the bare value
    // exactly as today — deployed apps parse it as an RSA key.
    final r2 = await selfEnroll(
        parentEnrollmentId: parentId,
        namespaces: {'app_1': 'rw'},
        appName: 'selfapp2',
        deviceName: 'selfdevice2');
    final child2Id = jsonDecode(r2.data!)['enrollmentId'] as String;
    final bareApsk = (await keyValueStore.get(
            'public:_apsk.$child2Id.${EnrollmentConstants.perEnrollmentApproved}$alice'))!
        .data!;
    expect(bareApsk, 'pq apkam public key selfapp2 selfdevice2',
        reason: 'the bare form is frozen for rsa2048 — the tagged form is '
            'only for algorithms no deployed parser could read anyway');
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
      ..signingAlgo = 'mldsa65'
      ..namespaces = {'app_1': 'rw'};
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

    expect(pkamResponse.isError, false,
        reason: '${pkamResponse.errorMessage}');
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
      ..apkamPublicKey = rsaPair.atPublicKey.publicKey
      ..namespaces = {'app_1': 'rw'};
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
}
