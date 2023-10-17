import 'dart:collection';

import 'package:at_commons/at_commons.dart';
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
      inboundConnection.getMetaData().isAuthenticated = true;
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
        inboundConnection.getMetaData().isAuthenticated = true;
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
      inboundConnection.getMetaData().isAuthenticated = true;
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
      inboundConnection.getMetaData().isAuthenticated = true;
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
        'A test to verify UnAuthorizedException is thrown when topt verb is executed on an unauthenticated conn',
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
      inboundConnection.getMetaData().isAuthenticated = true;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(await otpVerbHandler.isOTPValid(response.data), true);
    });

    test('A test to verify otp:validate returns invalid when OTP is expired',
        () async {
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      inboundConnection.getMetaData().isAuthenticated = true;
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
    tearDown(() async => await verbTestsTearDown());
  });
}
