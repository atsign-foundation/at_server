import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/enroll_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/otp_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

/// The flat PKAM credential's retirement clock.
///
/// `privatekey:at_pkam_publickey` is what a `pkam:` carrying no enrollment id
/// is verified against. Nothing on the enrollment roster names it and no verb
/// withdraws it, so an atSign holding one holds a credential it cannot take
/// back. The clock is how that ends for an owner who has moved to
/// enrollments: it starts when an OWNER connection first mints one, and it
/// removes the flat key when it elapses — unless removing it would leave the
/// atSign nothing to authenticate with, in which case it declines and asks
/// again on the next sweep.
void main() {
  AtSignLogger.root_level = 'WARNING';

  group('the flat PKAM credential\'s retirement clock', () {
    late EnrollVerbHandler enrollVerbHandler;

    setUpAll(() async {
      await verbTestsSetUpAll();
    });

    setUp(() async {
      await verbTestsSetUp();
      enrollVerbHandler =
          EnrollVerbHandler(keyValueStore, enMgr, notificationManager);
    });

    tearDown(() async {
      await verbTestsTearDown();
    });

    /// Installs a flat credential, the way an atSign onboarded by an older
    /// server holds one. Written straight to the store because no connection
    /// may write this key any more.
    Future<void> installFlatCredential([String value = 'FLAT_PKAM_KEY']) =>
        keyValueStore.put(AtConstants.atPkamPublicKey, AtData()..data = value,
            skipCommit: true);

    Future<String?> deadlineRecord() async {
      try {
        return (await keyValueStore
                .get(enMgr.legacyCredentialRetirementKey))
            ?.data;
      } on KeyNotFoundException {
        return null;
      }
    }

    Future<void> writeDeadline(String raw) => keyValueStore.put(
        enMgr.legacyCredentialRetirementKey,
        AtData()..data = raw,
        skipCommit: true);

    /// Stores an approved enrollment directly, with [namespaces] and a
    /// non-empty APKAM public key — what makes a fully privileged one count
    /// as a root the atSign could fall back on.
    Future<String> storeApprovedEnrollment(Map<String, String> namespaces,
        {String apkamPublicKey = 'A_PUBLIC_KEY'}) async {
      final id = Uuid().v4();
      await keyValueStore.put(
          '$id.${EnrollmentConstants.enrollmentKeyPattern}.'
          '${EnrollmentConstants.enrollManageNamespace}$alice',
          AtData()
            ..data = jsonEncode({
              'sessionId': '123',
              'appName': 'wavi',
              'deviceName': 'pixel',
              'namespaces': namespaces,
              'apkamPublicKey': apkamPublicKey,
              'requestType': 'newEnrollment',
              'approval': {'state': 'approved'},
            }),
          skipCommit: true);
      return id;
    }

    /// An `enroll:request` on a CRAM connection — the initial enrollment,
    /// which the server auto-approves. This is one of the two moments an
    /// owner mints a credential that carries an enrollment id.
    Future<String> mintOverCram() async {
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.cram;
      inboundConnection.metadata.enrollmentId = null;
      inboundConnection.metaData.sessionID = 'session-${Uuid().v4()}';
      final response = Response();
      await enrollVerbHandler.processVerb(
          response,
          getVerbParam(
              VerbSyntax.enroll,
              'enroll:request:{"appName":"wavi","deviceName":"pixel",'
              '"namespaces":{"wavi":"rw"},"apkamPublicKey":"APKAM_KEY"}'),
          inboundConnection);
      return jsonDecode(response.data!)['enrollmentId'];
    }

    /// The other minting moment: an owner APPROVES a pending request. The
    /// approving connection carries no enrollment id; the requesting one
    /// arrives unauthenticated with an OTP.
    ///
    /// [approverEnrollmentId] null is the owner. Passing one makes the
    /// approver an ENROLLED connection instead, which is the discriminator
    /// this whole arming rests on.
    Future<String> mintByOwnerApproval({String? approverEnrollmentId}) async {
      final response = Response();
      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metaData.authType = AuthType.pkamLegacy;
      inboundConnection.metadata.enrollmentId = approverEnrollmentId;
      inboundConnection.metaData.sessionID = 'session-${Uuid().v4()}';

      await OtpVerbHandler(keyValueStore).processVerb(
          response, getVerbParam(VerbSyntax.otp, 'otp:get'), inboundConnection);
      final otp = response.data!;

      inboundConnection.metaData.isAuthenticated = false;
      final HashMap<String, String?> requestParams = getVerbParam(
          VerbSyntax.enroll,
          'enroll:request:{"appName":"buzz","deviceName":"pixel",'
          '"namespaces":{"buzz":"rw"},"otp":"$otp",'
          '"encryptedAPKAMSymmetricKey":"SYMKEY",'
          '"apkamPublicKey":"APKAM_KEY"}');
      await enrollVerbHandler.processVerb(
          response, requestParams, inboundConnection);
      final String enrollmentId = jsonDecode(response.data!)['enrollmentId'];

      inboundConnection.metaData.isAuthenticated = true;
      inboundConnection.metadata.enrollmentId = approverEnrollmentId;
      await enrollVerbHandler.processVerb(
          response,
          getVerbParam(
              VerbSyntax.enroll,
              'enroll:approve:{"enrollmentId":"$enrollmentId",'
              '"encryptedDefaultEncryptionPrivateKey":"ENC_PRIVATE_KEY",'
              '"encryptedDefaultSelfEncryptionKey":"SELF_ENC_KEY"}'),
          inboundConnection);
      expect(jsonDecode(response.data!)['status'], 'approved',
          reason: 'precondition: the approval this arming hangs off actually '
              'happened');
      return enrollmentId;
    }

    // ---- arming ----

    test('a CRAM connection minting an enrollment arms the clock', () async {
      await installFlatCredential();
      expect(await deadlineRecord(), isNull, reason: 'precondition: unarmed');

      await mintOverCram();

      final raw = await deadlineRecord();
      expect(raw, isNotNull,
          reason: 'the atSign now holds a credential that CAN be withdrawn, '
              'which is the moment the flat one starts running out');
      final deadline = DateTime.parse(raw!);
      expect(
          deadline.difference(DateTime.now().toUtc()).inHours,
          closeTo(720, 2),
          reason: 'the default migration window is 30 days from the mint');
    });

    test('an OWNER approving a request arms the clock', () async {
      await installFlatCredential();
      await mintByOwnerApproval();
      expect(await deadlineRecord(), isNotNull,
          reason: 'otp:get + enroll:request + enroll:approve is how an owner '
              'holding a flat keyfile mints its first enrolled credential');
    });

    test('CONTROL: an ENROLLED approver does not arm the clock', () async {
      await installFlatCredential();
      final approver = await storeApprovedEnrollment({'*': 'rw', '__manage': 'rw'});

      await mintByOwnerApproval(approverEnrollmentId: approver);

      expect(await deadlineRecord(), isNull,
          reason: 'the clock measures from the OWNER moving to enrollments. '
              'An approval by an enrolled connection is not that moment — the '
              'atSign already had an enrollment to approve with — and arming '
              'on it would start the window over on ordinary day-to-day '
              'enrolment');
    });

    test('CONTROL: no flat credential, no clock', () async {
      // Every atSign onboarded by this server. There is nothing to retire,
      // and a deadline standing over an absent key would fire on whatever was
      // installed there later.
      expect(await enMgr.legacyPkamPublicKey(), isNull,
          reason: 'precondition: no flat credential');

      await mintOverCram();

      expect(await deadlineRecord(), isNull,
          reason: 'a deadline written against a key that does not exist is a '
              'timer with no subject');
    });

    test('a zero-length flat credential does not arm the clock', () async {
      // Not a credential: authentication refuses an empty public key before
      // it looks at any signature, so an empty value and a missing one are
      // the same thing — and a store written by an older server, before both
      // spellings of update demanded a non-empty value, can hold one.
      await installFlatCredential('');

      await mintOverCram();

      expect(await deadlineRecord(), isNull,
          reason: 'a zero-length value is a credential nobody can '
              'authenticate with, so there is nothing to give a deadline');
    });

    test('a second mint does not push the deadline out', () async {
      await installFlatCredential();
      await mintOverCram();
      final first = await deadlineRecord();
      expect(first, isNotNull, reason: 'precondition: armed');

      await mintOverCram();
      await mintByOwnerApproval();

      expect(await deadlineRecord(), first,
          reason: 'the deadline is an absolute, so re-arming would push it '
              'out by a whole window every time — an owner minting an '
              'enrollment a month would keep the flat credential for ever');
    });

    // ---- firing ----

    test('an elapsed deadline removes the flat credential', () async {
      await installFlatCredential();
      await storeApprovedEnrollment({'*': 'rw', '__manage': 'rw'});
      await writeDeadline(
          DateTime.now().toUtc().subtract(Duration(minutes: 1))
              .toIso8601String());

      await enMgr.retireLegacyCredentialIfDue();

      expect(await enMgr.legacyPkamPublicKey(), isNull,
          reason: 'the window has run out and the atSign holds a fully '
              'privileged enrollment it can fall back on, so the credential '
              'nothing could revoke goes');
      expect(await deadlineRecord(), isNull,
          reason: 'and the deadline goes with the key it stood over');
    });

    test('CONTROL: a deadline still in the future removes nothing', () async {
      // Differs from the case above in the DEADLINE and in nothing else —
      // same store, same roster, same call. Without it that case is equally
      // satisfied by the sweep removing the key unconditionally.
      await installFlatCredential();
      await storeApprovedEnrollment({'*': 'rw', '__manage': 'rw'});
      final future = DateTime.now().toUtc().add(Duration(days: 30));
      await writeDeadline(future.toIso8601String());

      await enMgr.retireLegacyCredentialIfDue();

      expect(await enMgr.legacyPkamPublicKey(), 'FLAT_PKAM_KEY',
          reason: 'the migration window is what the credential survives on');
      expect(await deadlineRecord(), future.toIso8601String());
    });

    test('CONTROL: an unarmed clock removes nothing', () async {
      await installFlatCredential();
      await storeApprovedEnrollment({'*': 'rw', '__manage': 'rw'});

      await enMgr.retireLegacyCredentialIfDue();

      expect(await enMgr.legacyPkamPublicKey(), 'FLAT_PKAM_KEY',
          reason: 'an atSign whose owner never minted an enrollment never '
              'started a window, and the sweep must not invent one');
    });

    test('the removal DECLINES rather than stranding the atSign', () async {
      // The case R7 exists for. An atSign that revoked its enrollments — or
      // whose only enrollment expired — has nothing left but the flat
      // credential, and no verb puts it back once removed. So the deadline
      // elapsing is not enough.
      await installFlatCredential();
      await writeDeadline(DateTime.now()
          .toUtc()
          .subtract(Duration(days: 1))
          .toIso8601String());
      expect(await enMgr.hasUnexpiringRootEnrollmentRecord({}), isFalse,
          reason: 'precondition: the roster holds no root it could fall back '
              'on');

      await enMgr.retireLegacyCredentialIfDue();

      expect(await enMgr.legacyPkamPublicKey(), 'FLAT_PKAM_KEY',
          reason: 'removing the only credential an atSign can authenticate '
              'with locks its owner out permanently. A clock that never '
              'completes for such an atSign is the correct outcome');
      expect(await deadlineRecord(), isNotNull,
          reason: 'and the deadline STANDS, so the question is asked again on '
              'the next sweep rather than the atSign being exempted for good');
    });

    test('a scoped enrollment is not a root, so the removal still declines',
        () async {
      // The discriminating half of the decline: it is not "are there any
      // enrollments", it is "is there one the atSign could restore itself
      // with". A wavi-scoped enrollment cannot approve a replacement root.
      await installFlatCredential();
      await storeApprovedEnrollment({'wavi': 'rw'});
      await writeDeadline(DateTime.now()
          .toUtc()
          .subtract(Duration(days: 1))
          .toIso8601String());

      await enMgr.retireLegacyCredentialIfDue();

      expect(await enMgr.legacyPkamPublicKey(), 'FLAT_PKAM_KEY',
          reason: 'an enrollment that cannot admit a root leaves the atSign '
              'as stranded as no enrollment at all');
    });

    test('a root enrollment with an EMPTY public key does not license the '
        'removal', () async {
      // A phantom root: approved, fully privileged, and holding a credential
      // no signature can ever be checked against. Counting it would answer
      // "the atSign can restore itself" with an identity nobody holds.
      await installFlatCredential();
      await storeApprovedEnrollment({'*': 'rw', '__manage': 'rw'},
          apkamPublicKey: '');
      await writeDeadline(DateTime.now()
          .toUtc()
          .subtract(Duration(days: 1))
          .toIso8601String());

      await enMgr.retireLegacyCredentialIfDue();

      expect(await enMgr.legacyPkamPublicKey(), 'FLAT_PKAM_KEY',
          reason: 'a zero-length apkamPublicKey is not a credential, so the '
              'record is not a root the atSign could fall back on');
    });

    test('a declined removal happens once the atSign has a root again',
        () async {
      // The decline is a re-ask, not an exemption. This is what makes the
      // deadline survive it worth keeping.
      await installFlatCredential();
      await writeDeadline(DateTime.now()
          .toUtc()
          .subtract(Duration(days: 1))
          .toIso8601String());
      await enMgr.retireLegacyCredentialIfDue();
      expect(await enMgr.legacyPkamPublicKey(), isNotNull,
          reason: 'precondition: the first pass declined');

      await storeApprovedEnrollment({'*': 'rw', '__manage': 'rw'});
      await enMgr.retireLegacyCredentialIfDue();

      expect(await enMgr.legacyPkamPublicKey(), isNull,
          reason: 'the question the decline asked is asked again on every '
              'sweep, so the clock completes when the answer changes');
    });

    test('the stranding question does NOT count the credential being removed',
        () async {
      // The asymmetry that would make the guard vacuous: the ordinary
      // hasUnexpiringRootEnrollment counts the flat credential first, so
      // asking it here would have every removal license itself.
      await installFlatCredential();

      expect(await enMgr.hasUnexpiringRootEnrollment({}), isTrue,
          reason: 'CONTROL: the flat credential IS a usable root, which is '
              'why every other act may count it');
      expect(await enMgr.hasUnexpiringRootEnrollmentRecord({}), isFalse,
          reason: 'but the act whose subject IS that credential must ask the '
              'roster alone, or "something survives" is answered by the very '
              'thing being taken away');
    });

    test('an expiring root enrollment does not license the removal', () async {
      // "Unexpiring" is load-bearing. A root that is itself on a timer leaves
      // the atSign stranded the moment it goes, and by then the flat
      // credential is gone too.
      await installFlatCredential();
      final id = await storeApprovedEnrollment({'*': 'rw', '__manage': 'rw'});
      await keyValueStore.putMeta(
          enMgr.buildEnrollmentKey(id), AtMetaData()..ttl = 60 * 60 * 1000,
          skipCommit: true);
      await writeDeadline(DateTime.now()
          .toUtc()
          .subtract(Duration(days: 1))
          .toIso8601String());

      await enMgr.retireLegacyCredentialIfDue();

      expect(await enMgr.legacyPkamPublicKey(), 'FLAT_PKAM_KEY',
          reason: 'a root with an hour left on it is not something the atSign '
              'can fall back on after the flat credential is gone');
    });

    test('a deadline standing over a credential already gone is dropped',
        () async {
      await writeDeadline(DateTime.now()
          .toUtc()
          .subtract(Duration(days: 1))
          .toIso8601String());

      await enMgr.retireLegacyCredentialIfDue();

      expect(await deadlineRecord(), isNull,
          reason: 'the deadline has nothing left to act on, and one left '
              'standing would fire on whatever was installed at that key '
              'afterwards');
    });

    test('an unreadable deadline removes nothing', () async {
      await installFlatCredential();
      await storeApprovedEnrollment({'*': 'rw', '__manage': 'rw'});
      await writeDeadline('not-a-timestamp');

      await enMgr.retireLegacyCredentialIfDue();

      expect(await enMgr.legacyPkamPublicKey(), 'FLAT_PKAM_KEY',
          reason: 'a removal that cannot say when it fell due is not one to '
              'make');
    });

    // ---- the wiring ----

    test('the server\'s housekeeping sweep runs the retirement', () async {
      // What schedules it. The deadline is deliberately NOT a ttl — a ttl
      // would have the store delete the key on its own schedule, and this
      // removal has a question to ask first — so it needs a tick of its own,
      // and the claim that it gets one is asserted here rather than reasoned
      // from the timer's existence.
      await installFlatCredential();
      await storeApprovedEnrollment({'*': 'rw', '__manage': 'rw'});
      await writeDeadline(DateTime.now()
          .toUtc()
          .subtract(Duration(minutes: 1))
          .toIso8601String());

      await AtSecondaryServerImpl.getInstance().runHousekeepingSweep();

      expect(await enMgr.legacyPkamPublicKey(), isNull,
          reason: 'the sweep the expiry timer drives is what notices a '
              'deadline nothing else is watching');
    });
  });
}
