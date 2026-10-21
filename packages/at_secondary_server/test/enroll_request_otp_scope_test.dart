import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/otp_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

/// Catalogue: features/enrollment/enroll_request_otp_scope.feature
void main() {
  setUp(() async => await verbTestsSetUp());
  tearDown(() async => await verbTestsTearDown());

  /// A CRAM connection of @alice's, which may issue an OTP and set the SPP.
  DummyInboundConnection cram() => DummyInboundConnection()
    ..metadata.isAuthenticated = true
    ..metadata.authType = AuthType.cram
    ..metadata.sessionID = 'cram-${Uuid().v4()}';

  DummyInboundConnection unauthenticated() => DummyInboundConnection()
    ..metadata.isAuthenticated = false
    ..metadata.sessionID = 'unauthenticated-${Uuid().v4()}';

  Future<String> otp(String command) async {
    final Response response = Response();
    await OtpVerbHandler(keyValueStore)
        .processVerb(response, getVerbParam(VerbSyntax.otp, command), cram());
    return response.data!;
  }

  /// Stores OTP [passcode] as otp:get does for an enrollment holding
  /// [namespaces].
  Future<void> otpIssuedWith(
          String passcode, Map<String, String> namespaces) =>
      OtpVerbHandler(keyValueStore).savePasscode(passcode,
          ttl: 60000, isSpp: false, namespaces: namespaces);

  /// Sends an enroll:request with [passcode] for [namespaces] on a new
  /// unauthenticated connection, answering its status.
  Future<String> request(
      String passcode, Map<String, String> namespaces) async {
    final Response response = Response();
    await EnrollVerbHandler(keyValueStore, enMgr, notificationManager)
        .processVerb(
            response,
            getVerbParam(
                VerbSyntax.enroll,
                'enroll:request:{"appName":"app-${Uuid().v4()}"'
                ',"deviceName":"device"'
                ',"namespaces":${jsonEncode(namespaces)}'
                ',"otp":"$passcode"'
                ',"apkamPublicKey":"apkam-${Uuid().v4()}"'
                ',"encryptedAPKAMSymmetricKey":"symmetric"}'),
            unauthenticated());
    return jsonDecode(response.data!)['status'];
  }

  final Matcher refusedAsInvalidOtp = throwsA(predicate((dynamic e) =>
      e is IllegalArgumentException &&
      e.message == 'invalid otp. Cannot process enroll request'));

  // NOTE UnAuthorizedException is what the atServer answers as AT0009.
  final Matcher refusedAsBeyondOtp = throwsA(predicate((dynamic e) =>
      e is UnAuthorizedException &&
      e.message ==
          'enroll:request asks for namespaces the OTP it presents does not'
              ' cover'));

  test('An OTP admits a request within its namespaces', () async {
    await otpIssuedWith('ABC123', {'wavi': 'rw', '__manage': 'rw'});
    expect(await request('ABC123', {'wavi': 'r'}), 'pending');
  });

  test('An OTP refuses a namespace it does not hold, and is spent', () async {
    await otpIssuedWith('ABC123', {'wavi': 'rw', '__manage': 'rw'});
    await expectLater(request('ABC123', {'buzz': 'rw'}), refusedAsBeyondOtp);
    await expectLater(request('ABC123', {'wavi': 'r'}), refusedAsInvalidOtp);
  });

  test('An OTP refuses more access than it holds', () async {
    await otpIssuedWith('ABC123', {'*': 'r', '__manage': 'rw'});
    await expectLater(request('ABC123', {'wavi': 'rw'}), refusedAsBeyondOtp);
  });

  test('An OTP holding * does not cover __manage', () async {
    await otpIssuedWith('ABC123', {'*': 'rw'});
    await expectLater(
        request('ABC123', {'__manage': 'r'}), refusedAsBeyondOtp);
  });

  test("An OTP's namespaces are compared as the keystore folds them",
      () async {
    await otpIssuedWith('ABC123', {'Wavi': 'rw', '__manage': 'rw'});
    expect(await request('ABC123', {'wavi': 'rw'}), 'pending');
  });

  group('A passcode carrying no namespaces does not limit the request', () {
    test('the SPP, set with otp:put', () async {
      await otp('otp:put:SPP111');
      expect(await request('SPP111', {'buzz': 'rw'}), 'pending');
    });

    test('an OTP issued with otp:get over CRAM', () async {
      final String passcode = await otp('otp:get');
      expect(await request(passcode, {'buzz': 'rw'}), 'pending');
    });

    test('an OTP stored before OTPs recorded namespaces, as a bare value',
        () async {
      await keyValueStore.put(
          OtpVerbHandler.passcodeKey('OLD123', isSpp: false),
          AtData()..data = 'OLD123');
      expect(await request('OLD123', {'buzz': 'rw'}), 'pending');
    });
  });
}