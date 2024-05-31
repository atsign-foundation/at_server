@Timeout(const Duration(minutes: 10))
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

import 'sync_unit_test.dart';
import 'test_utils.dart';

void main() {
  group('A group of tests to verify OTP generation and expiration', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test('Verify that otp:get requires authentication', () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = false;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      expect(
          otpVerbHandler.processVerb(response,
              getVerbParam(VerbSyntax.otp, 'otp:get'), inboundConnection),
          throwsA(predicate((dynamic e) => e is UnAuthenticatedException)));
    });
    test('Verify that otp:get with ttl requires authentication', () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = false;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      expect(
          otpVerbHandler.processVerb(
              response,
              getVerbParam(VerbSyntax.otp, 'otp:get:ttl:1000'),
              inboundConnection),
          throwsA(predicate((dynamic e) => e is UnAuthenticatedException)));
    });
    test('Verify that otp:put requires authentication', () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = false;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      expect(
          otpVerbHandler.processVerb(
              response,
              getVerbParam(VerbSyntax.otp, 'otp:put:abcdef'),
              inboundConnection),
          throwsA(predicate((dynamic e) => e is UnAuthenticatedException)));
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
      expect(await otpVerbHandler.isPasscodeValid(otp), true);
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
      expect(await otpVerbHandler.isPasscodeValid(otp), false);
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests to verify exceptions', () {
    setUp(() async {
      await verbTestsSetUp();
    });
    test(
        'A test to verify UnAuthorizedException is thrown when opt:get is executed on an unauthenticated conn',
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
              e.message == 'otp: requires authenticated connection')));
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
      expect(await otpVerbHandler.isPasscodeValid(response.data), true);
    });

    test('A test to verify otp:validate returns invalid when OTP is expired',
        () async {
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get:ttl:1');
      inboundConnection.metaData.isAuthenticated = true;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      String? otp = response.data;
      await Future.delayed(Duration(milliseconds: 2));
      expect(await otpVerbHandler.isPasscodeValid(otp), false);
    });

    test('A test to verify default otp expiry not overwritten', () async {
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get:ttl:1');
      inboundConnection.metaData.isAuthenticated = true;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      AtData? atData = await secondaryKeyStore.get(
          'private:${response.data}.${OtpVerbHandler.otpNamespace}$atSign');
      expect(atData?.metaData?.ttl, 1);

      verbParams = getVerbParam(VerbSyntax.otp, 'otp:get');
      inboundConnection.metaData.isAuthenticated = true;
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      atData = await secondaryKeyStore.get(
          'private:${response.data}.${OtpVerbHandler.otpNamespace}$atSign');
      expect(atData?.metaData?.ttl,
          OtpVerbHandler.defaultOtpExpiry.inMilliseconds);
    });

    test(
        'A test to verify otp:validate return invalid when otp does not exist in keystore',
        () async {
      String otp = 'ABC123';
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      expect(await otpVerbHandler.isPasscodeValid(otp), false);
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
      expect(await otpVerbHandler.isPasscodeValid(otp), true);
      expect(await otpVerbHandler.isPasscodeValid(otp), false);
    });

    test('validate backwards compatability with legacy otp key', () async {
      String atsign = '@alice';
      String testOtp = 'ABCD12';
      String otpLegacyKey = 'private:${testOtp.toLowerCase()}$atsign';
      AtData value = AtData()
        ..data = testOtp
        ..metaData = (AtMetaData()
          ..ttl = OtpVerbHandler.defaultOtpExpiry.inMilliseconds);
      await secondaryKeyStore.put(otpLegacyKey, value);

      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      expect(await otpVerbHandler.isPasscodeValid(testOtp), true);
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
      expect(await otpVerbHandler.isPasscodeValid(passcode), true);
      // Adding expect again to ensure the Semi-permanent passcodes are not deleted
      // after one time use.
      expect(await otpVerbHandler.isPasscodeValid(passcode), true);
    });

    test('set spp with a ttl, check isOTPValid before ttl expires', () async {
      String passcode = 'SppWithTtl50';
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:put:$passcode:ttl:50');
      inboundConnection.metaData.isAuthenticated = true;
      (inboundConnection.metaData as InboundConnectionMetadata).enrollmentId =
          enrollmentId;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(await otpVerbHandler.isPasscodeValid(passcode), true);
      // Adding expect again to ensure the Semi-permanent passcodes are not deleted
      // after one time use.
      await Future.delayed(Duration(milliseconds: 10));
      expect(await otpVerbHandler.isPasscodeValid(passcode), true);
    });

    test('set spp with a ttl, check isOTPValid before and after ttl expires',
        () async {
      String passcode = 'SppWithTtl50';
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:put:$passcode:ttl:50');
      inboundConnection.metaData.isAuthenticated = true;
      (inboundConnection.metaData as InboundConnectionMetadata).enrollmentId =
          enrollmentId;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(await otpVerbHandler.isPasscodeValid(passcode), true);
      // Adding expect again to ensure the Semi-permanent passcodes are not deleted
      // after one time use.
      expect(await otpVerbHandler.isPasscodeValid(passcode), true);

      await Future.delayed(Duration(milliseconds: 51));
      expect(await otpVerbHandler.isPasscodeValid(passcode), false);
    });

    test('set spp without a ttl, verify its ttl has been set to -1', () async {
      String passcode = 'SppWithoutTtl';
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:put:$passcode');
      inboundConnection.metaData.isAuthenticated = true;
      (inboundConnection.metaData as InboundConnectionMetadata).enrollmentId =
          enrollmentId;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      await Future.delayed(Duration(milliseconds: 2));
      expect(await otpVerbHandler.isPasscodeValid(passcode), true);

      String sppKey = OtpVerbHandler.passcodeKey(passcode, isSpp: true);
      var atData = await secondaryKeyStore.get(sppKey);
      expect(atData?.metaData?.ttl, -1);
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
      expect(await otpVerbHandler.isPasscodeValid(passcode), true);
      // Update the pass-code
      passcode = 'xyz987';
      response = Response();
      verbParams = getVerbParam(VerbSyntax.otp, 'otp:put:$passcode');
      otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(await otpVerbHandler.isPasscodeValid(passcode), true);
    });

    test('validate backwards compatability with legacy ssp key', () async {
      String atsign = '@alice';
      String testOtp = 'ABC123';
      String otpLegacyKey = 'private:spp$atsign';
      AtData value = AtData()..data = testOtp;
      await secondaryKeyStore.put(otpLegacyKey, value);

      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      expect(await otpVerbHandler.isPasscodeValid(testOtp), true);
    });
    tearDown(() async => await verbTestsTearDown());
  });
}
