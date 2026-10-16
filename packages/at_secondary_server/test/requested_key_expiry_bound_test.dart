import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';

import 'enrollment_test_utils.dart';
import 'test_utils.dart';

/// Catalogue: features/enrollment/requested_key_expiry_bound.feature
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

  const int longest = 3155760000000;

  /// Sends `enroll:request` from a new device holding an OTP, asking for
  /// [expiry] as its `apkamKeysExpiryInMillis`, and returns what the atServer
  /// wrote back; a refusal is thrown, as the atServer's exception handler
  /// receives it.
  Future<String> requestAsking(Object expiry) async {
    final Map<String, dynamic> params = (EnrollParams()
          ..appName = 'bounded'
          ..deviceName = 'device-${DateTime.now().microsecondsSinceEpoch}'
          ..apkamPublicKey = 'apkam public key bounded'
          ..encryptedAPKAMSymmetricKey = 'encrypted apkam aes key bounded'
          ..namespaces = {'wavi': 'rw'}
          ..otp = await etu.getOtp())
        .toJson()
      ..['apkamKeysExpiryInMillis'] = expiry;
    inboundConnection.metaData
      ..isAuthenticated = false
      ..authType = null
      ..sessionID = DateTime.now().microsecondsSinceEpoch.toString();
    await etu.evh
        .process('enroll:request:${jsonEncode(params)}', inboundConnection);
    return inboundConnection.lastWrittenData!;
  }

  /// The id and status of the enrollment a successful `enroll:request`
  /// [answer] names.
  (String, String) requestedIn(String answer) {
    expect(answer, startsWith('data:'), reason: answer);
    final Map m = jsonDecode(answer.substring(5).split('\n').first);
    return (m['enrollmentId'], m['status']);
  }

  /// `enroll:list` as the primary enrollment, keyed by enrollment key.
  Future<Map<String, dynamic>> roster() async {
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.apkam;
    inboundConnection.metadata.enrollmentId = etu.primaryEnId;
    final r = Response();
    await etu.evh.processVerb(
        r, getVerbParam(VerbSyntax.enroll, 'enroll:list'), inboundConnection);
    expect(r.isError, false, reason: '${r.errorMessage}');
    return jsonDecode(r.data!) as Map<String, dynamic>;
  }

  group('A request asking for a key expiry outside the bound is refused', () {
    for (final Object expiry in [
      3155760000001,
      -1,
      18446744160109551,
      1.5,
      '3600000',
    ]) {
      test(jsonEncode(expiry), () async {
        final Set<String> before = (await roster()).keys.toSet();
        expect(before, contains(enMgr.buildEnrollmentKey(etu.primaryEnId)),
            reason: 'the roster lists what the store holds');

        await expectLater(
            requestAsking(expiry),
            throwsA(isA<IllegalArgumentException>()
                .having(GlobalExceptionHandler.getInstance().getErrorCode,
                    'error code', 'AT0022')
                .having(
                    (e) => e.message,
                    'message',
                    'apkamKeysExpiryInMillis must be a whole number of '
                        'milliseconds from 0 to 3155760000000')));
        expect((await roster()).keys.toSet(), before);
      });
    }
  });

  group(
      'A request asking for a key expiry within the bound is pending with '
      'that expiry', () {
    for (final int expiry in [longest, 1, 0]) {
      test('$expiry', () async {
        final (String id, String status) =
            requestedIn(await requestAsking(expiry));

        expect(status, EnrollmentStatus.pending.name);
        final Map listed = (await roster())[enMgr.buildEnrollmentKey(id)];
        expect(listed['apkamKeysExpiryInMillis'], expiry);
      });
    }
  });

  test('An approver that never expires approves the longest key expiry',
      () async {
    final (String id, _) = requestedIn(await requestAsking(longest));
    expect(
        (await keyValueStore.get(enMgr.buildEnrollmentKey(etu.primaryEnId)))
            ?.metaData
            ?.expiresAt,
        isNull,
        reason: 'the approver never expires');

    final DateTime start = DateTime.now().toUtc();
    await etu.approveEnrollment(etu.primaryEnId, id);
    final DateTime end = DateTime.now().toUtc();

    final DateTime expires =
        (await keyValueStore.get(enMgr.buildEnrollmentKey(id)))!
            .metaData!
            .expiresAt!
            .toUtc();
    const Duration term = Duration(days: 36525);
    expect(term.inMilliseconds, longest);
    expect(
        expires.isBefore(start.add(term).subtract(Duration(milliseconds: 1))),
        isFalse,
        reason: '$expires is earlier than ${start.add(term)}');
    expect(
        expires.isAfter(end.add(term).add(Duration(milliseconds: 1))), isFalse,
        reason: '$expires is later than ${end.add(term)}');
  });
}
