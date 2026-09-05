import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';

import 'enrollment_test_utils.dart';
import 'test_utils.dart';

/// `enroll:fetch` and every `enroll:list` projection report each enrollment's
/// effective expiry as `expiresAt`, or null when nothing set it.
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

  /// ⚠️ WIRE PIN: frozen; clients parse this field by name with
  /// `DateTime.parse`.
  final RegExp isoUtc = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z$');

  Future<Map<String, dynamic>> run(String command,
      {String? asEnrollment, AuthType authType = AuthType.apkam}) async {
    inboundConnection.metaData.isAuthenticated = true;
    inboundConnection.metaData.enrollmentId = asEnrollment;
    inboundConnection.metaData.authType = authType;
    final r = Response();
    await etu.evh.processVerb(
        r, getVerbParam(VerbSyntax.enroll, command), inboundConnection);
    expect(r.isError, false, reason: '${r.errorMessage}');
    return jsonDecode(r.data!) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> fetch(String id,
          {required String asEnrollment}) =>
      run('enroll:fetch:{"enrollmentId":"$id"}', asEnrollment: asEnrollment);

  /// An approved enrollment carrying a one-hour posture, and the expiry the
  /// store holds for it.
  Future<(String, DateTime)> anExpiringEnrollment(
      {Map<String, String> namespaces = const {'wavi': 'rw'},
      String appName = 'expiring'}) async {
    final id = await etu.createPendingEnrollment(
        appName: appName,
        deviceName: 'device',
        namespaces: namespaces,
        apkamKeysExpiryDuration: Duration(hours: 1));
    await etu.approveEnrollment(etu.primaryEnId, id);
    final stored = (await keyValueStore.get(enMgr.buildEnrollmentKey(id)))
        ?.metaData
        ?.expiresAt;
    expect(stored, isNotNull,
        reason: 'precondition: approval with a posture writes an expiry');
    return (id, stored!.toUtc());
  }

  group('enroll:fetch', () {
    test('reports null for an enrollment with no expiry, with the key present',
        () async {
      final m = await fetch(etu.primaryEnId, asEnrollment: etu.primaryEnId);

      expect(m.containsKey('expiresAt'), isTrue,
          reason: 'an absent key and a key a client failed to parse are the '
              'same thing to a careless reader; an explicit null is an '
              'answer');
      expect(m['expiresAt'], isNull);
    });

    test('reports the stored expiry, as ISO-8601 UTC', () async {
      final (id, stored) = await anExpiringEnrollment();

      final m = await fetch(id, asEnrollment: etu.primaryEnId);

      expect(m['expiresAt'], matches(isoUtc),
          reason: 'the wire form is what DateTime.parse reads back as UTC');
      expect(DateTime.parse(m['expiresAt']), stored,
          reason: 'the value is the record\'s own expiry, not a recomputation '
              'from the posture: it must be whatever set it LAST');
    });

    test('an enrollment fetching itself sees its own expiry', () async {
      final (id, stored) = await anExpiringEnrollment();

      final m = await fetch(id, asEnrollment: id);

      expect(DateTime.parse(m['expiresAt']), stored,
          reason: 'the client that holds the credential is the one that '
              'needs to know when it stops working');
    });
  });

  group('enroll:list', () {
    late String expiringId;
    late DateTime stored;

    setUp(() async {
      (expiringId, stored) = await anExpiringEnrollment();
    });

    void expectBothEntries(Map<String, dynamic> roster) {
      final Map expiring = roster[enMgr.buildEnrollmentKey(expiringId)];
      expect(DateTime.parse(expiring['expiresAt']), stored);
      final Map root = roster[enMgr.buildEnrollmentKey(etu.primaryEnId)];
      expect(root.containsKey('expiresAt'), isTrue);
      expect(root['expiresAt'], isNull);
    }

    test('over a connection carrying no enrollment id (the whole record)',
        () async {
      expectBothEntries(await run('enroll:list',
          asEnrollment: null, authType: AuthType.cram));
    });

    test('over a __manage:rw holder (the whole record)', () async {
      expectBothEntries(
          await run('enroll:list', asEnrollment: etu.primaryEnId));
    });

    test('over a __manage:r holder (the roster projection)', () async {
      final auditorId = await etu.createPendingEnrollment(
          appName: 'auditor',
          deviceName: 'device',
          namespaces: {'__manage': 'r', 'wavi': 'rw'},
          apkamKeysExpiryDuration: null);
      await etu.approveEnrollment(etu.primaryEnId, auditorId);

      final roster = await run('enroll:list', asEnrollment: auditorId);

      expectBothEntries(roster);
      final Map expiring = roster[enMgr.buildEnrollmentKey(expiringId)];
      expect(expiring.containsKey('encryptedAPKAMSymmetricKey'), isFalse,
          reason: 'control: this really is the redacted projection, and the '
              'expiry is reported on it because it is a fact about the '
              'enrollment\'s life, not key material');
    });

    test('over an enrollment holding no __manage (its own record only)',
        () async {
      final roster = await run('enroll:list', asEnrollment: expiringId);

      expect(roster.keys, [enMgr.buildEnrollmentKey(expiringId)],
          reason: 'control: the self-only branch');
      final Map own = roster.values.single;
      expect(DateTime.parse(own['expiresAt']), stored);
    });
  });
}
