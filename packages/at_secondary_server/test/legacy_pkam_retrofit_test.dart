import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:test/test.dart';

import 'enrollment_test_utils.dart';
import 'test_utils.dart';

/// The atSign's oldest credential — the legacy keyfile, which authenticates
/// with no enrollment id at all — gets an enrollment record of its own.
///
/// Without one it is the single credential on the atSign whose grants are
/// assumed rather than stated, which no roster shows, which no verb can
/// revoke, and which nothing ever retires. The housekeeping enrollment is what
/// a legacy connection authenticates AS, so that credential acquires the
/// lifecycle every other credential already has.
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

  String hKey() =>
      enMgr.buildEnrollmentKey(EnrollmentManager.housekeepingEnrollmentId);

  /// `keyStore.get` THROWS for a missing key rather than returning null, so
  /// absence has to be caught rather than tested for.
  Future<EnrollDataStoreValue?> storedH() async {
    final AtData? r;
    try {
      r = await keyValueStore.get(hKey());
    } on KeyNotFoundException {
      return null;
    }
    if (r?.data == null) return null;
    return EnrollDataStoreValue.fromJson(jsonDecode(r!.data!));
  }

  Future<void> setHStatus(EnrollmentStatus status) async {
    final h = (await storedH())!..approval = EnrollApproval(status.name);
    await enMgr.put(EnrollmentManager.housekeepingEnrollmentId,
        AtData()..data = jsonEncode(h.toJson()), status);
  }

  group('the housekeeping enrollment', () {
    test('its id is the literal `primary`', () {
      expect(EnrollmentManager.housekeepingEnrollmentId, 'primary',
          reason: 'AT-REST AND CROSS-REPO, so this is a raw-literal pin. '
              'at_client already publishes a legacy client\'s signing key at '
              '`public:_apsk.primary.a.__e@<atSign>`, and that key becomes '
              'this enrollment\'s per-enrollment data only because the two '
              'ids match exactly. Changing this string strands it.');
    });

    test('is created on demand, approved and fully privileged', () async {
      expect(await storedH(), isNull, reason: 'precondition: no record yet');

      await enMgr.ensureHousekeepingEnrollment('the-legacy-pkam-key');

      final h = await storedH();
      expect(h, isNotNull);
      expect(h!.approval?.state, EnrollmentStatus.approved.name);
      expect(h.namespaces, {
        EnrollmentConstants.allNamespaces: 'rw',
        EnrollmentConstants.enrollManageNamespace: 'rw',
      }, reason: 'it stands for the credential the atSign was onboarded with, '
          'which has always had unrestricted access — stating that is the '
          'point of the record');
      expect(h.isRootEnrollment, isTrue,
          reason: 'so the stranding refusals count it like any other root');
      expect(h.apkamPublicKey, 'the-legacy-pkam-key',
          reason: 'the record describes the credential it stands for rather '
              'than being a bare marker');
    });

    test('carries NO approver, so no cascade can reach it', () async {
      await enMgr.ensureHousekeepingEnrollment('k');
      final admitted = await etu.createPendingEnrollment(
          appName: 'admitted',
          deviceName: 'device',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null);
      await etu.approveEnrollment(etu.primaryEnId, admitted);

      expect((await storedH())!.approvedByEnrollmentId, isNull,
          reason: 'nothing admitted it — the server created it for itself');

      final reachable = await enMgr.descendantsOf(etu.primaryEnId);
      expect(reachable, contains(admitted),
          reason: 'positive control: the cascade does reach what the primary '
              'admitted, so an absence below is about the approver and not '
              'about a walk that finds nothing');
      expect(
          reachable,
          isNot(contains(EnrollmentManager.housekeepingEnrollmentId)),
          reason: 'a cascade able to sweep it away would strand the very '
              'credential it exists to govern');
    });

    test('does not expire of its own accord', () async {
      await enMgr.ensureHousekeepingEnrollment('k');
      expect((await keyValueStore.get(hKey()))?.metaData?.expiresAt, isNull,
          reason: 'only the retrofit cap may ever put a clock on it');
    });

    test('a second authentication reads it rather than rewriting it', () async {
      await enMgr.ensureHousekeepingEnrollment('k');
      final int writesBefore = EnrollmentManager.cacheInvalidations;
      final String sessionBefore = (await storedH())!.sessionId;

      await enMgr.ensureHousekeepingEnrollment('k');

      expect(EnrollmentManager.cacheInvalidations, writesBefore,
          reason: 'every enrollment write bumps this counter, and this runs '
              'on EVERY legacy authentication — the already-created case has '
              'to cost one read and no write');
      expect((await storedH())!.sessionId, sessionBefore,
          reason: 'and it is the same record, not a freshly minted one');
    });

    test('a REVOKED one is not restored by authenticating again', () async {
      await enMgr.ensureHousekeepingEnrollment('k');
      await setHStatus(EnrollmentStatus.revoked);

      final returned = await enMgr.ensureHousekeepingEnrollment('k');

      expect(returned.approval?.state, EnrollmentStatus.revoked.name);
      expect((await storedH())!.approval?.state,
          EnrollmentStatus.revoked.name,
          reason: 'otherwise legacy authentication is a way to undo its own '
              'revocation, and the record could never be retired at all');
    });

    test('the signing key a legacy client already published becomes its '
        'per-enrollment data', () async {
      // The whole reason the id is `primary` rather than something coined.
      // at_client publishes a legacy client's signing key at this address
      // today and nothing has ever retired it, because there was no
      // enrollment for it to belong to.
      final String approvedKey = 'public:_apsk.'
          '${EnrollmentManager.housekeepingEnrollmentId}'
          '.${EnrollmentConstants.perEnrollmentApproved}$alice';
      final String revokedKey = 'public:_apsk.'
          '${EnrollmentManager.housekeepingEnrollmentId}'
          '.${EnrollmentConstants.perEnrollmentRevoked}$alice';
      await keyValueStore.put(
          approvedKey, AtData()..data = 'the legacy signing key',
          skipCommit: true);

      await enMgr.ensureHousekeepingEnrollment('k');
      expect(await keyValueStore.exists(approvedKey), isTrue,
          reason: 'precondition: creation approves it, so the key stays at '
              'the live address');

      await setHStatus(EnrollmentStatus.revoked);

      expect(await keyValueStore.exists(revokedKey), isTrue,
          reason: 'revoking the legacy credential must PARK its signing key, '
              'exactly as revoking any other enrollment does');
      expect(await keyValueStore.exists(approvedKey), isFalse,
          reason: 'and it must no longer resolve at the address a verifier '
              'reads');
    });
  });
}
