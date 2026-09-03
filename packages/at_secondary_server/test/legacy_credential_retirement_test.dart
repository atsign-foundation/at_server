import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
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
              '"namespaces":{"wavi":"rw"},"apkamPublicKey":"APKAM_KEY-${Uuid().v4()}"}'),
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
          '"apkamPublicKey":"APKAM_KEY-${Uuid().v4()}"}');
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

    /// A second fully privileged enrollment that is NOT a permanent survivor:
    /// same grants as a root, but with an expiry, so it cannot be the
    /// unexpiring root the stranding question is satisfied by.
    Future<String> storeExpiringFullGrant() async {
      final id = await storeApprovedEnrollment({'*': 'rw', '__manage': 'rw'});
      final AtData record =
          (await keyValueStore.get(enMgr.buildEnrollmentKey(id)))!;
      await enMgr.put(id, record, EnrollmentStatus.approved,
          assertedTimestamps: AtAssertedTimestamps(
              expiresAt: DateTime.now().toUtc().add(Duration(hours: 1)),
              deriveTtl: true));
      return id;
    }

    /// `enroll:revoke` of [target], issued by the enrollment [asId].
    Future<Response> revoke(String target, {required String asId}) async {
      inboundConnection.metaData
        ..isAuthenticated = true
        ..authType = AuthType.apkam
        ..sessionID = 'session-${Uuid().v4()}';
      inboundConnection.metadata.enrollmentId = asId;
      final r = Response();
      await enrollVerbHandler.processVerb(
          r,
          getVerbParam(
              VerbSyntax.enroll, 'enroll:revoke:{"enrollmentId":"$target"}'),
          inboundConnection);
      return r;
    }

    Future<bool> aUsableRootSurvives() =>
        enMgr.hasUnexpiringRootEnrollment({});

    test('startup migrates the flat key into primary before the clock could '
        'arm, so nothing is armed', () async {
      // BEHAVIOUR CHANGED. The startup arming ran for an atSign whose owner
      // minted enrollments before this server ever ran. The flat key is now
      // migrated into the `primary` enrollment ahead of it, so by the time
      // the arming asks there is no flat key to put on a clock.
      await installFlatCredential();
      await storeApprovedEnrollment({'wavi': 'rw'});
      expect(await deadlineRecord(), isNull,
          reason: 'precondition: nothing has armed it yet');

      await AtSecondaryServerImpl.getInstance().prepareStoreForFirstConnection();

      expect(await deadlineRecord(), isNull,
          reason: 'the migration ran first and left no flat key to arm');
      expect(await enMgr.legacyPkamPublicKey(), isNull);
      expect(
          (await enMgr.getEnrollmentById(
                  EnrollmentManager.primaryEnrollmentId))
              .apkamPublicKey,
          'FLAT_PKAM_KEY',
          reason: 'the credential became a record rather than a deadline');
    });

    test('...but a virgin store arms nothing, and neither does an atSign '
        'with no flat credential', () async {
      // Two controls, because the arm has two preconditions and a startup
      // step that armed on a virgin store would put a removal deadline
      // against a key installed later for some entirely different reason.
      await installFlatCredential();
      await AtSecondaryServerImpl.getInstance().prepareStoreForFirstConnection();
      expect(await deadlineRecord(), isNull,
          reason: 'flat credential but NO enrollments: nothing has migrated, '
              'nothing to schedule');

      await keyValueStore.remove(AtConstants.atPkamPublicKey, skipCommit: true);
      await storeApprovedEnrollment({'wavi': 'rw'});
      await AtSecondaryServerImpl.getInstance().prepareStoreForFirstConnection();
      expect(await deadlineRecord(), isNull,
          reason: 'enrollments but NO flat credential: nothing to retire');
    });

    // The two places the server actually runs the sweep. Each is pinned on
    // its own, because one being right says nothing about the other: the
    // retirement has no ttl and no other trigger, so a site that stopped
    // calling the sweep would leave every deadline unwatched with nothing
    // going red. A test that calls runHousekeepingSweep() directly proves the
    // sweep works, not that anything runs it.
    Future<void> aDueRetirement() async {
      await installFlatCredential();
      await storeApprovedEnrollment({'*': 'rw', '__manage': 'rw'});
      await writeDeadline(DateTime.now()
          .toUtc()
          .subtract(Duration(minutes: 1))
          .toIso8601String());
      expect(await enMgr.legacyPkamPublicKey(), isNotNull,
          reason: 'precondition: there is a credential to retire');
    }

    test('the startup path runs the sweep', () async {
      // Pinned on an expired key rather than on a due retirement: the flat
      // key is migrated before the sweep runs, so a retirement that fell due
      // finds nothing to retire, and a pin on it would be green whether or
      // not the sweep ran.
      await keyValueStore.put('elapsed.wavi$alice', AtData()..data = 'x',
          assertedTimestamps: AtAssertedTimestamps(
              expiresAt: DateTime.now().toUtc().subtract(Duration(minutes: 1)),
              deriveTtl: true));
      expect(await keyValueStore.exists('elapsed.wavi$alice'), isTrue,
          reason: 'precondition: elapsed, and still on disk');

      await AtSecondaryServerImpl.getInstance().prepareStoreForFirstConnection();

      expect(await keyValueStore.exists('elapsed.wavi$alice'), isFalse,
          reason: 'a key that expired while the server was down is reaped on '
              'the way up, by the startup path itself and not by a sweep '
              'some test called for it');
    });

    test('the expiry timer\'s callback runs the sweep', () async {
      await aDueRetirement();
      await AtSecondaryServerImpl.getInstance().onExpirySweepTimerFired();
      expect(await enMgr.legacyPkamPublicKey(), isNull,
          reason: 'what the timer fires is what watches the deadline; a '
              'callback that only reaped expired keys would leave the flat '
              'credential in place for ever, with the timer ticking');
    });

    test('the sweep and a revoke in flight together cannot strand the atSign',
        () async {
      // The sweep decides "an unexpiring root survives, so the flat key may
      // go" on the roster; the revoke decides "the flat key still works, so
      // this root may go" on the store. Each is right on the state it read,
      // and if they read it at the same moment they are each licensed by the
      // thing the other is removing. That is a decide-then-write over the same
      // state as every enroll: mutation, so it belongs in the same section.
      //
      // The caller is FULLY privileged but EXPIRING, which is load-bearing: a
      // permanent caller would itself be the surviving root, and neither
      // removal would strand anything.
      await installFlatCredential();
      await writeDeadline(DateTime.now()
          .toUtc()
          .subtract(Duration(minutes: 1))
          .toIso8601String());
      final root = await storeApprovedEnrollment({'*': 'rw', '__manage': 'rw'});
      final caller = await storeExpiringFullGrant();
      expect(await aUsableRootSurvives(), isTrue,
          reason: 'precondition: the atSign starts with something to lose');

      await Future.wait([
        AtSecondaryServerImpl.getInstance().runHousekeepingSweep(),
        revoke(root, asId: caller),
      ]);

      expect(await aUsableRootSurvives(), isTrue,
          reason: 'whichever ran second saw the other\'s write and declined: '
              'either the flat key was kept because the root had gone, or '
              'the revoke was refused because the flat key had gone. Both '
              'gone is the race, and there is no verb that puts either back');
    });

    test('...and each SERIAL order is safe on its own, which is the control',
        () async {
      // Without this the assertion above is satisfied by a sweep that never
      // removes anything, or a revoke that never succeeds. Each order must
      // leave a root AND must show one of the two acts actually happened.
      await installFlatCredential();
      await writeDeadline(DateTime.now()
          .toUtc()
          .subtract(Duration(minutes: 1))
          .toIso8601String());
      final root = await storeApprovedEnrollment({'*': 'rw', '__manage': 'rw'});
      final caller = await storeExpiringFullGrant();

      // Sweep first: the root licenses removing the flat key; the revoke is
      // then refused as taking the last permanent root.
      await AtSecondaryServerImpl.getInstance().runHousekeepingSweep();
      expect(await enMgr.legacyPkamPublicKey(), isNull,
          reason: 'sweep-first: the flat key really was removed');
      await expectLater(
          () => revoke(root, asId: caller),
          throwsA(isA<AtEnrollmentRevokeException>().having(
              (e) => e.message, 'message', contains('is permanent'))),
          reason: 'sweep-first: with the flat key gone, this revoke would take '
              'the last permanent root and must be refused — and it is '
              'refused by THROWING, which is the channel this handler uses');
      expect(await aUsableRootSurvives(), isTrue,
          reason: 'sweep-first leaves the root standing');
    });
  });
}
