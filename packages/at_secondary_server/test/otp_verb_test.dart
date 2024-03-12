import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/constants/enroll_constants.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/otp_verb_handler.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  group('A group of tests to verify OTP generation and expiration', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test('A test to verify OTP generated is 6-character length', () async {
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      inboundConnection.metaData.isAuthenticated = true;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(response.data, isNotNull);
      expect(response.data!.length, 6);
      assert(RegExp('\\d').hasMatch(response.data!));
    });

    test('A test to verify same OTP is not returned', () async {
      Set<String> otpSet = {};
      for (int i = 1; i <= 1000; i++) {
        Response response = Response();
        HashMap<String, String?> verbParams =
            getVerbParam(VerbSyntax.otp, 'otp:get');
        inboundConnection.metaData.isAuthenticated = true;
        OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
        await otpVerbHandler.processVerb(
            response, verbParams, inboundConnection);
        expect(response.data, isNotNull);
        expect(response.data!.length, 6);
        assert(RegExp('\\d').hasMatch(response.data!));
        bool isUnique = otpSet.add(response.data!);
        expect(isUnique, true);
      }
      expect(otpSet.length, 1000);
    });

    test('A test to verify otp:get with TTL set is active before TTL is met',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get:ttl:1000');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      String? otp = response.data;
      expect(await otpVerbHandler.isOTPValid(otp), true);
    });

    test('A test to verify otp:get with TTL set expires after the TTL is met',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get:ttl:1');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      String? otp = response.data;
      await Future.delayed(Duration(seconds: 1));
      expect(await otpVerbHandler.isOTPValid(otp), false);
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests to verify exceptions', () {
    setUp(() async {
      await verbTestsSetUp();
    });
    test(
        'A test to verify UnAuthorizedException is thrown when opt verb is executed on an unauthenticated conn',
        () {
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      expect(
          () => otpVerbHandler.processVerb(
              response, verbParams, inboundConnection),
          throwsA(predicate((e) =>
              e is UnAuthenticatedException &&
              e.message == 'otp:get requires authenticated connection')));
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to OTP validity', () {
    setUp(() async {
      await verbTestsSetUp();
    });
    test('A test to verify isOTPValid method returns valid when OTP is active',
        () async {
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      inboundConnection.metaData.isAuthenticated = true;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(await otpVerbHandler.isOTPValid(response.data), true);
    });

    test('A test to verify otp:validate returns invalid when OTP is expired',
        () async {
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      inboundConnection.metaData.isAuthenticated = true;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      otpVerbHandler.otpExpiryInMills = 1;
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      String? otp = response.data;
      await Future.delayed(Duration(milliseconds: 2));
      expect(await otpVerbHandler.isOTPValid(otp), false);
    });

    test(
        'A test to verify otp:validate return invalid when otp does not exist in keystore',
        () async {
      String otp = 'ABC123';
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      expect(await otpVerbHandler.isOTPValid(otp), false);
    });

    test('A test to verify otp is removed from the keystore after use',
        () async {
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      inboundConnection.metaData.isAuthenticated = true;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      String? otp = response.data;
      expect(await otpVerbHandler.isOTPValid(otp), true);
      expect(await otpVerbHandler.isOTPValid(otp), false);
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to semi-permanent pass codes', () {
    String enrollmentId = 'dummy-enrollment-key';
    setUp(() async {
      await verbTestsSetUp();
      String enrollmentKey =
          '$enrollmentId.$newEnrollmentKeyPattern.$enrollManageNamespace$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'dummy_session_id', 'dummy-app', 'dummy-device', 'dummy-apkam-key')
        ..namespaces = {enrollManageNamespace: 'rw'}
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      await secondaryKeyStore.put(
          enrollmentKey, AtData()..data = jsonEncode(enrollDataStoreValue));
    });
    test('A test to set a pass code and verify isOTPValid returns true',
        () async {
      String passcode = 'abc123';
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:put:$passcode');
      inboundConnection.metaData.isAuthenticated = true;
      (inboundConnection.metaData as InboundConnectionMetadata).enrollmentId =
          enrollmentId;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(await otpVerbHandler.isOTPValid(passcode), true);
      // Adding expect again to ensure the Semi-permanent passcodes are not deleted
      // after one time use.
      expect(await otpVerbHandler.isOTPValid(passcode), true);
    });

    test('A test to verify pass code can be updated', () async {
      String passcode = 'abc123';
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:put:$passcode');
      inboundConnection.metaData.isAuthenticated = true;
      (inboundConnection.metaData as InboundConnectionMetadata).enrollmentId =
          enrollmentId;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(await otpVerbHandler.isOTPValid(passcode), true);
      // Update the pass-code
      passcode = 'xyz987';
      response = Response();
      verbParams = getVerbParam(VerbSyntax.otp, 'otp:put:$passcode');
      otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(await otpVerbHandler.isOTPValid(passcode), true);
    });
    tearDown(() async => await verbTestsTearDown());
  });
}
