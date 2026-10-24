import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/info_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/otp_verb_handler.dart';
import 'package:test/test.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;

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
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      expect(
          otpVerbHandler.processVerb(response,
              getVerbParam(VerbSyntax.otp, 'otp:get'), inboundConnection),
          throwsA(predicate((dynamic e) => e is UnAuthenticatedException)));
    });
    test('Verify that otp:get with ttl requires authentication', () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = false;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
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
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      expect(
          otpVerbHandler.processVerb(
              response,
              getVerbParam(VerbSyntax.otp, 'otp:put:abcdef'),
              inboundConnection),
          throwsA(predicate((dynamic e) => e is UnAuthenticatedException)));
    });
    test('otp:get is denied for an enrollment without __manage access',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.enrollmentId = 'scoped-enroll-id';
      inboundConnection.metaData.authType = AuthType.apkam;
      await keyValueStore.put(
          'scoped-enroll-id.new.enrollments.__manage$alice',
          AtData()
            ..data = jsonEncode({
              'sessionId': '123',
              'appName': 'wavi',
              'deviceName': 'pixel',
              'namespaces': {'wavi': 'rw'}, // no __manage
              'apkamPublicKey': 'k',
              'requestType': 'newEnrollment',
              'approval': {'state': 'approved'}
            }));
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      expect(
          otpVerbHandler.processVerb(response,
              getVerbParam(VerbSyntax.otp, 'otp:get'), inboundConnection),
          throwsA(isA<UnAuthorizedException>()));
    });
    test('otp:get is allowed for an enrollment with __manage access', () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.enrollmentId = 'manage-enroll-id';
      inboundConnection.metaData.authType = AuthType.apkam;
      await keyValueStore.put(
          'manage-enroll-id.new.enrollments.__manage$alice',
          AtData()
            ..data = jsonEncode({
              'sessionId': '123',
              'appName': 'wavi',
              'deviceName': 'pixel',
              'namespaces': {'wavi': 'rw', '__manage': 'rw'},
              'apkamPublicKey': 'k',
              'requestType': 'newEnrollment',
              'approval': {'state': 'approved'}
            }));
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(
          response, getVerbParam(VerbSyntax.otp, 'otp:get'), inboundConnection);
      expect(response.data, isNotNull);
      expect(response.data!.length, 6);
    });
    test('A test to verify OTP generated is 6-character length', () async {
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(response.data, isNotNull);
      expect(response.data!.length, 6);
      assert(RegExp('\\d').hasMatch(response.data!));
    });

    test('A test to verify same OTP is not returned', () {
      // NOTE generateOTP directly: 1000 live OTPs through otp:get would be far
      // over the live-OTP cap, and each otp:get counts the live ones.
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      Set<String> otpSet = {};
      for (int i = 1; i <= 1000; i++) {
        String otp = otpVerbHandler.generateOTP();
        expect(otp.length, 6);
        assert(RegExp('\\d').hasMatch(otp));
        bool isUnique = otpSet.add(otp);
        expect(isUnique, true);
      }
      expect(otpSet.length, 1000);
    });

    test('A test to verify otp:get with TTL set is active before TTL is met',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get:ttl:1000');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      String? otp = response.data;
      expect(await otpVerbHandler.isPasscodeValid(otp), true);
    });

    test('A test to verify otp:get with TTL set expires after the TTL is met',
        () async {
      Response response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get:ttl:1');
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
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
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
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
      inboundConnection.metaData.authType = AuthType.cram;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(await otpVerbHandler.isPasscodeValid(response.data), true);
    });

    test('A test to verify otp:validate returns invalid when OTP is expired',
        () async {
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get:ttl:1');
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
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
      inboundConnection.metaData.authType = AuthType.cram;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      AtData? atData = await keyValueStore.get(
          'private:${response.data}.${OtpVerbHandler.otpNamespace}$atSign');
      expect(atData?.metaData?.ttl, 1);

      verbParams = getVerbParam(VerbSyntax.otp, 'otp:get');
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      atData = await keyValueStore.get(
          'private:${response.data}.${OtpVerbHandler.otpNamespace}$atSign');
      expect(atData?.metaData?.ttl,
          OtpVerbHandler.defaultOtpExpiry.inMilliseconds);
    });

    test(
        'A test to verify otp:validate return invalid when otp does not exist in keystore',
        () async {
      String otp = 'ABC123';
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      expect(await otpVerbHandler.isPasscodeValid(otp), false);
    });

    test('A test to verify otp is removed from the keystore after use',
        () async {
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:get');
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      String? otp = response.data;
      expect(await otpVerbHandler.isPasscodeValid(otp), true);
      expect(await otpVerbHandler.isPasscodeValid(otp), false);
    });

    test('A test to verify a namespace-less private record is not an OTP',
        () async {
      String testOtp = 'ABCD12';
      String key = 'private:${testOtp.toLowerCase()}$alice';
      AtData value = AtData()
        ..data = testOtp
        ..metaData = (AtMetaData()
          ..ttl = OtpVerbHandler.defaultOtpExpiry.inMilliseconds);
      await keyValueStore.put(key, value);

      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      expect(await otpVerbHandler.isPasscodeValid(testOtp), false);
      expect((await keyValueStore.get(key))?.data, testOtp);
    });

    for (final (String first, String second) in [
      ('ABC124', 'ABC124'),
      ('ABC124', ' ABC124'),
      ('ABC124', 'ABC 124'),
    ]) {
      test(
          'A test to verify one OTP checked at once as "$first" and "$second"'
          ' is accepted once', () async {
        OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
        await otpVerbHandler.savePasscode('ABC124', ttl: 60000, isSpp: false);
        expect(
            await Future.wait([
              otpVerbHandler.isPasscodeValid(first),
              otpVerbHandler.isPasscodeValid(second),
            ]),
            unorderedEquals([true, false]));
      });
    }

    test('A test to verify a refused passcode can be accepted once issued',
        () async {
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      expect(await otpVerbHandler.isPasscodeValid('ABC126'), false);
      await otpVerbHandler.savePasscode('ABC126', ttl: 60000, isSpp: false);
      expect(await otpVerbHandler.isPasscodeValid('ABC126'), true);
    });

    test('A test to verify a refused expired OTP is not removed', () async {
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.savePasscode('ABC125', ttl: 1, isSpp: false);
      await Future.delayed(Duration(milliseconds: 2));
      expect(await otpVerbHandler.isPasscodeValid('ABC125'), false);
      expect(
          await keyValueStore
              .exists(OtpVerbHandler.passcodeKey('ABC125', isSpp: false)),
          true);
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to semi-permanent pass codes', () {
    String enrollmentId = 'dummy-enrollment-key';
    setUp(() async {
      await verbTestsSetUp();
      String enrollmentKey =
          '$enrollmentId.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice';
      EnrollDataStoreValue enrollDataStoreValue = EnrollDataStoreValue(
          'dummy_session_id', 'dummy-app', 'dummy-device', 'dummy-apkam-key')
        ..namespaces = {
          EnrollmentConstants.allNamespaces: 'rw',
          EnrollmentConstants.enrollManageNamespace: 'rw'
        }
        ..approval = EnrollApproval(EnrollmentStatus.approved.name);
      await keyValueStore.put(
          enrollmentKey, AtData()..data = jsonEncode(enrollDataStoreValue));
    });

    test('A test to set a pass code and verify isOTPValid returns true',
        () async {
      String passcode = 'abc123';
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:put:$passcode');
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.enrollmentId = enrollmentId;
      inboundConnection.metaData.authType = AuthType.apkam;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
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
      inboundConnection.metaData.enrollmentId = enrollmentId;
      inboundConnection.metaData.authType = AuthType.apkam;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
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
      inboundConnection.metaData.enrollmentId = enrollmentId;
      inboundConnection.metaData.authType = AuthType.apkam;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
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
      inboundConnection.metaData.enrollmentId = enrollmentId;
      inboundConnection.metaData.authType = AuthType.apkam;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      await Future.delayed(Duration(milliseconds: 2));
      expect(await otpVerbHandler.isPasscodeValid(passcode), true);

      String sppKey = OtpVerbHandler.passcodeKey(passcode, isSpp: true);
      var atData = await keyValueStore.get(sppKey);
      expect(atData?.metaData?.ttl, -1);
    });

    test('A test to verify pass code can be updated', () async {
      String passcode = 'abc123';
      Response response = Response();
      HashMap<String, String?> verbParams =
          getVerbParam(VerbSyntax.otp, 'otp:put:$passcode');
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.enrollmentId = enrollmentId;
      inboundConnection.metaData.authType = AuthType.apkam;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(await otpVerbHandler.isPasscodeValid(passcode), true);
      // Update the pass-code
      passcode = 'xyz987';
      response = Response();
      verbParams = getVerbParam(VerbSyntax.otp, 'otp:put:$passcode');
      otpVerbHandler = OtpVerbHandler(keyValueStore);
      await otpVerbHandler.processVerb(response, verbParams, inboundConnection);
      expect(await otpVerbHandler.isPasscodeValid(passcode), true);
    });

    test('validate backwards compatability with legacy ssp key', () async {
      String atsign = alice;
      String testOtp = 'ABC123';
      String otpLegacyKey = 'private:spp$atsign';
      AtData value = AtData()..data = testOtp;
      await keyValueStore.put(otpLegacyKey, value);

      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      expect(await otpVerbHandler.isPasscodeValid(testOtp), true);
    });

    test('otp:put is refused for an enrollment without full privilege',
        () async {
      await keyValueStore.put(
          'manage-only.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice',
          AtData()
            ..data = jsonEncode(
                EnrollDataStoreValue('sid', 'app', 'device', 'apkam-key')
                  ..namespaces = {
                    EnrollmentConstants.enrollManageNamespace: 'rw'
                  }
                  ..approval = EnrollApproval(EnrollmentStatus.approved.name)));
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.enrollmentId = 'manage-only';
      inboundConnection.metaData.authType = AuthType.apkam;
      OtpVerbHandler otpVerbHandler = OtpVerbHandler(keyValueStore);
      await expectLater(
          otpVerbHandler.processVerb(
              Response(),
              getVerbParam(VerbSyntax.otp, 'otp:put:abc123'),
              inboundConnection),
          throwsA(isA<UnAuthorizedException>()));
      expect(await otpVerbHandler.isPasscodeValid('abc123'), false);
    });
    tearDown(() async => await verbTestsTearDown());
  });

  group('A group of tests related to otp:list and otp:delete', () {
    setUp(() async {
      await verbTestsSetUp();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
    });
    tearDown(() async => await verbTestsTearDown());

    Future<Response> run(String command) async {
      Response response = Response();
      await OtpVerbHandler(keyValueStore).processVerb(
          response, getVerbParam(VerbSyntax.otp, command), inboundConnection);
      return response;
    }

    Future<void> useManageOnlyEnrollment() async {
      inboundConnection.metaData.enrollmentId = 'manage-only';
      inboundConnection.metaData.authType = AuthType.apkam;
      await keyValueStore.put(
          'manage-only.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice',
          AtData()
            ..data = jsonEncode(
                EnrollDataStoreValue('sid', 'app', 'device', 'apkam-key')
                  ..namespaces = {
                    EnrollmentConstants.enrollManageNamespace: 'rw'
                  }
                  ..approval = EnrollApproval(EnrollmentStatus.approved.name)));
    }

    Future<void> useEnrollment(
        String id, Map<String, String> namespaces) async {
      inboundConnection.metaData.enrollmentId = id;
      inboundConnection.metaData.authType = AuthType.apkam;
      await keyValueStore.put(
          '$id.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice',
          AtData()
            ..data = jsonEncode(
                EnrollDataStoreValue('sid', 'app', 'device', 'apkam-key')
                  ..namespaces = namespaces
                  ..approval = EnrollApproval(EnrollmentStatus.approved.name)));
    }

    void useCram() {
      inboundConnection.metaData.enrollmentId = null;
      inboundConnection.metaData.authType = AuthType.cram;
    }

    List<String> entries(Response response) =>
        (jsonDecode(response.data!) as List)
            .map((e) => '${e['type']}:${e['value']}')
            .toList();

    test('otp:list returns live OTPs, as issued, and the SPP', () async {
      String otp = (await run('otp:get')).data!;
      await run('otp:put:abc123');
      expect(entries(await run('otp:list')),
          unorderedEquals(['otp:$otp', 'spp:abc123']));
    });

    test('otp:list skips an expired OTP', () async {
      await run('otp:get:ttl:1');
      await Future.delayed(Duration(milliseconds: 5));
      expect(entries(await run('otp:list')), isEmpty);
    });

    test('otp:list shows the legacy SPP when there is no current one',
        () async {
      await keyValueStore.put('private:spp$alice', AtData()..data = 'old123');
      expect(entries(await run('otp:list')), ['spp:old123']);
    });

    test('otp:list is refused without __manage', () async {
      await useEnrollment('wavi-only', {'wavi': 'rw'});
      expect(run('otp:list'), throwsA(isA<UnAuthorizedException>()));
    });

    test('otp:delete removes an OTP', () async {
      String otp = (await run('otp:get')).data!;
      expect((await run('otp:delete:$otp')).data, 'ok');
      expect(await OtpVerbHandler(keyValueStore).isPasscodeValid(otp), false);
    });

    test('otp:delete:spp removes the current and the legacy SPP', () async {
      await run('otp:put:abc123');
      await keyValueStore.put('private:spp$alice', AtData()..data = 'old123');
      expect((await run('otp:delete:SPP')).data, 'ok');
      OtpVerbHandler handler = OtpVerbHandler(keyValueStore);
      expect(await handler.isPasscodeValid('abc123'), false);
      expect(await handler.isPasscodeValid('old123'), false);
    });

    test('otp:delete of an unknown OTP answers ok', () async {
      expect((await run('otp:delete:NOSUCH1')).data, 'ok');
    });

    test('otp:delete without full privilege answers ok and deletes nothing',
        () async {
      String otp = (await run('otp:get')).data!;
      await useManageOnlyEnrollment();
      expect((await run('otp:delete:$otp')).data, 'ok');
      expect(await OtpVerbHandler(keyValueStore).isPasscodeValid(otp), true);
    });

    test('otp:delete leaves a namespace-less private key alone', () async {
      await keyValueStore.put(
          'private:abcd12$alice', AtData()..data = 'ABCD12');
      expect((await run('otp:delete:ABCD12')).data, 'ok');
      expect(await keyValueStore.exists('private:abcd12$alice'), true);
    });

    test("otp:get records the issuing enrollment's namespaces", () async {
      await useEnrollment('app1', {'app_1': 'rw', '__manage': 'rw'});
      String otp = (await run('otp:get')).data!;
      AtData? atData = await keyValueStore
          .get(OtpVerbHandler.passcodeKey(otp, isSpp: false));
      expect(jsonDecode(atData!.data!), {
        'passcode': otp,
        'namespaces': {'app_1': 'rw', '__manage': 'rw'}
      });
    });

    test('otp:list shows a __manage enrollment only the OTPs it covers',
        () async {
      await run('otp:put:abc123');
      String cramOtp = (await run('otp:get')).data!;
      await useEnrollment(
          'both', {'app_1': 'rw', 'app_2': 'rw', '__manage': 'rw'});
      String bothOtp = (await run('otp:get')).data!;
      await useEnrollment('two', {'app_2': 'rw', '__manage': 'rw'});
      String twoOtp = (await run('otp:get')).data!;

      expect(entries(await run('otp:list')), ['otp:$twoOtp']);
      await useEnrollment(
          'both', {'app_1': 'rw', 'app_2': 'rw', '__manage': 'rw'});
      expect(entries(await run('otp:list')),
          unorderedEquals(['otp:$bothOtp', 'otp:$twoOtp']));
      useCram();
      expect(
          entries(await run('otp:list')),
          unorderedEquals(
              ['spp:abc123', 'otp:$cramOtp', 'otp:$bothOtp', 'otp:$twoOtp']));
    });

    test('otp:delete by a __manage enrollment removes only OTPs it covers',
        () async {
      await useEnrollment(
          'both', {'app_1': 'rw', 'app_2': 'rw', '__manage': 'rw'});
      String bothOtp = (await run('otp:get')).data!;
      await useEnrollment('two', {'app_2': 'rw', '__manage': 'rw'});
      String twoOtp = (await run('otp:get')).data!;

      expect((await run('otp:delete:$bothOtp')).data, 'ok');
      expect((await run('otp:delete:$twoOtp')).data, 'ok');
      OtpVerbHandler handler = OtpVerbHandler(keyValueStore);
      expect(await handler.isPasscodeValid(bothOtp), true);
      expect(await handler.isPasscodeValid(twoOtp), false);
    });

    test('otp:delete:spp by a __manage enrollment leaves the SPP', () async {
      await run('otp:put:abc123');
      await useEnrollment('manage', {'__manage': 'rw'});
      expect((await run('otp:delete:spp')).data, 'ok');
      expect(
          await OtpVerbHandler(keyValueStore).isPasscodeValid('abc123'), true);
    });

    test('an OTP stored before OTPs carried namespaces is full privilege only',
        () async {
      await keyValueStore.put(
          OtpVerbHandler.passcodeKey('ABCD12', isSpp: false),
          AtData()..data = 'ABCD12');
      expect(entries(await run('otp:list')), ['otp:ABCD12']);
      await useEnrollment('manage', {'__manage': 'rw'});
      expect(entries(await run('otp:list')), isEmpty);
    });

    test('covers follows verifyNoEscalation', () {
      expect(OtpVerbHandler.covers({'a': 'rw'}, {'a': 'r'}), true);
      expect(OtpVerbHandler.covers({'a': 'r'}, {'a': 'rw'}), false);
      expect(OtpVerbHandler.covers({'*': 'rw'}, {'a': 'rw'}), true);
      expect(OtpVerbHandler.covers({'*': 'rw'}, {'__manage': 'rw'}), false);
      expect(
          OtpVerbHandler.covers(
              {'a': 'rw', '__manage': 'rw'}, {'*': 'rw', '__manage': 'rw'}),
          false);
      expect(
          OtpVerbHandler.covers(
              {'*': 'rw', '__manage': 'rw'}, {'*': 'rw', '__manage': 'rw'}),
          true);
    });

    test('otp:list shows one SPP when the current and legacy keys both exist',
        () async {
      await run('otp:put:abc123');
      await keyValueStore.put('private:spp$alice', AtData()..data = 'old123');
      expect(entries(await run('otp:list')), ['spp:abc123']);
    });

    test('otp:list gives an SPP set without a ttl an expiresAt of -1',
        () async {
      await run('otp:put:abc123');
      final List listed = jsonDecode((await run('otp:list')).data!);
      expect(listed.single['expiresAt'], -1);
    });

    test('otp:list leaves out an expired legacy SPP', () async {
      await keyValueStore.put(
          'private:spp$alice',
          AtData()
            ..data = 'old123'
            ..metaData = (AtMetaData()..ttl = 1));
      await Future.delayed(Duration(milliseconds: 5));
      expect(entries(await run('otp:list')), isEmpty);
    });

    test('covers folds namespaces as the keystore does', () {
      expect(OtpVerbHandler.covers({'App_1': 'rw'}, {'app_1': 'r'}), true);
      expect(OtpVerbHandler.covers({'app_1': 'rw'}, {'APP_1': 'rw'}), true);
      expect(OtpVerbHandler.covers({' App 1 ': 'rw'}, {'app1': 'r'}), true);
      expect(OtpVerbHandler.covers({'*': 'rw'}, {'__MANAGE': 'rw'}), false);
    });

    test('readOtp reads a malformed record as a namespace-less OTP', () {
      expect(OtpVerbHandler.readOtp('{oops'),
          (passcode: '{oops', namespaces: null));
      expect(OtpVerbHandler.readOtp('{"passcode": 1}'),
          (passcode: '{"passcode": 1}', namespaces: null));
      expect(OtpVerbHandler.readOtp('{oops', keyPasscode: 'badrec'),
          (passcode: 'badrec', namespaces: null));
    });

    test('a malformed OTP record is listed under its key and can be deleted',
        () async {
      await keyValueStore.put(
          OtpVerbHandler.passcodeKey('BADREC', isSpp: false),
          AtData()..data = '{oops');
      await useEnrollment('two', {'app_2': 'rw', '__manage': 'rw'});
      final otp = (await run('otp:get')).data!;
      expect(entries(await run('otp:list')), ['otp:$otp']);
      useCram();
      expect(entries(await run('otp:list')),
          unorderedEquals(['otp:badrec', 'otp:$otp']));
      await run('otp:delete:badrec');
      expect(entries(await run('otp:list')), ['otp:$otp']);
    });

    test('otp:put without a passcode is a syntax error', () async {
      await expectLater(run('otp:put'), throwsA(isA<InvalidSyntaxException>()));
    });

    test('otp:delete of the SPP\'s value leaves the SPP', () async {
      await run('otp:put:abc123');
      expect((await run('otp:delete:abc123')).data, 'ok');
      expect(
          await OtpVerbHandler(keyValueStore).isPasscodeValid('abc123'), true);
    });

    test('otp:list and otp:delete require authentication', () async {
      inboundConnection.metaData.isAuthenticated = false;
      await expectLater(
          run('otp:list'), throwsA(isA<UnAuthenticatedException>()));
      await expectLater(
          run('otp:delete:ABC123'), throwsA(isA<UnAuthenticatedException>()));
    });
  });

  group('A group of tests related to the otp:get ttl limit', () {
    setUp(() async {
      await verbTestsSetUp();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      AtSecondaryConfig.otpMaxTtlInMinutes = 1;
    });
    tearDown(() async {
      AtSecondaryConfig.otpMaxTtlInMinutes = null;
      await verbTestsTearDown();
    });

    Future<String> issue(String command) async {
      Response response = Response();
      await OtpVerbHandler(keyValueStore).processVerb(
          response, getVerbParam(VerbSyntax.otp, command), inboundConnection);
      return response.data!;
    }

    Future<int?> storedTtl(String otp) async => (await keyValueStore
            .get('private:$otp.${OtpVerbHandler.otpNamespace}$atSign'))
        ?.metaData
        ?.ttl;

    test('otp:get accepts a ttl equal to the maximum', () async {
      String otp = await issue('otp:get:ttl:60000');
      expect(await storedTtl(otp), 60000);
    });

    test('otp:get refuses a ttl above the maximum, and stores nothing',
        () async {
      await expectLater(
          issue('otp:get:ttl:60001'), throwsA(isA<IllegalArgumentException>()));
      expect(await OtpVerbHandler(keyValueStore).listPasscodes(), isEmpty);
    });

    test('otp:get refuses ttl:0, which would never expire', () async {
      await expectLater(
          issue('otp:get:ttl:0'), throwsA(isA<IllegalArgumentException>()));
    });

    test('otp:get refuses a ttl too large to parse', () async {
      // NOTE a maximum above the 5-minute default, so a silent fallback to
      // the default would be accepted and this test would fail.
      AtSecondaryConfig.otpMaxTtlInMinutes = 10;
      await expectLater(issue('otp:get:ttl:99999999999999999999'),
          throwsA(isA<IllegalArgumentException>()));
    });

    test('otp:get without a ttl is cut to a shorter maximum', () async {
      String otp = await issue('otp:get');
      expect(await storedTtl(otp), 60000);
    });

    test('otp:get without a ttl keeps the default under a longer maximum',
        () async {
      AtSecondaryConfig.otpMaxTtlInMinutes = null;
      String otp = await issue('otp:get');
      expect(
          await storedTtl(otp), OtpVerbHandler.defaultOtpExpiry.inMilliseconds);
    });

    test('a maximum of 0 or less falls back to 60 minutes', () {
      AtSecondaryConfig.otpMaxTtlInMinutes = 0;
      expect(AtSecondaryConfig.otpMaxTtlInMinutes, 60);
      AtSecondaryConfig.otpMaxTtlInMinutes = -5;
      expect(AtSecondaryConfig.otpMaxTtlInMinutes, 60);
    });

    test('a maximum above one year is cut to one year, so it cannot overflow',
        () async {
      // NOTE 2^63-1 minutes overflowed Duration(minutes:) to a negative ttl:
      // an OTP issued without a ttl never expired, and every ttl was refused.
      AtSecondaryConfig.otpMaxTtlInMinutes = 9223372036854775807;
      expect(AtSecondaryConfig.otpMaxTtlInMinutes, 525600);
      String otp = await issue('otp:get');
      expect(
          await storedTtl(otp), OtpVerbHandler.defaultOtpExpiry.inMilliseconds);
      otp = await issue('otp:get:ttl:300000');
      expect(await storedTtl(otp), 300000);
    });
  });

  group('A group of tests related to the live-OTP limit', () {
    setUp(() async {
      await verbTestsSetUp();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      AtSecondaryConfig.maxLiveOtps = 2;
    });
    tearDown(() async {
      AtSecondaryConfig.maxLiveOtps = null;
      await verbTestsTearDown();
    });

    Future<String> issue(String command) async {
      Response response = Response();
      await OtpVerbHandler(keyValueStore).processVerb(
          response, getVerbParam(VerbSyntax.otp, command), inboundConnection);
      return response.data!;
    }

    Future<int> liveCount() async =>
        (await OtpVerbHandler(keyValueStore).listPasscodes()).length;

    Future<void> useEnrollment(
        String id, Map<String, String> namespaces) async {
      inboundConnection.metaData.enrollmentId = id;
      inboundConnection.metaData.authType = AuthType.apkam;
      await keyValueStore.put(
          '$id.${EnrollmentConstants.enrollmentKeyPattern}.${EnrollmentConstants.enrollManageNamespace}$alice',
          AtData()
            ..data = jsonEncode(
                EnrollDataStoreValue('sid', 'app', 'device', 'apkam-key')
                  ..namespaces = namespaces
                  ..approval = EnrollApproval(EnrollmentStatus.approved.name)));
    }

    test('otp:get is refused once the maximum is live, and stores nothing',
        () async {
      await issue('otp:get');
      await issue('otp:get');
      await expectLater(
          issue('otp:get'), throwsA(isA<AtThrottleLimitExceeded>()));
      expect(await liveCount(), 2);
    });

    test('the SPP does not count toward the maximum', () async {
      await issue('otp:put:abc123');
      await issue('otp:get');
      await issue('otp:get');
      expect(await liveCount(), 3);
    });

    test('an expired OTP does not count toward the maximum', () async {
      await issue('otp:get:ttl:1');
      await Future.delayed(Duration(milliseconds: 10));
      await issue('otp:get');
      await issue('otp:get');
      expect(await liveCount(), 2);
    });

    test('otp:delete frees a place', () async {
      String first = await issue('otp:get');
      await issue('otp:get');
      await issue('otp:delete:$first');
      await issue('otp:get');
      expect(await liveCount(), 2);
    });

    test('concurrent otp:gets never exceed the maximum', () async {
      int refused = 0;
      await Future.wait(List.generate(5, (_) async {
        try {
          await issue('otp:get');
        } on AtThrottleLimitExceeded {
          refused++;
        }
      }));
      expect(refused, 3);
      expect(await liveCount(), 2);
    });

    test('a maximum of 0 or less falls back to 10', () {
      AtSecondaryConfig.maxLiveOtps = 0;
      expect(AtSecondaryConfig.maxLiveOtps, 10);
      AtSecondaryConfig.maxLiveOtps = -1;
      expect(AtSecondaryConfig.maxLiveOtps, 10);
    });

    test('the maximum is shared by every issuer, full privilege included',
        () async {
      await useEnrollment('first', {'app_1': 'rw', '__manage': 'rw'});
      await issue('otp:get');
      await useEnrollment('second', {'app_2': 'rw', '__manage': 'rw'});
      await issue('otp:get');
      // NOTE "second" has issued one OTP, but "first"'s counts against it too.
      await expectLater(
          issue('otp:get'), throwsA(isA<AtThrottleLimitExceeded>()));
      inboundConnection.metaData.enrollmentId = null;
      inboundConnection.metaData.authType = AuthType.cram;
      await expectLater(
          issue('otp:get'), throwsA(isA<AtThrottleLimitExceeded>()));
      expect(await liveCount(), 2);
    });

    test('a refused ttl is answered before the live-OTP cap is checked',
        () async {
      await issue('otp:get');
      await issue('otp:get');
      // NOTE the cap of 2 is full, but the ttl is refused first.
      await expectLater(
          issue('otp:get:ttl:0'), throwsA(isA<IllegalArgumentException>()));
    });
  });

  test('info lists otp.list and otp.delete as Beta', () {
    final features = InfoFeatures.parse(
        'data:${jsonEncode({'features': InfoVerbHandler.features})}')!;
    expect(features.statusOf(InfoFeature.otpList), InfoFeatureStatus.beta);
    expect(features.statusOf(InfoFeature.otpDelete), InfoFeatureStatus.beta);
  });
}
