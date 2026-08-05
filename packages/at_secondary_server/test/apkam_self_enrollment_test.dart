import 'dart:convert';

import 'package:at_commons/at_commons.dart';
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
///   until `min(now + grace, its existing expiry)` — and the child records
///   its parent so revocation can cascade.
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
  }) async {
    final ep = EnrollParams()
      ..appName = appName
      ..deviceName = deviceName
      ..apkamPublicKey = 'pq apkam public key $appName $deviceName'
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
