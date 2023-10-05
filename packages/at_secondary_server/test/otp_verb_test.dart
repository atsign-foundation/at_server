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
          getVerbParam(VerbSyntax.otp, 'otp:get:ttl:1');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      String? otp = response.data;
      verbParams = getVerbParam(VerbSyntax.otp, 'otp:validate:$otp');
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(response.data, 'valid');
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
      verbParams = getVerbParam(VerbSyntax.otp, 'otp:validate:$otp');
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(response.data, 'invalid');
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

  group('A group of tests related to otp:validate', () {
    setUp(() async {
      await verbTestsSetUp();
    });
    test('A test to verify otp:validate returns valid when OTP is active',
        () async {
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      inboundConnection.getMetaData().isAuthenticated = true;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:validate:${response.data}');
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(response.data, 'valid');
    });

    test('A test to verify otp:validate returns invalid when OTP is expired',
        () async {
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      inboundConnection.getMetaData().isAuthenticated = true;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      otpVerbHandler.otpExpiryDuration = Duration(microseconds: 1);
      await Future.delayed(Duration(microseconds: 3));
      String? otp = response.data;
      response = Response();
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      verbParams = getVerbParam(VerbSyntax.otp, 'otp:validate:$otp');
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(response.data, 'invalid');
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to gc on otp store', () {
    setUp(() async {
      await verbTestsSetUp();
    });

    test('A test to verify gc removes the expired keys from the otp store',
        () async {
      Response response = Response();
      inboundConnection.getMetaData().isAuthenticated = true;

      OtpVerbHandler otpVerbHandler =
          OtpVerbHandler(secondaryKeyStore, gcDuration: Duration(seconds: 2));

      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get:ttl:1');
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      String? firstOTP = response.data;
      expect(firstOTP, isNotEmpty);

      verbParams = getVerbParam(VerbSyntax.otp, 'otp:get:ttl:30');
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      String? secondOTP = response.data;
      expect(secondOTP, isNotEmpty);

      await Future.delayed(Duration(seconds: 2));
      expect(otpVerbHandler.size(), 1);

      verbParams = getVerbParam(VerbSyntax.otp, 'otp:validate:$firstOTP');
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(response.data, 'invalid');

      verbParams = getVerbParam(VerbSyntax.otp, 'otp:validate:$secondOTP');
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(response.data, 'valid');
    });
    tearDown(() async => await verbTestsTearDown());
  });
}
