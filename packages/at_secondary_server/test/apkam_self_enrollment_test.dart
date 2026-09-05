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
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';

import 'enrollment_test_utils.dart';
import 'test_utils.dart';

/// An APKAM-authenticated connection retrofits itself: it enrols a FRESH
/// enrollment that REPLACES the one it authenticated as, with no OTP and no
/// human step, the connection's existing approved enrollment being the whole
/// authority.
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
  Future<String?> stateOf(String id) async => EnrollDataStoreValue.fromJson(
          jsonDecode((await keyValueStore.get(enMgr.buildEnrollmentKey(id)))!
              .data!))
      .approval
      ?.state;

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

  /// A retrofit whose successor holds a real ML-DSA keypair, so it can then
  /// authenticate through the production PKAM handler.
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
    expect(successor.retrofitPredecessorEnrollmentId, predecessorId,
        reason: 'the successor records what it replaced, which is what the '
            'settlement reads to know what to revoke. NOT for revocation by '
            'cascade: that follows the approver the successor inherits, '
            'never this edge');
    expect(successor.namespaces.containsKey('__manage'), isFalse,
        reason: 'auto-approve must NOT carry the CRAM branch\'s __manage/* '
            'grant — that grant is what makes CRAM the atSign\'s root, and a '
            'self-enrollment is not that');
    expect(successor.namespaces.containsKey('*'), isFalse);

    final predecessorAfter = await enMgr.getEnrollmentById(predecessorId);
    expect(predecessorAfter.approval?.state, EnrollmentStatus.approved.name,
        reason: 'sibling clones of the same keyfile still authenticate as the '
            'predecessor until a successor does');
    final predecessorData =
        await keyValueStore.get(enMgr.buildEnrollmentKey(predecessorId));
    expect(predecessorData?.metaData?.expiresAt, isNull,
        reason: 'the predecessor is settled by the successor\'s first '
            'authentication, not by storing it. A successor whose keyfile '
            'write failed exists here and nowhere else, and revoking the '
            'predecessor, by then the only credential that still works, on '
            'the strength of a record only this server has seen is exactly '
            'the hazard');
    expect(successor.predecessorSettledAt, isNull,
        reason: 'and the successor records that it has settled nothing yet');
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

    await expectLater(
        () => selfEnroll(
            predecessorId: predecessorId, namespaces: {'test': 'rw'}),
        throwsA(isA<UnAuthorizedException>()),
        reason: 'r under rw fits; rw under r is an escalation — per letter, '
            'not merely per namespace');
  });

  test('escalation is refused: __manage via a wildcard predecessor', () async {
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
    final r = await selfEnroll(predecessorId: etu.primaryEnId);

    expect(r.isError, false, reason: '${r.errorMessage}');
    final successor = await enMgr
        .getEnrollmentById(jsonDecode(r.data!)['enrollmentId'] as String);
    expect(successor.namespaces, {'*': 'rw', '__manage': 'rw'},
        reason: 'a retrofit replaces its predecessor, so it carries those '
            'grants exactly — __manage included, which is what leaves the '
            'atSign able to approve a replacement once the predecessor is '
            'revoked');
  });

  test('naming a subset of a wildcard predecessor is refused', () async {
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
      'siblings that both enrolled before either authenticated settle the same '
      'predecessor: the first revokes it, the second finds it revoked',
      () async {
    final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
    final (firstId, firstKey) = await retrofitWithRealKey(predecessorId,
        appName: 'sib1', deviceName: 'sib1-device');
    final (secondId, secondKey) = await retrofitWithRealKey(predecessorId,
        appName: 'sib2', deviceName: 'sib2-device');

    await authenticateAs(firstId, firstKey, sessionId: 'sib1-session');
    expect(await stateOf(predecessorId), EnrollmentStatus.revoked.name,
        reason: 'the first sibling to authenticate supersedes the predecessor');

    await authenticateAs(secondId, secondKey, sessionId: 'sib2-session');
    expect((await enMgr.getEnrollmentById(secondId)).predecessorSettledAt,
        isNotNull,
        reason: 'the second is settled too, or every later authentication '
            're-asks the question');
    final supersessions = (await enMgr.revocationEvents())
        .where((e) =>
            e.enrollmentId == predecessorId &&
            e.type == EnrollmentRevocationEventType.superseded)
        .toList();
    expect(supersessions.map((e) => e.byEnrollmentId), [firstId],
        reason: 'one supersession, by the sibling that revoked it; the '
            'second found it revoked and wrote none');
  });

  test('the successor record expires per the posture it inherited', () async {
    final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
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

      // Control: no posture anywhere begets none.
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

    final r = await selfEnroll(
        predecessorId: predecessorId,
        apkamKeysExpiryDuration: Duration(milliseconds: -1));
    expect(r.isError, false, reason: '${r.errorMessage}');
    final successorId = jsonDecode(r.data!)['enrollmentId'] as String;

    // NOTE the raw ttl, deliberately not `?? 0`.
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

    expect((await enMgr.getEnrollmentById(successorId)).signingAlgo, 'mldsa65');

      // Control: no apsk sent, no record.
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

      // Control: a tampered signature must be refused.
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

      // Control: the rule is equality, not a ban on naming grants at all.
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

  /// Revocation cascades along the APPROVAL edge and NOT along the
  /// replacement edge.
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
      final approverId = (await etu.createEnrollments(n: 1)).$1.first;
      final pendingId = await etu.createPendingEnrollment(
          appName: 'admitted-app',
          deviceName: 'admitted-device',
          namespaces: {'test': 'r'},
          apkamKeysExpiryDuration: null);
      await etu.approveEnrollment(etu.primaryEnId, pendingId);

      expect((await enMgr.getEnrollmentById(pendingId)).parentEnrollmentId,
          etu.primaryEnId,
          reason: 'read off the CONNECTION, so an approver cannot name '
              'somebody else as the admitting party');
      expect(
          (await enMgr.getEnrollmentById(approverId)).parentEnrollmentId,
          etu.primaryEnId,
          reason: 'control: the fixture\'s own enrollments carry it too, so '
              'the assertion above is not satisfied by a field nothing sets');
    });

    test('a retrofit INHERITS its predecessor\'s approver', () async {
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      final r = await selfEnroll(
          predecessorId: predecessorId,
          appName: 'inherit-app',
          deviceName: 'inherit-device');
      expect(r.isError, false, reason: '${r.errorMessage}');
      final successorId = jsonDecode(r.data!)['enrollmentId'] as String;

      final successor = await enMgr.getEnrollmentById(successorId);
      expect(successor.parentEnrollmentId, etu.primaryEnId,
          reason: 'whoever admitted the predecessor admitted this');
      expect(successor.retrofitPredecessorEnrollmentId, predecessorId,
          reason: 'control: the replacement edge is still recorded, because '
              'the settlement needs to know what it replaced');
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
  group('a successor may not outlive its predecessor\'s deadline', () {
    Future<DateTime?> expiryOf(String id) async =>
        (await keyValueStore.get(enMgr.buildEnrollmentKey(id)))
            ?.metaData
            ?.expiresAt;

    /// A predecessor whose RECORD carries a deadline.
    Future<void> mintUnder(String id, String? predecessorId,
        {Duration? ttl}) async {
      final v = EnrollDataStoreValue('s', 'app-$id', 'device-$id', 'pk')
        ..namespaces = {'*': 'rw', '__manage': 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name)
        ..retrofitPredecessorEnrollmentId = predecessorId;
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
      // NOTE the bound is carried as an absolute, not as a duration.
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
      // Control: the bound is a ceiling, not an assignment.
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
      final rootId = (await etu.createEnrollments(n: 1)).$1.first;
      for (final i in [1, 2, 3]) {
        final r = await selfEnroll(
            predecessorId: rootId,
            appName: 'sibling-app-$i',
            deviceName: 'sibling-dev-$i');
        expect(r.isError, false,
            reason: 'sibling $i must still be able to retrofit the root, no '
                'successor having authenticated and settled it yet: '
                '${r.errorMessage}');
      }
    });

    test('a predecessor its first successor has settled is not split again',
        () async {
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      final (firstId, firstKey) = await retrofitWithRealKey(predecessorId,
          appName: 'settled-app', deviceName: 'settled-dev');
      await authenticateAs(firstId, firstKey, sessionId: 'settled-session');
      expect((await enMgr.getEnrollmentById(firstId)).predecessorSettledAt,
          isNotNull,
          reason: 'precondition: the first successor has authenticated, and '
              'the settlement it recorded is what the refusal reads');

      await expectLater(
          () => selfEnroll(
              predecessorId: predecessorId,
              appName: 'settled-app-2',
              deviceName: 'settled-dev-2'),
          throwsA(isA<UnAuthorizedException>().having((e) => e.message,
              'message', contains('a second replacement is not allowed'))),
          reason: 'a superseded predecessor is revoked, and stays settled '
              'even if un-revoked; a sibling clone of the keyfile enrols '
              'over an OTP instead');
    });

    test('an un-revoked predecessor is still not split again', () async {
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      final (firstId, firstKey) = await retrofitWithRealKey(predecessorId,
          appName: 'revived-app', deviceName: 'revived-dev');
      await authenticateAs(firstId, firstKey, sessionId: 'revived-session');
      expect(await stateOf(predecessorId), EnrollmentStatus.revoked.name,
          reason: 'precondition: superseded');

      final k = enMgr.buildEnrollmentKey(predecessorId);
      final revived = (await keyValueStore.get(k))!;
      final value = EnrollDataStoreValue.fromJson(jsonDecode(revived.data!))
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      revived.data = jsonEncode(value.toJson());
      await enMgr.put(predecessorId, revived, EnrollmentStatus.approved);

      await expectLater(
          () => selfEnroll(
              predecessorId: predecessorId,
              appName: 'revived-app-2',
              deviceName: 'revived-dev-2'),
          throwsA(isA<UnAuthorizedException>().having((e) => e.message,
              'message', contains('a second replacement is not allowed'))),
          reason: 'an un-revoke restores the credential, not the once-off '
              'migration it has already spent; the approval check alone would '
              'let it through');
    });

    test('a ROOT predecessor is split again after its first successor '
        'authenticates', () async {
      final rootId = etu.primaryEnId;
      final (firstId, firstKey) = await retrofitWithRealKey(rootId,
          appName: 'root-split-app', deviceName: 'root-split-dev');
      await authenticateAs(firstId, firstKey,
          sessionId: 'root-split-session');
      expect((await enMgr.getEnrollmentById(firstId)).predecessorSettledAt,
          isNotNull,
          reason: 'precondition: the successor has authenticated and settled '
              'what it replaced');

      final r = await selfEnroll(
          predecessorId: rootId,
          appName: 'root-split-app-2',
          deviceName: 'root-split-dev-2');

      expect(r.isError, false,
          reason: 'a root is never revoked as a predecessor, so it keeps its '
              'life and stays splittable: ${r.errorMessage}');
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

  /// Who could still restore this atSign, asserted directly on the manager.
  group('hasUnexpiringRootEnrollment', () {
    Future<void> mint(String id, Map<String, String> namespaces,
        {Duration? ttl,
        EnrollmentStatus status = EnrollmentStatus.approved,
        String apkamPublicKey = 'pk'}) async {
      final v = EnrollDataStoreValue(
          's', 'app-$id', 'device-$id', apkamPublicKey)
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
      await mint('probe-longlived', {'*': 'rw', '__manage': 'rw'},
          ttl: Duration(days: 3650));
      expect(await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isFalse,
          reason: 'a finite root defers the stranding rather than preventing '
              'it, so it must not answer the question');
    });

    test('...while the same root with no expiry does', () async {
      // Control: identical grants and status, the only difference being the
      // ttl.
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

    test('a root holding NO APKAM public key does not count', () async {
      await mint('probe-keyless', {'*': 'rw', '__manage': 'rw'},
          apkamPublicKey: '');
      expect(await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isFalse,
          reason: 'a record nothing can authenticate as is not a root, '
              'whoever it is — the bar is not special to the legacy identity');
    });

    test('the FLAT credential does NOT count: it is a record by the time '
        'anyone asks', () async {
      await keyValueStore.put(AtConstants.atPkamPublicKey,
          AtData()..data = 'a flat credential somebody holds',
          skipCommit: true);
      expect(await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isFalse,
          reason: 'the question is asked of the roster alone');
    });

    test('...while primary, the record it becomes, does', () async {
      // Control: the same credential as the record the startup migration
      // makes of it.
      await enMgr.serialiseMutation(
          () => enMgr.mintPrimary('a flat credential somebody holds'));
      expect(await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isTrue,
          reason: 'an atSign whose owner authenticates as primary can mint a '
              'fresh enrollment, so it is not stranded');
    });

    test('...while the same root WITH a key does', () async {
      // Control, differing from the test above in the public key and in
      // nothing else.
      await mint('probe-keyless', {'*': 'rw', '__manage': 'rw'},
          apkamPublicKey: 'an APKAM public key somebody holds');
      expect(await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isTrue);
    });
  });

  /// Revoking an enrollment revokes everything it APPROVED, to any depth.
  group('revocation cascades to descendants', () {
    Future<String?> statusOf(String id) async =>
        (await enMgr.getEnrollmentById(id)).approval?.state;

    Future<String?> approverIdOf(String id) async =>
        (await enMgr.getEnrollmentById(id)).parentEnrollmentId;

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
    /// produce.
    Future<void> mintUnder(String id, String? predecessorId,
        {EnrollmentStatus status = EnrollmentStatus.approved,
        Duration? ttl,
        String apkamPublicKey = 'pk'}) async {
      final v = EnrollDataStoreValue(
          's', 'app-$id', 'device-$id', apkamPublicKey)
        ..namespaces = {'*': 'rw', '__manage': 'rw'}
        ..approval = EnrollApproval(status.name)
        ..retrofitPredecessorEnrollmentId = predecessorId;
      await enMgr.put(
          id,
          AtData()
            ..data = jsonEncode(v.toJson())
            ..metaData = (AtMetaData()..ttl = ttl?.inMilliseconds ?? 0),
          status);
    }

    /// A record written straight to the store, approved BY [approverId].
    Future<void> mintApprovedBy(String id, String? approverId,
        {EnrollmentStatus status = EnrollmentStatus.approved,
        Map<String, String> namespaces = const {'*': 'rw', '__manage': 'rw'},
        Duration? ttl}) async {
      final v = EnrollDataStoreValue('s', 'app-$id', 'device-$id', 'pk')
        ..namespaces = Map<String, String>.from(namespaces)
        ..approval = EnrollApproval(status.name)
        ..parentEnrollmentId = approverId;
      await enMgr.put(
          id,
          AtData()
            ..data = jsonEncode(v.toJson())
            ..metaData = (AtMetaData()..ttl = ttl?.inMilliseconds ?? 0),
          status);
    }

    /// An enrollment admitted by [approverId] through the real
    /// `enroll:request` + `enroll:approve` path.
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

    /// An approved enrollment that can itself approve: it holds `__manage`.
    Future<String> anApprover({String suffix = ''}) async {
      final id = await etu.createPendingEnrollment(
          appName: 'approver$suffix',
          deviceName: 'device$suffix',
          namespaces: {'__manage': 'rw', 'test': 'r'},
          apkamKeysExpiryDuration: null);
      await etu.approveEnrollment(etu.primaryEnId, id);
      return id;
    }

    /// [rootId] → a0 → a1 → …, links along the APPROVAL edge: each
    /// enrollment admitted by the one before it.
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
      await mintApprovedBy('link-a', null);
      await mintApprovedBy('link-b', 'link-a',
          status: EnrollmentStatus.revoked);
      await mintApprovedBy('link-c', 'link-b');

      final r = await revoke(etu.primaryEnId, 'link-a');
      expect(r.isError, false, reason: '${r.errorMessage}');
      expect(await statusOf('link-c'), EnrollmentStatus.revoked.name);
    });

    test('the cascade crosses an EXPIRED link', () async {
      await mintApprovedBy('exp-root', null);
      await mintApprovedBy('exp-mid', 'exp-root',
          ttl: Duration(milliseconds: 1));
      await mintApprovedBy('exp-leaf', 'exp-mid');
      await Future.delayed(Duration(milliseconds: 30));

      expect(
          (await enMgr.getAllEnrollmentKeys(includeExpired: false))
              .any((k) => k.contains('exp-mid')),
          isFalse,
          reason: 'precondition: the middle link is expired and therefore '
              'invisible to the VISIBLE roster — without this the test passes '
              'for the wrong reason');
      expect(
          (await enMgr.getAllEnrollmentKeys(includeExpired: true))
              .any((k) => k.contains('exp-mid')),
          isTrue,
          reason: 'and it is still on disk rather than reaped, which is what '
              'makes the two rosters disagree about it at all');

      final r = await revoke(etu.primaryEnId, 'exp-root');
      expect(r.isError, false, reason: '${r.errorMessage}');
      expect(await statusOf('exp-leaf'), EnrollmentStatus.revoked.name,
          reason: 'the walk climbs from each live candidate and fetches each '
              'link BY KEY, which returns an expired record, so an expired '
              'enrollment part-way up no longer severs the chain');
    });

    test('settling a predecessor re-parents a child whose ttl has elapsed',
        () async {
      await mintApprovedBy('rp-predecessor', etu.primaryEnId);
      await mintApprovedBy('rp-child', 'rp-predecessor',
          ttl: Duration(milliseconds: 1));
      await Future.delayed(Duration(milliseconds: 30));

      final String childKey = enMgr.buildEnrollmentKey('rp-child');
      expect(await keyValueStore.exists(childKey), isTrue,
          reason: 'precondition: STILL ON DISK — otherwise this is a test of '
              'deletion');
      expect(await enMgr.getAllEnrollmentKeys(includeExpired: false),
          isNot(contains(childKey)),
          reason: 'precondition: and invisible to the VISIBLE roster, which '
              'is the one variable');

      final r = await selfEnroll(
          predecessorId: 'rp-predecessor',
          apkamKeysExpiryDuration: Duration(minutes: 1));
      expect(r.isError, false, reason: '${r.errorMessage}');
      final String successor = jsonDecode(r.data!)['enrollmentId'] as String;

      await enMgr.settlePredecessorOnFirstAuth(successor);

      expect(await approverIdOf('rp-child'), successor,
          reason: 'the successor stands where its predecessor stood, and the '
              'predecessor is revoked; a child left naming it is orphaned');
    });

    test('a revoke whose cascade would remove the caller is refused', () async {
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
      // NOTE the keystore lowercases every key, so a non-canonical spelling
      // resolves to the SAME record.
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
      await mintUnder('short-root', null, ttl: Duration(minutes: 5));

      await expectLater(() => revoke('short-root', etu.primaryEnId),
          throwsA(isA<AtEnrollmentRevokeException>()),
          reason: 'the liveness question has to be asked for every revoke of '
              'a fully privileged enrollment, not only a self-revoke');
      expect(await statusOf(etu.primaryEnId), EnrollmentStatus.approved.name,
          reason: 'refused before anything is written');
    });

    test('…but a root that outlives the one it revokes may proceed', () async {
      // Control: same shape, same target, and the only difference is that
      // this caller has no expiry.
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
      // Control: the refusal is not merely 'self-revocation is refused'.
      await mintUnder('spare-root', null);
      final r = await revoke(etu.primaryEnId, etu.primaryEnId, force: true);
      expect(r.isError, false, reason: '${r.errorMessage}');
      expect(await statusOf(etu.primaryEnId), EnrollmentStatus.revoked.name);
    });

    test('…but a KEYLESS root does not license it', () async {
      await mintUnder('keyless-root', null, apkamPublicKey: '');

      await expectLater(
          () => revoke(etu.primaryEnId, etu.primaryEnId, force: true),
          throwsA(isA<AtEnrollmentRevokeException>()),
          reason: 'the atSign would be left with no root anything holds a '
              'credential for, which is the stranding this refusal exists '
              'for');
      expect(await statusOf(etu.primaryEnId), EnrollmentStatus.approved.name,
          reason: 'and refused before anything was written');
    });

    test('…while the same root WITH a key licenses it', () async {
      // Control for the pair, and the only difference is the public key.
      await mintUnder('keyless-root', null,
          apkamPublicKey: 'an APKAM public key somebody holds');

      final r = await revoke(etu.primaryEnId, etu.primaryEnId, force: true);
      expect(r.isError, false, reason: '${r.errorMessage}');
      expect(await statusOf(etu.primaryEnId), EnrollmentStatus.revoked.name);
    });

    test('primary licenses the last enrollment root\'s revoke', () async {
      await enMgr.serialiseMutation(
          () => enMgr.mintPrimary('a flat credential somebody holds'));

      final r = await revoke(etu.primaryEnId, etu.primaryEnId, force: true);
      expect(r.isError, false, reason: '${r.errorMessage}');
      expect(await statusOf(etu.primaryEnId), EnrollmentStatus.revoked.name,
          reason: 'primary is a usable root, so this act strands nobody');
    });

    test('…while a flat key still at its address does not', () async {
      await keyValueStore.put(AtConstants.atPkamPublicKey,
          AtData()..data = 'a flat credential somebody holds',
          skipCommit: true);

      await expectLater(
          () => revoke(etu.primaryEnId, etu.primaryEnId, force: true),
          throwsA(isA<AtEnrollmentRevokeException>()),
          reason: 'the question is asked of the roster alone');
      expect(await statusOf(etu.primaryEnId), EnrollmentStatus.approved.name,
          reason: 'and refused before anything was written');
    });

    test('an enrollment about to be cascaded away is not counted as the '
        'survivor', () async {
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

    /// The atSign's original root, rewritten with a finite life.
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
      // Control: the only difference is a permanent root that the act leaves
      // alone.
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
      await mintApprovedBy('owner-admitted', null,
          status: EnrollmentStatus.revoked);
      await etu.unrevokeEnrollment(etu.primaryEnId, 'owner-admitted');
      expect(await statusOf('owner-admitted'), EnrollmentStatus.approved.name);
    });

    test('…and neither is one whose approver is still approved', () async {
      // Control: this record DOES carry an approver.
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

      await Future.delayed(Duration(milliseconds: 50));
      await revoke(etu.primaryEnId, 'exp-approver');

      expect(await statusOf('exp-admitted'), EnrollmentStatus.revoked.name,
          reason: 'precondition: the cascade actually wrote this record');
      expect((await keyValueStore.get(ek))!.metaData!.expiresAt, before,
          reason: 'a revoke says nothing about expiry, and the metadata '
              'builder re-derives it from the retained ttl unless the stored '
              'value is asserted back — so a cascade would hand every '
              'enrollment it revoked a fresh full lifetime');
    });

    /// The revocation history: one record per moment an enrollment's
    /// revocation state changed.
    group('the revocation event log', () {
      Future<List<EnrollmentRevocationEvent>> eventsFor(String id) async =>
          (await enMgr.revocationEvents())
              .where((e) => e.enrollmentId == id)
              .toList();

      test('nothing is written until something is revoked', () async {
        // Control: the log does not record every enrollment operation.
        await etu.createEnrollments(n: 1);
        expect(await enMgr.revocationEvents(), isEmpty);
      });

      test('a supersession writes one event of its own kind, by the '
          'successor, with no cascade', () async {
        final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
        final grants = Map<String, String>.from(
            (await enMgr.getEnrollmentById(predecessorId)).namespaces);
        final (successorId, key) = await retrofitWithRealKey(predecessorId);
        final before = DateTime.now().toUtc();

        await authenticateAs(successorId, key, sessionId: 'supersede-log');

        final events = await eventsFor(predecessorId);
        expect(events, hasLength(1),
            reason: 'one event for the supersession, and no plain revoke '
                'beside it');
        final e = events.single;
        expect(e.type, EnrollmentRevocationEventType.superseded,
            reason: 'the history says what happened, not that the successor '
                'revoked its predecessor by name');
        expect(e.byEnrollmentId, successorId);
        expect(e.cascadedFrom, isNull);
        expect(e.namespaces, grants);
        expect(e.at.isBefore(before), isFalse);
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
        final ordinary = (await etu.createEnrollments(n: 1)).$1.first;
        await revoke(etu.primaryEnId, ordinary);

        final enrollmentKeys =
            await enMgr.getAllEnrollmentKeys(includeExpired: true);
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
        final holders = (await etu.createEnrollments(n: 2)).$1;
        await revoke(etu.primaryEnId, holders[1]);
        final DateTime at = (await eventsFor(holders[1])).single.at;
        expect(await enMgr.lastRevocationForNamespace('test'), at,
            reason: 'precondition');

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

    /// `enroll:infons:<ns>` answers facts about a NAMESPACE, where
    /// `enroll:listns` answers who holds it.
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

      test('a supersession counts as a revocation of what the predecessor '
          'held', () async {
        final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
        final namespace =
            (await enMgr.getEnrollmentById(predecessorId)).namespaces.keys.first;
        expect(await enMgr.lastRevocationForNamespace(namespace), isNull,
            reason: 'control: nothing holding $namespace has been revoked yet');
        final (successorId, key) = await retrofitWithRealKey(predecessorId);

        await authenticateAs(successorId, key, sessionId: 'supersede-infons');

        final supersededAt = (await enMgr.revocationEvents())
            .singleWhere((e) => e.enrollmentId == predecessorId)
            .at;
        expect(await enMgr.lastRevocationForNamespace(namespace), supersededAt,
            reason: 'a superseded credential stopped holding $namespace at '
                'that moment, and a client reading infons must learn it; an '
                'event kind read as a withdrawal would hide it');
      });

      /// The moment the LOG says [id] was revoked, read straight off the
      /// stored event rather than through the derivation under test.
      Future<DateTime> soleRevocationOf(String id) async {
        final es = (await enMgr.revocationEvents())
            .where((e) =>
                e.enrollmentId == id &&
                e.type != EnrollmentRevocationEventType.unrevoked)
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
        // Control: an explicit null is an answer to the question asked.
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
        // ⚠️ WIRE PIN. `enroll:listns` answers a JSON list and deployed
        // clients parse it by shape; a change here sweeps every parser.
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
        final holders = (await etu.createEnrollments(n: 2)).$1;
        await revoke(etu.primaryEnId, holders[1]);
        await soleRevocationOf(holders[1]); // precondition: there IS a
        // revocation to be wrongly reported.

        expect((await infons(holders[0], 'app_1'))['lastRevokedAt'], isNull,
            reason: 'the revoked enrollment does not hold app_1, so it says '
                'nothing about app_1');
        // Control: the same revocation IS reported for a namespace it did
        // hold.
        expect((await infons(holders[0], 'test'))['lastRevokedAt'], isNotNull);
      });

      test('the latest of several revocations is the one reported', () async {
        final holders = (await etu.createEnrollments(n: 3)).$1;
        await revoke(etu.primaryEnId, holders[1]);
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
        final successorId = await admittedBy(holders[1], suffix: '-infons');

        await revoke(etu.primaryEnId, holders[1]);

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
        final holders = (await etu.createEnrollments(n: 2)).$1;

        await expectLater(() => infons(holders[1], 'app_1'),
            throwsA(isA<UnAuthorizedException>()));

        // Control: the same caller may ask about a namespace it holds.
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

  /// `enroll:listns` and `enroll:infons` share one gate, and that gate asks
  /// the same namespace matcher the rest of the server asks.
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
      final caller = await enrollmentHolding('fg-star-control', {'*': 'rw'});
      final r = await rosterVerb('listns', caller, 'wavi');
      expect(r.isError, false,
          reason: 'the wildcard still admits an ordinary namespace; only '
              '__manage is withheld. Got: ${r.errorMessage}');
    });
  });

  group('the predecessor is settled by the successor\'s first authentication',
      () {
    test('a successor that never authenticates leaves its predecessor alone',
        () async {
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      await selfEnroll(predecessorId: predecessorId);

      expect(await stateOf(predecessorId), EnrollmentStatus.approved.name,
          reason: 'a retrofit whose keyfile never reached disk must not '
              'retire the credential that still works');
    });

    test(
        'the first authentication revokes the predecessor, through the real '
        'PKAM handler', () async {
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      final (successorId, key) = await retrofitWithRealKey(predecessorId);
      expect(await stateOf(predecessorId), EnrollmentStatus.approved.name,
          reason: 'control: approved right up until the successor proves '
              'itself, so the assertion below measures the authentication');

      await authenticateAs(successorId, key);

      expect(await stateOf(predecessorId), EnrollmentStatus.revoked.name,
          reason: 'the settlement is wired into the production PKAM path '
              'rather than merely implemented on EnrollmentManager');
      expect((await enMgr.getEnrollmentById(successorId)).predecessorSettledAt,
          isNotNull,
          reason: 'and the successor records that it settled');
    });

    test('a second authentication does not revoke an un-revoked predecessor '
        'again', () async {
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      final (successorId, key) = await retrofitWithRealKey(predecessorId);
      await authenticateAs(successorId, key, sessionId: 'first-session');
      expect(await stateOf(predecessorId), EnrollmentStatus.revoked.name,
          reason: 'control: the first authentication did revoke it');
      final settledAt =
          (await enMgr.getEnrollmentById(successorId)).predecessorSettledAt;

      final k = enMgr.buildEnrollmentKey(predecessorId);
      final revived = (await keyValueStore.get(k))!;
      final value = EnrollDataStoreValue.fromJson(jsonDecode(revived.data!))
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      revived.data = jsonEncode(value.toJson());
      await enMgr.put(predecessorId, revived, EnrollmentStatus.approved);

      await authenticateAs(successorId, key, sessionId: 'second-session');

      expect(await stateOf(predecessorId), EnrollmentStatus.approved.name,
          reason: 'a successor authenticates on every reconnect; settling '
              'on each one would revoke a deliberately un-revoked '
              'predecessor again');
      expect((await enMgr.getEnrollmentById(successorId)).predecessorSettledAt,
          settledAt,
          reason: 'the stamp records the FIRST settlement and does not move');
    });

    test('an enrollment that replaced nothing settles nothing', () async {
      await enMgr.settlePredecessorOnFirstAuth(etu.primaryEnId);

      expect(await stateOf(etu.primaryEnId), EnrollmentStatus.approved.name,
          reason: 'an enrollment with no predecessor must pass through the '
              'settlement untouched');
      expect((await enMgr.getEnrollmentById(etu.primaryEnId))
              .predecessorSettledAt,
          isNull);
    });

    test('the successor\'s OWN expiry is not restarted by the stamp',
        () async {
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

    test('a REVOKED predecessor is left as it is, and the successor is '
        'settled all the same', () async {
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
          reason: 'a revoked predecessor is already retired; nothing is '
              'written onto it');
      expect(await stateOf(predecessorId), EnrollmentStatus.revoked.name,
          reason: 'and it stays revoked');
      expect(
          (await enMgr.revocationEvents())
              .where((e) => e.enrollmentId == predecessorId)
              .map((e) => e.type),
          isNot(contains(EnrollmentRevocationEventType.superseded)),
          reason: 'a predecessor found revoked is not revoked again, so no '
              'supersession is recorded');
      expect((await enMgr.getEnrollmentById(successorId)).predecessorSettledAt,
          isNotNull,
          reason: 'settled all the same: an un-revoke later restores the '
              'predecessor, and the successor\'s next authentication must '
              'not take it away again');
    });

    // A fully privileged predecessor keeps its life, whatever the successor's
    // posture.
    for (final (label, posture) in const <(String, Duration?)>[
      ('never', null),
      ('one minute', Duration(minutes: 1)),
      ('29 days, just inside the grace', Duration(days: 29)),
      ('31 days, just past the grace', Duration(days: 31)),
      ('ten years', Duration(days: 3650)),
    ]) {
      test('a ROOT predecessor is not revoked by a successor expiring in $label',
          () async {
        final rootId = etu.primaryEnId;
        expect((await enMgr.getEnrollmentById(rootId)).isRootEnrollment, isTrue,
            reason: 'precondition: the predecessor is fully privileged, which '
                'is the whole condition');

        final (successorId, successorKey) = await retrofitWithRealKey(rootId,
            apkamKeysExpiryDuration: posture);
        await authenticateAs(successorId, successorKey,
            sessionId: 'root-posture-${posture?.inMinutes ?? 0}');

        expect(
            (await keyValueStore.get(enMgr.buildEnrollmentKey(rootId)))
                ?.metaData
                ?.expiresAt,
            isNull,
            reason: 'a root is never put on a clock');
        expect(await stateOf(rootId), EnrollmentStatus.approved.name,
            reason: 'and never revoked as a predecessor');
        expect(
            (await enMgr.getEnrollmentById(successorId)).predecessorSettledAt,
            isNotNull,
            reason: 'settled all the same: the stamp is what stops every later '
                'authentication re-asking, and what records that the '
                'root\'s children moved');
        expect(await enMgr.hasUnexpiringRootEnrollment({}), isTrue,
            reason: 'the atSign keeps a root it can restore itself from');
      });
    }

    test('a ROOT predecessor\'s children move onto its successor on the '
        'successor\'s first authentication', () async {
      final rootId = etu.primaryEnId;
      final childId = (await etu.createEnrollments(n: 1)).$1.first;
      expect(await enMgr.descendantsOf(rootId), contains(childId),
          reason: 'precondition: the fixture\'s enrollments are approved by '
              'the root');

      final (successorId, successorKey) = await retrofitWithRealKey(rootId);
      expect(await enMgr.descendantsOf(successorId), isNot(contains(childId)),
          reason: 'control: storing the successor moves nothing; the '
              'authentication does');

      await authenticateAs(successorId, successorKey,
          sessionId: 'root-adoption');

      expect(await enMgr.descendantsOf(successorId), contains(childId),
          reason: 'what the root admitted now hangs off its successor');
      expect(await enMgr.descendantsOf(rootId), isNot(contains(childId)));
      expect(
          (await keyValueStore.get(enMgr.buildEnrollmentKey(rootId)))
              ?.metaData
              ?.expiresAt,
          isNull,
          reason: 'and the root keeps its life');
    });

    test(
        'an ORDINARY predecessor is revoked even by a short-lived successor',
        () async {
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      final predecessorBefore = await enMgr.getEnrollmentById(predecessorId);
      expect(predecessorBefore.namespaces.containsKey('__manage'), isFalse,
          reason: 'precondition: an ordinary predecessor, not an approver, so '
              'revoking it strands nothing');

      final (successorId, successorKey) = await retrofitWithRealKey(predecessorId,
          apkamKeysExpiryDuration: Duration(minutes: 1));
      await authenticateAs(successorId, successorKey, sessionId: 'ordinary-short');

      expect(await stateOf(predecessorId), EnrollmentStatus.revoked.name,
          reason: 'a short-lived successor still retires an ordinary '
              'predecessor: there are other approvers behind it, so nothing '
              'is stranded and the migration must still make progress');
    });

    test(
        'an ordinary predecessor is revoked even when NOTHING could restore a '
        'root', () async {
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      expect((await enMgr.getEnrollmentById(predecessorId)).isRootEnrollment,
          isFalse,
          reason: 'precondition: an ordinary predecessor');

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
          reason: 'precondition: nothing could restore a root, so a revoke '
              'that asked the stranding question here would decline');

      final (successorId, successorKey) = await retrofitWithRealKey(predecessorId,
          apkamKeysExpiryDuration: Duration(minutes: 1));
      await authenticateAs(successorId, successorKey, sessionId: 'ordinary-noroot');

      expect(await stateOf(predecessorId), EnrollmentStatus.revoked.name,
          reason: 'the migration must still make progress for ordinary '
              'credentials, whatever state the atSign\'s roots are in');
    });

    test('a predecessor revoked between the decision and the write is not '
        'revoked twice, and the successor is settled', () async {
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      final (successorId, successorKey) =
          await retrofitWithRealKey(predecessorId);

      final key = enMgr.buildEnrollmentKey(predecessorId);
      final approved = (await keyValueStore.get(key))!;
      final approvedJson = jsonDecode(approved.data!) as Map<String, dynamic>;

      final revokedValue = EnrollDataStoreValue.fromJson(approvedJson)
        ..approval = EnrollApproval(EnrollmentStatus.revoked.name);
      await keyValueStore.put(
          key, AtData()..data = jsonEncode(revokedValue.toJson()));
      enMgr.atDataCache[key] = (approved, approvedJson);

      await authenticateAs(successorId, successorKey,
          sessionId: 'late-decline');

      expect(await stateOf(predecessorId), EnrollmentStatus.revoked.name);
      expect(
          (await enMgr.revocationEvents())
              .where((e) => e.enrollmentId == predecessorId)
              .map((e) => e.type),
          isNot(contains(EnrollmentRevocationEventType.superseded)),
          reason: 'the revoke reads the record it is about to write, not '
              'the cached snapshot the decision was made on');
      expect((await enMgr.getEnrollmentById(successorId)).predecessorSettledAt,
          isNotNull,
          reason: 'and the successor is settled, so nothing is re-asked');
    });

    test('a predecessor found revoked is settled for good: un-revoking it does '
        'not get it revoked by the next authentication', () async {
      final predecessorId = (await etu.createEnrollments(n: 1)).$1.first;
      final (successorId, successorKey) = await retrofitWithRealKey(predecessorId);

      final key = enMgr.buildEnrollmentKey(predecessorId);
      final atData = await keyValueStore.get(key);
      final value = EnrollDataStoreValue.fromJson(jsonDecode(atData!.data!));
      value.approval = EnrollApproval(EnrollmentStatus.revoked.name);
      atData.data = jsonEncode(value.toJson());
      await enMgr.put(predecessorId, atData, EnrollmentStatus.revoked);

      await authenticateAs(successorId, successorKey, sessionId: 'declined-1');
      expect((await enMgr.getEnrollmentById(successorId)).predecessorSettledAt,
          isNotNull,
          reason: 'settled: nothing was revoked, and nothing will be');

      final back = await keyValueStore.get(key);
      final restored = EnrollDataStoreValue.fromJson(jsonDecode(back!.data!));
      restored.approval = EnrollApproval(EnrollmentStatus.approved.name);
      back.data = jsonEncode(restored.toJson());
      await enMgr.put(predecessorId, back, EnrollmentStatus.approved);

      await authenticateAs(successorId, successorKey, sessionId: 'declined-2');
      expect(await stateOf(predecessorId), EnrollmentStatus.approved.name,
          reason: 'an un-revoke is an operator\'s decision, and the '
              'successor\'s next authentication must not overturn it');
    });

    test('a predecessor that is already gone is not an error, and its '
        'children still move', () async {
      final predecessorId = await etu.createPendingEnrollment(
          appName: 'gone-approver',
          deviceName: 'device',
          namespaces: {'__manage': 'rw', 'wavi': 'rw'},
          apkamKeysExpiryDuration: null);
      await etu.approveEnrollment(etu.primaryEnId, predecessorId);
      final childId = await etu.createPendingEnrollment(
          appName: 'gone-child',
          deviceName: 'device',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null);
      await etu.approveEnrollment(predecessorId, childId);
      final r = await selfEnroll(predecessorId: predecessorId);
      final successorId = jsonDecode(r.data!)['enrollmentId'] as String;

      await enMgr.remove(enId: predecessorId);
      await enMgr.settlePredecessorOnFirstAuth(successorId);

      expect((await enMgr.getEnrollmentById(successorId)).predecessorSettledAt,
          isNotNull,
          reason: 'stamped even with nothing to revoke, or every later '
              'connection re-walks the lookup for a predecessor that is '
              'never coming back');
      expect(await enMgr.descendantsOf(successorId), contains(childId),
          reason: 'the child was an orphan already, and the successor is what '
              'it should have been hanging off');
    });

    test('superseding an approver moves what it admitted onto its successor',
        () async {
      final middleId = await etu.createPendingEnrollment(
          appName: 'middle',
          deviceName: 'device',
          namespaces: {'__manage': 'rw', 'wavi': 'rw'},
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

      await enMgr.settlePredecessorOnFirstAuth(successorId);

      expect(await stateOf(middleId), EnrollmentStatus.revoked.name,
          reason: 'precondition: the predecessor really was superseded');
      expect(await enMgr.descendantsOf(successorId), contains(behindId),
          reason: 'the successor stands where its predecessor stood, so what '
              'the predecessor admitted hangs off it now');
      expect(await enMgr.descendantsOf(middleId), isNot(contains(behindId)),
          reason: 'and no longer off the record that is on its way out');

      await enMgr.remove(enId: middleId);
      expect(await enMgr.descendantsOf(etu.primaryEnId), contains(behindId),
          reason: 'revoking the root still reaches it, because the link the '
              'walk climbs through is the successor and the successor is live');
    });

    test('re-parenting a child leaves the child own expiry where it was',
        () async {
      final middleId = await etu.createPendingEnrollment(
          appName: 'middle-keeps-child-expiry',
          deviceName: 'device',
          namespaces: {'__manage': 'rw', 'wavi': 'rw'},
          apkamKeysExpiryDuration: null);
      await etu.approveEnrollment(etu.primaryEnId, middleId);

      final childId = await etu.createPendingEnrollment(
          appName: 'child-with-an-hour',
          deviceName: 'device',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: Duration(hours: 1));
      await etu.approveEnrollment(middleId, childId);

      final String childKey = enMgr.buildEnrollmentKey(childId);
      // NOTE the stored expiry is pulled in ahead of the hour its retained ttl
      // would re-derive.
      final DateTime shortened =
          DateTime.now().toUtc().add(Duration(minutes: 5));
      await enMgr.put(
          childId, (await keyValueStore.get(childKey))!,
          EnrollmentStatus.approved,
          assertedTimestamps: AtAssertedTimestamps(expiresAt: shortened));
      final DateTime? before =
          (await keyValueStore.get(childKey))?.metaData?.expiresAt;
      expect(before, isNotNull,
          reason: 'precondition: the child carries a bounded expiry for the '
              're-parenting to move');
      expect(before!.isBefore(DateTime.now().toUtc().add(Duration(minutes: 30))),
          isTrue,
          reason: 'precondition: the stored expiry sits well inside the hour '
              'the retained ttl would re-derive');

      final r = await selfEnroll(
          predecessorId: middleId,
          appName: 'middle-keeps-child-expiry',
          deviceName: 'device');
      expect(r.isError, false, reason: '${r.errorMessage}');
      final successorId = jsonDecode(r.data!)['enrollmentId'] as String;

      await enMgr.settlePredecessorOnFirstAuth(successorId);

      expect(await enMgr.descendantsOf(successorId), contains(childId),
          reason: 'precondition: the child really was re-parented, so the '
              'write under test happened');
      expect((await keyValueStore.get(childKey))?.metaData?.expiresAt, before,
          reason: 're-parenting rewrote the child record and let its expiry '
              'be re-derived, so a child with an hour left gained or lost '
              'time it was never granted');
    });
  });
  // The stored roster versus the visible one. `getKeys` filters out records
  // whose ttl has elapsed but which the sweep has not yet removed; `get` and
  // `exists` do not.
  group('the roster a decision reads', () {
    /// An approved enrollment holding [apkamPublicKey], minted through the
    /// real request-and-approve path.
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
      final String id = jsonDecode(r.data!)['enrollmentId'] as String;
      await etu.approveEnrollment(etu.primaryEnId, id);
      return id;
    }

    /// Moves [enId]'s expiry into the past WITHOUT removing the record.
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

    test('an elapsed enrollment keeps its encryption keys until it is reaped',
        () async {
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
      // Control: the sweep is still deleting.
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
      final String holder =
          await enrollmentHolding('k', appName: 'leaky', deviceName: 'device');
      final String leak =
          enMgr.keyForLegacyPK(await enMgr.getEnrollmentById(holder));
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
}
