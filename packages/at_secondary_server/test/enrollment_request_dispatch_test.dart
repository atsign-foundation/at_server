import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'enrollment_test_utils.dart';
import 'test_utils.dart';

/// Which branch of `enroll:request` a connection takes, and what selects it:
/// the CRAM auto-approve by auth type, and the retrofit branch, the
/// (appName, deviceName) skip and the mandatory-namespace exemption by the
/// enrollment the connection carries. All four connection shapes the server
/// produces are covered.
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

  /// An approved enrollment holding [namespaces], admitted by the root.
  Future<String> approved(Map<String, String> namespaces) async {
    final String id = await etu.createPendingEnrollment(
        appName: 'app-${Uuid().v4()}',
        deviceName: 'device',
        namespaces: namespaces,
        apkamKeysExpiryDuration: null);
    await etu.approveEnrollment(etu.primaryEnId, id);
    return id;
  }

  /// Sends `enroll:request` with [namespaces] (absent when null) over a
  /// connection of [authType] carrying [enrollmentId], reporting a thrown
  /// refusal as an error response.
  Future<Response> request(
      {required AuthType? authType,
      required String? enrollmentId,
      Map<String, String>? namespaces,
      String? otp}) async {
    final EnrollParams ep = EnrollParams()
      ..appName = 'dispatch-${Uuid().v4()}'
      ..deviceName = 'device'
      ..apkamPublicKey = 'key-${Uuid().v4()}'
      ..encryptedAPKAMSymmetricKey = 'wrapped'
      ..namespaces = namespaces
      ..otp = otp;
    inboundConnection.metaData
      ..isAuthenticated = authType != null
      ..authType = authType
      ..sessionID = DateTime.now().millisecondsSinceEpoch.toString();
    inboundConnection.metadata.enrollmentId = enrollmentId;
    final r = Response();
    try {
      await etu.evh.processVerb(
          r,
          getVerbParam(
              VerbSyntax.enroll, 'enroll:request:${jsonEncode(ep.toJson())}'),
          inboundConnection);
    } on AtException catch (e) {
      r.isError = true;
      r.errorMessage = '${e.runtimeType}: ${e.message}';
    }
    return r;
  }

  Future<EnrollDataStoreValue> recordOf(Response r) async =>
      enMgr.getEnrollmentById(jsonDecode(r.data!)['enrollmentId'] as String);

  group('what selects the branch', () {
    test('carriesEnrollment is a non-empty enrollment id on an authenticated '
        'connection', () {
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metadata.enrollmentId = null;
      expect(EnrollVerbHandler.carriesEnrollment(inboundConnection.metadata),
          isFalse);
      inboundConnection.metadata.enrollmentId = '';
      expect(EnrollVerbHandler.carriesEnrollment(inboundConnection.metadata),
          isFalse);
      inboundConnection.metadata.enrollmentId = 'some-id';
      expect(EnrollVerbHandler.carriesEnrollment(inboundConnection.metadata),
          isTrue);
      inboundConnection.metaData.isAuthenticated = false;
      expect(EnrollVerbHandler.carriesEnrollment(inboundConnection.metadata),
          isFalse,
          reason: 'an id on an unauthenticated connection names nothing the '
              'connection proved');
    });

    test('a CRAM connection takes the auto-approve, by auth type', () async {
      final r = await request(
          authType: AuthType.cram,
          enrollmentId: etu.primaryEnId,
          namespaces: {'wavi': 'rw'});

      expect(r.isError, isFalse, reason: r.errorMessage);
      final v = await recordOf(r);
      expect(v.approval?.state, EnrollmentStatus.approved.name);
      expect(v.namespaces['__manage'], 'rw',
          reason: 'the auto-approve confers the root grants');
      expect(v.namespaces['*'], 'rw');
      expect(v.retrofitPredecessorEnrollmentId, isNull,
          reason: 'minted, not a replacement of the enrollment carried');
    });

    test('an APKAM connection carrying its enrollment takes the retrofit',
        () async {
      final String predecessor = await approved({'wavi': 'rw'});

      final r = await request(
          authType: AuthType.apkam, enrollmentId: predecessor);

      expect(r.isError, isFalse, reason: r.errorMessage);
      final v = await recordOf(r);
      expect(v.approval?.state, EnrollmentStatus.approved.name);
      expect(v.retrofitPredecessorEnrollmentId, predecessor);
      expect(v.namespaces, {'wavi': 'rw'},
          reason: 'inherited from the predecessor, not chosen');
    });

    test('a legacy-PKAM connection carrying an enrollment takes the retrofit '
        'too: the branch is keyed on the enrollment, not the auth type',
        () async {
      final String predecessor = await approved({'wavi': 'rw', 'buzz': 'r'});

      final r = await request(
          authType: AuthType.pkamLegacy, enrollmentId: predecessor);

      expect(r.isError, isFalse, reason: r.errorMessage);
      final v = await recordOf(r);
      expect(v.approval?.state, EnrollmentStatus.approved.name,
          reason: 'the retrofit auto-approves under the predecessor\'s '
              'authority');
      expect(v.retrofitPredecessorEnrollmentId, predecessor);
      expect(v.namespaces, {'wavi': 'rw', 'buzz': 'r'},
          reason: 'never empty: a request that states nothing inherits, and '
              'a record holding no grants is one no caller can ever '
              'demonstrate authority over');
    });

    test('a connection carrying no enrollment takes the standard path, and '
        'must name a namespace', () async {
      final refused = await request(
          authType: AuthType.pkamLegacy, enrollmentId: null);
      expect(refused.isError, isTrue,
          reason: 'no enrollment to inherit from, so the request must choose');
      expect(refused.errorMessage,
          contains('At least one namespace must be specified'));

      final r = await request(
          authType: AuthType.pkamLegacy,
          enrollmentId: null,
          namespaces: {'wavi': 'rw'});
      expect(r.isError, isFalse, reason: r.errorMessage);
      final v = await recordOf(r);
      expect(v.approval?.state, EnrollmentStatus.pending.name,
          reason: 'the standard path stores a pending request for an '
              'approver');
      expect(v.retrofitPredecessorEnrollmentId, isNull);
    });

    test('an unauthenticated connection with an OTP takes the standard path',
        () async {
      final r = await request(
          authType: null,
          enrollmentId: null,
          namespaces: {'wavi': 'rw'},
          otp: await etu.getOtp());

      expect(r.isError, isFalse, reason: r.errorMessage);
      expect((await recordOf(r)).approval?.state,
          EnrollmentStatus.pending.name);
    });
  });

  group('the (appName, deviceName) skip travels with the retrofit branch', () {
    test('a retrofit may re-use its predecessor\'s names, whatever '
        'authenticated the connection', () async {
      for (final authType in [AuthType.apkam, AuthType.pkamLegacy]) {
        inboundConnection.metadata.enrollmentId = etu.primaryEnId;
        final String predecessorId = await etu.createPendingEnrollment(
            appName: 'shared-${authType.name}',
            deviceName: 'device',
            namespaces: {'wavi': 'rw'},
            apkamKeysExpiryDuration: null);
        await etu.approveEnrollment(etu.primaryEnId, predecessorId);

        final EnrollParams ep = EnrollParams()
          ..appName = 'shared-${authType.name}'
          ..deviceName = 'device'
          ..apkamPublicKey = 'key-${Uuid().v4()}';
        inboundConnection.metaData
          ..isAuthenticated = true
          ..authType = authType
          ..sessionID = DateTime.now().millisecondsSinceEpoch.toString();
        inboundConnection.metadata.enrollmentId = predecessorId;
        final r = Response();
        await etu.evh.processVerb(
            r,
            getVerbParam(VerbSyntax.enroll,
                'enroll:request:${jsonEncode(ep.toJson())}'),
            inboundConnection);

        expect(r.isError, isFalse,
            reason: '${authType.name}: ${r.errorMessage}');
        expect((await recordOf(r)).retrofitPredecessorEnrollmentId,
            predecessorId);
      }
    });

    test('a connection carrying no enrollment may not', () async {
      await etu.createPendingEnrollment(
          appName: 'taken',
          deviceName: 'device',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null);

      final EnrollParams ep = EnrollParams()
        ..appName = 'taken'
        ..deviceName = 'device'
        ..apkamPublicKey = 'key-${Uuid().v4()}'
        ..namespaces = {'wavi': 'rw'};
      inboundConnection.metaData
        ..isAuthenticated = true
        ..authType = AuthType.pkamLegacy
        ..sessionID = DateTime.now().millisecondsSinceEpoch.toString();
      inboundConnection.metadata.enrollmentId = null;
      final r = Response();
      Object? thrown;
      try {
        await etu.evh.processVerb(
            r,
            getVerbParam(VerbSyntax.enroll,
                'enroll:request:${jsonEncode(ep.toJson())}'),
            inboundConnection);
      } catch (e) {
        thrown = e;
      }

      expect(thrown, isA<IllegalStateException>(),
          reason: 'the standard path still refuses a taken '
              '(appName, deviceName)');
      expect((thrown as IllegalStateException).message,
          contains('Another enrollment with id'));
    });
  });
}
