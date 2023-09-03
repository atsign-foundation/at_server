import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/otp_verb_handler.dart';
import 'package:expire_cache/expire_cache.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  group('A group of tests to verify OTP generation and expiration', () {
    setUp(() async {
      await verbTestsSetUp();
    });
    test('A test to verify OTP generated is 6-character length', () {
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      inboundConnection.getMetaData().isAuthenticated = true;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(response.data, isNotNull);
      expect(response.data!.length, 6);
      assert(RegExp('\\d').hasMatch(response.data!));
    });

    test('A test to verify same OTP is not returned', () {
      Set<String> otpSet = {};
      for (int i = 1; i <= 1000; i++) {
        Response response = Response();
        HashMap<String, String?> verbParams =
            getVerbParam(VerbSyntax.otp, 'otp:get');
        inboundConnection.getMetaData().isAuthenticated = true;
        OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
        otpVerbHandler.processVerb(response, verbParams, inboundConnection);
        expect(response.data, isNotNull);
        expect(response.data!.length, 6);
        assert(RegExp('\\d').hasMatch(response.data!));
        bool isUnique = otpSet.add(response.data!);
        expect(isUnique, true);
      }
      expect(otpSet.length, 1000);
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
      OtpVerbHandler.cache =
          ExpireCache(expireDuration: Duration(microseconds: 1));
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(secondaryKeyStore);
      print(OtpVerbHandler.cache.expireDuration.inMicroseconds);
      await Future.delayed(Duration(microseconds: 2));
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:validate:${response.data}');
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(response.data, 'invalid');
    });
    tearDown(() async => await verbTestsTearDown());
  });
}
