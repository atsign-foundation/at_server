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

/// Catalogue: features/enrollment/enroll_request_passcodes.feature
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

  /// Sends an enroll:request with [passcode] on a new unauthenticated
  /// connection, answering its status.
  Future<String> request(String passcode) async {
    final Response response = Response();
    await EnrollVerbHandler(keyValueStore, enMgr, notificationManager)
        .processVerb(
            response,
            getVerbParam(
                VerbSyntax.enroll,
                'enroll:request:{"appName":"app-${Uuid().v4()}"'
                ',"deviceName":"device","namespaces":{"wavi":"r"}'
                ',"otp":"$passcode"'
                ',"apkamPublicKey":"apkam-${Uuid().v4()}"'
                ',"encryptedAPKAMSymmetricKey":"symmetric"}'),
            unauthenticated());
    return jsonDecode(response.data!)['status'];
  }

  final Matcher refusedAsInvalidOtp = throwsA(predicate((dynamic e) =>
      e is IllegalArgumentException &&
      e.message == 'invalid otp. Cannot process enroll request'));

  test('An OTP the atServer issued admits one enroll:request', () async {
    final String passcode = await otp('otp:get');
    expect(await request(passcode), 'pending');
    await expectLater(request(passcode), refusedAsInvalidOtp);
  });

  test('Two enroll:requests presenting one OTP at once admit only one',
      () async {
    final String passcode = await otp('otp:get');
    final List<String> outcomes = await Future.wait([
      for (int i = 0; i < 2; i++)
        request(passcode).then((status) => status,
            onError: (Object e) => e is IllegalArgumentException
                ? 'refused: ${e.message}'
                : throw e),
    ]);
    expect(outcomes.where((o) => o == 'pending'), hasLength(1),
        reason: 'outcomes $outcomes');
    expect(outcomes,
        contains('refused: invalid otp. Cannot process enroll request'));
  });

  group('An issued OTP in another spelling is refused', () {
    for (final (String example, String Function(String) spell) in [
      ('P with a leading space', (String p) => ' $p'),
      (
        'P with a space inside it',
        (String p) => '${p.substring(0, 3)} '
            '${p.substring(3)}'
      ),
    ]) {
      test(example, () async {
        final String passcode = await otp('otp:get');
        await expectLater(request(spell(passcode)), refusedAsInvalidOtp);
        expect(await request(passcode), 'pending');
      });
    }
  });

  test('A record outside the __otp namespace is never read as an OTP',
      () async {
    final String key = 'private:abc123$alice';
    await keyValueStore.put(key, AtData()..data = 'abc123');
    await expectLater(request('abc123'), refusedAsInvalidOtp);
    expect((await keyValueStore.get(key))?.data, 'abc123');
  });

  test('An SPP stored in the namespace-less form still counts as the SPP',
      () async {
    await keyValueStore.put('private:spp$alice', AtData()..data = 'ABC123');
    expect(await request('ABC123'), 'pending');
  });

  test(
      'Setting an SPP with otp:put removes one stored in the namespace-less form',
      () async {
    final String legacyKey = 'private:spp$alice';
    await keyValueStore.put(legacyKey, AtData()..data = 'OLD111');
    await otp('otp:put:NEW111');
    expect(await keyValueStore.exists(legacyKey), false);
    await keyValueStore
        .remove(OtpVerbHandler.passcodeKey('NEW111', isSpp: true));
    await expectLater(request('OLD111'), refusedAsInvalidOtp);
  });
}
