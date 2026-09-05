import 'dart:convert';

import 'package:at_chops/at_chops.dart'
    show
        AtChopsImpl,
        AtChopsKeys,
        AtChopsUtil,
        AtSigningInput,
        AtSigningMode,
        HashingAlgoType,
        SigningAlgoType;
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/verb/handler/pkam_verb_handler.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';

import 'enrollment_test_utils.dart';
import 'test_utils.dart';

/// Pins that an enrollment id names the record the KEYSTORE resolves it to.
/// Every key is folded before it is stored or read, trimmed, lowercased and
/// with spaces stripped, while comparisons above the keystore are exact
/// `String ==`.
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

  /// U+3000 IDEOGRAPHIC SPACE, the adversarial spelling used throughout.
  const String wsWrite = '\u{3000}';

  /// U+00A0 NO-BREAK SPACE, refused by the write-path key validator.
  const String wsRead = '\u{00A0}';

  /// Writes an enrollment straight to the store under [id], always canonical.
  Future<void> mint(String id,
      {Map<String, String> namespaces = const {'*': 'rw', '__manage': 'rw'},
      EnrollmentStatus status = EnrollmentStatus.approved,
      String? approvedBy,
      String? replacing,
      Duration? ttl}) async {
    final v = EnrollDataStoreValue('s', 'app-$id', 'device-$id', 'pk-$id')
      ..namespaces = Map<String, String>.from(namespaces)
      ..approval = EnrollApproval(status.name)
      ..parentEnrollmentId = approvedBy
      ..retrofitPredecessorEnrollmentId = replacing;
    await enMgr.put(
        id,
        AtData()
          ..data = jsonEncode(v.toJson())
          ..metaData = (AtMetaData()..ttl = ttl?.inMilliseconds ?? 0),
        status);
  }

  Future<Response> enroll(String command, {String? callerId}) async {
    inboundConnection.metaData
      ..isAuthenticated = true
      ..authType = AuthType.apkam;
    inboundConnection.metadata.enrollmentId = callerId;
    final r = Response();
    await etu.evh.processVerb(
      r,
      getVerbParam(VerbSyntax.enroll, command),
      inboundConnection,
    );
    return r;
  }

  /// The status ON DISK, never through [EnrollmentManager]'s cache.
  Future<String> storedStatusOf(String id) async {
    final rec = await keyValueStore.get(enMgr.buildEnrollmentKey(id));
    if (rec?.data == null) return 'ABSENT';
    return (jsonDecode(rec!.data!)['approval']?['state']).toString();
  }


  /// [canonicalAtKey] is the keystore's OWN fold, not a second copy.
  group('the fold above the keystore is the keystore\'s fold', () {
    const canonicalKey = 'canon-subject.canon.test@alice';

    setUp(() async {
      await keyValueStore.put(canonicalKey, AtData()..data = 'v');
    });

    for (final spelling in <String, String>{
      'leading space': ' canon-subject.canon.test@alice',
      'trailing space': 'canon-subject.canon.test@alice ',
      'mixed case': 'Canon-Subject.Canon.Test@alice',
      'interior space': 'canon- subject.canon.test@alice',
      'ideographic space': '${wsWrite}canon-subject.canon.test@alice',
      'no-break space': '${wsRead}canon-subject.canon.test@alice',
      'all of it': '  Canon- Subject.Canon.Test@alice  ',
    }.entries) {
      test('${spelling.key} reaches the same record, and canonicalAtKey says '
          'so', () async {
        expect(await keyValueStore.exists(spelling.value), isTrue,
            reason: 'the STORE resolves this spelling to the record written '
                'under the canonical key — that is the fact everything above '
                'it has to agree with');
        expect(canonicalAtKey(spelling.value), canonicalKey,
            reason: 'and the shared fold predicts exactly which record, so a '
                'key built above the keystore is about the string on disk');
      });
    }

    test('a spelling that folds DIFFERENTLY reaches a different record',
        () async {
      // The control: an INTERIOR no-break space is not stripped.
      const other = 'canon-${wsRead}subject.canon.test@alice';
      expect(await keyValueStore.exists(other), isFalse);
      expect(canonicalAtKey(other), isNot(canonicalKey));
    });
  });


  group('the pkam entry point folds the id it is given', () {
    Future<Response> pkam(String idOnTheWire, String sessionId,
        AtSigningInput Function(String, String) inputFor,
        AtChopsImpl chops) async {
      final challenge = 'challenge-$sessionId';
      await keyValueStore.put(
          'private:$sessionId$alice', AtData()..data = challenge);
      inboundConnection.metaData
        ..isAuthenticated = false
        ..enrollmentId = null
        ..sessionID = sessionId;
      final signature = chops.sign(inputFor(sessionId, challenge)).result;
      final r = Response();
      await PkamVerbHandler(keyValueStore).processVerb(
        r,
        getVerbParam(
            VerbSyntax.pkam, 'pkam:enrollmentId:$idOnTheWire:$signature'),
        inboundConnection,
      );
      return r;
    }

    test('a connection authenticated under a non-canonical spelling carries '
        'the CANONICAL id', () async {
      final pair = AtChopsUtil.generateAtPkamKeyPair();
      final ep = EnrollParams()
        ..appName = 'signer'
        ..deviceName = 'device'
        ..apkamPublicKey = pair.atPublicKey.publicKey
        ..encryptedAPKAMSymmetricKey = 'encrypted apkam aes key'
        ..namespaces = {'wavi': 'rw'}
        ..otp = await etu.getOtp();
      inboundConnection.metaData
        ..isAuthenticated = false
        ..authType = null
        ..sessionID = 'req-session';
      final req = Response();
      await etu.evh.processVerb(
        req,
        getVerbParam(
            VerbSyntax.enroll, 'enroll:request:${jsonEncode(ep.toJson())}'),
        inboundConnection,
      );
      expect(req.isError, isFalse, reason: '${req.errorMessage}');
      final id = jsonDecode(req.data!)['enrollmentId'] as String;
      await etu.approveEnrollment(etu.primaryEnId, id);
      final chops = AtChopsImpl(AtChopsKeys.create(null, pair));
      AtSigningInput inputFor(String sessionId, String challenge) =>
          AtSigningInput('$sessionId$alice:$challenge')
            ..signingAlgoType = SigningAlgoType.rsa2048
            ..hashingAlgoType = HashingAlgoType.sha256
            ..signingMode = AtSigningMode.pkam;

      // The control: the canonical spelling authenticates.
      expect((await pkam(id, 'control-session', inputFor, chops)).data,
          'success',
          reason: 'precondition: this keypair authenticates as this '
              'enrollment');

      for (final spelling in [
        ' $id',
        id.toUpperCase(),
        '$wsWrite$id',
        '$wsRead$id',
      ]) {
        final r = await pkam(spelling, 'session-${spelling.hashCode}',
            inputFor, chops);
        expect(r.data, 'success',
            reason: 'the store resolves "$spelling" to this enrollment, so '
                'the authentication succeeds either way — which is exactly '
                'why the id LEFT ON THE CONNECTION matters');
        expect(inboundConnection.metaData.isAuthenticated, isTrue);
        expect(
            (inboundConnection.metaData as dynamic).enrollmentId as String?,
            id,
            reason: 'the connection must carry the id the KEYSTORE holds. '
                'Carrying "$spelling" instead makes every downstream '
                'comparison — the revoke\'s connection drop, the '
                'caller-in-cascade refusal, the self-only gate on '
                'enroll:update, and ownership of this enrollment\'s own '
                'reserved keys — answer about a string that is on no record');
      }
    });

    test('no id at all stays distinguishable from an empty one', () async {
      expect(EnrollmentManager.canonicalEnrollmentIdOrNull(null), isNull);
      expect(EnrollmentManager.canonicalEnrollmentIdOrNull('   '), isEmpty);
    });
  });


  group('the enroll entry point folds the id it is given', () {
    test('a self-revoke cannot be spelled around', () async {
      await expectLater(
          () => enroll(
              'enroll:revoke:'
              '${jsonEncode({'enrollmentId': '$wsWrite${etu.primaryEnId}'})}',
              callerId: etu.primaryEnId),
          throwsA(isA<AtEnrollmentRevokeException>().having(
              (e) => e.message,
              'message',
              contains('Current client cannot revoke its own enrollment'))),
          reason: 'the fold makes this the same enrollment, so the '
              'self-revoke refusal is the guard that answers');

      expect(await storedStatusOf(etu.primaryEnId),
          EnrollmentStatus.approved.name,
          reason: 'and the record is left alone');
    });

    test('...while revoking a DIFFERENT enrollment still works', () async {
      // The control: `enroll:revoke` does not refuse everything.
      final other = (await etu.createEnrollments(n: 1)).$1.first;
      final r = await enroll(
          'enroll:revoke:'
          '${jsonEncode({'enrollmentId': '$wsWrite${other.toUpperCase()}'})}',
          callerId: etu.primaryEnId);
      expect(r.isError, isFalse, reason: '${r.errorMessage}');
      expect(await storedStatusOf(other), EnrollmentStatus.revoked.name,
          reason: 'the non-canonical spelling revoked the record it names, '
              'which is what makes the refusal above a statement about '
              'identity rather than about spelling');
    });

    test('an id of nothing but whitespace is refused as a missing id',
        () async {
      await expectLater(
          () => enroll('enroll:revoke:${jsonEncode({'enrollmentId': '   '})}',
              callerId: etu.primaryEnId),
          throwsA(isA<IllegalArgumentException>().having((e) => e.message,
              'message', contains('enrollmentId is mandatory'))));
    });
  });

  /// `hasUnexpiringRootEnrollment` asks what would SURVIVE an act, matching
  /// built keys against the keys an enumeration returns.
  group('the last-root refusal counts what the act removes', () {
    /// A fully privileged caller that is not a descendant of the CRAM root
    /// and that expires.
    Future<String> outsideCaller() async {
      await mint('outside-caller', ttl: Duration(hours: 1));
      return 'outside-caller';
    }

    /// Drives the revoke and returns what it threw, the target's status ON
    /// DISK afterwards, and what it answered.
    Future<(Object?, String, Object?)> revokeLastRootAs(String caller) async {
      Object? thrown;
      Response? answered;
      try {
        answered = await enroll(
            'enroll:revoke:'
            '${jsonEncode({'enrollmentId': '$wsWrite${etu.primaryEnId}'})}',
            callerId: caller);
      } catch (e) {
        thrown = e;
      }
      return (thrown, await storedStatusOf(etu.primaryEnId), answered?.data);
    }

    test('a non-canonical exclusion still excludes the record', () async {
      expect(await enMgr.hasUnexpiringRootEnrollment({etu.primaryEnId}),
          isFalse,
          reason: 'precondition: the canonical spelling excludes it, and '
              'nothing else fully privileged and permanent exists');

      for (final spelling in [
        ' ${etu.primaryEnId}',
        etu.primaryEnId.toUpperCase(),
        '$wsWrite${etu.primaryEnId}',
        '$wsRead${etu.primaryEnId}',
      ]) {
        expect(await enMgr.hasUnexpiringRootEnrollment({spelling}), isFalse,
            reason: 'excluding "$spelling" names the record the act is about '
                'to rewrite, so it must not be counted as the root that '
                'survives — counting it strands the atSign silently');
      }
    });

    test('...and a genuinely different id is still counted', () async {
      // The control: a second permanent root exists for the walk to find.
      await mint('a-second-root');
      expect(
          await enMgr
              .hasUnexpiringRootEnrollment({'$wsWrite${etu.primaryEnId}'}),
          isTrue,
          reason: 'the exclusion is honoured AND the other root is found');
    });

    test('the enrollment key built from an id is the key the store holds',
        () async {
      final canonical = enMgr.buildEnrollmentKey(etu.primaryEnId);
      expect(await enMgr.getAllEnrollmentKeys(includeExpired: false),
          contains(canonical),
          reason: 'precondition: a canonical id builds a key the enumeration '
              'returns');

      for (final spelling in [
        ' ${etu.primaryEnId}',
        etu.primaryEnId.toUpperCase(),
        '$wsWrite${etu.primaryEnId}',
        '$wsRead${etu.primaryEnId}',
        '${etu.primaryEnId} ',
        '${etu.primaryEnId}\t',
        '${etu.primaryEnId}$wsWrite',
        '${etu.primaryEnId}$wsRead',
      ]) {
        expect(enMgr.buildEnrollmentKey(spelling), canonical,
            reason: 'a key built from "$spelling" has to be comparable '
                'against an enumerated one, or every set-membership test '
                'built on it is vacuous');
      }
    });

    test('revoking the last root through a non-canonical spelling is REFUSED',
        () async {
      final caller = await outsideCaller();
      final outcome = await revokeLastRootAs(caller);
      expect(
          outcome.$1,
          isA<AtEnrollmentRevokeException>().having((e) => e.message,
              'message', contains('unable to approve a replacement')),
          reason: 'the atSign\'s only permanent root is what this act would '
              'remove and nothing permanent would be left, so the refusal '
              'must fire. It answered ${outcome.$3} instead');
    });

    test('...and the last root is STILL THERE afterwards', () async {
      final caller = await outsideCaller();
      final outcome = await revokeLastRootAs(caller);
      expect(outcome.$2, EnrollmentStatus.approved.name,
          reason: 'the atSign must still hold a fully privileged, permanent '
              'enrollment it can restore itself from');
    });

    test('...while the same command is allowed once another permanent root '
        'exists', () async {
      // The control: the same revoke where the act does not strand the atSign.
      final caller = await outsideCaller();
      await mint('a-second-root');
      final r = await enroll(
          'enroll:revoke:'
          '${jsonEncode({'enrollmentId': '$wsWrite${etu.primaryEnId}'})}',
          callerId: caller);
      expect(r.isError, isFalse, reason: '${r.errorMessage}');
      expect(await storedStatusOf(etu.primaryEnId),
          EnrollmentStatus.revoked.name);
    });
  });

  /// A cascade walks the approval edge upward from every stored enrollment,
  /// comparing each link against the id being revoked.
  group('the revocation cascade cannot be spelled around', () {
    test('descendantsOf finds the subtree through a folding space', () async {
      await mint('child-of-root',
          namespaces: {'wavi': 'rw'}, approvedBy: etu.primaryEnId);
      await mint('grandchild',
          namespaces: {'wavi': 'rw'}, approvedBy: 'child-of-root');

      expect(await enMgr.descendantsOf(etu.primaryEnId),
          {'child-of-root', 'grandchild'},
          reason: 'precondition: the chain is there and the walk finds it');

      for (final ws in [wsRead, wsWrite, ' ']) {
        expect(await enMgr.descendantsOf('$ws${etu.primaryEnId}'),
            {'child-of-root', 'grandchild'},
            reason: 'a leading space of any kind folds away, so this names '
                'the same enrollment — measured: unfolded, this returned {} '
                'and the whole subtree survived the revoke');
      }
    });

    test('an approver id an older server stored uppercased still names its '
        'approver', () async {
      await mint('upper-approver', namespaces: {'*': 'rw', '__manage': 'rw'});
      await mint('upper-child',
          namespaces: {'wavi': 'rw'}, approvedBy: 'UPPER-APPROVER');

      expect(await enMgr.descendantsOf('upper-approver'),
          contains('upper-child'),
          reason: 'the stored link is folded before it is compared, so a '
              'record written under an unfolded spelling is still swept by '
              'the revoke of the enrollment that admitted it');
    });

    test('...and the adoption pass re-parents it too', () async {
      await mint('upper-pred', namespaces: {'*': 'rw', '__manage': 'rw'});
      await mint('upper-succ',
          namespaces: {'*': 'rw', '__manage': 'rw'},
          replacing: 'upper-pred');
      await mint('upper-kid',
          namespaces: {'wavi': 'rw'}, approvedBy: 'UPPER-PRED');

      await enMgr.settlePredecessorOnFirstAuth('upper-succ');

      expect((await enMgr.getEnrollmentById('upper-kid')).parentEnrollmentId,
          'upper-succ',
          reason: 'the pass runs once, so an unfolded link left behind here '
              'is orphaned for good');
    });

    test('...and still returns nothing for an enrollment that admitted nobody',
        () async {
      // The control: an empty answer must stay reachable.
      await mint('admits-nobody', namespaces: {'wavi': 'rw'});
      expect(await enMgr.descendantsOf('$wsRead admits-nobody'), isEmpty);
    });

    test('a revoke through a non-canonical spelling sweeps the subtree',
        () async {
      await mint('mid-approver',
          namespaces: {'wavi': 'rw', '__manage': 'rw'},
          approvedBy: etu.primaryEnId);
      await mint('leaf',
          namespaces: {'wavi': 'rw'}, approvedBy: 'mid-approver');

      final r = await enroll(
          'enroll:revoke:'
          '${jsonEncode({'enrollmentId': '${wsWrite}mid-approver'})}',
          callerId: etu.primaryEnId);
      expect(r.isError, isFalse, reason: '${r.errorMessage}');

      expect(await storedStatusOf('mid-approver'),
          EnrollmentStatus.revoked.name);
      expect(await storedStatusOf('leaf'), EnrollmentStatus.revoked.name,
          reason: 'the enrollment the target admitted goes with it. Unfolded, '
              'the target was revoked and this one was not, so a stolen '
              'credential kept everything it had ever admitted');
    });

    test('the per-enrollment move matches a folded id against folded keys',
        () async {
      await mint('move-subject', namespaces: {'wavi': 'rw'});
      await keyValueStore.put('public:_apsk.move-subject.a.__e@alice',
          AtData()..data = 'signing-key');

      final moved = await enMgr.movePerEnrollmentDataFor(
          {'${wsWrite}MOVE-SUBJECT'},
          to: EnrollmentConstants.perEnrollmentRevoked);

      expect(moved, ['public:_apsk.move-subject.a.__e@alice'],
          reason: 'the spelling names the same enrollment as the key it is '
              'being matched against, so the move has to happen');
    });

    test('...and still moves nothing for a genuinely different enrollment',
        () async {
      // The control: the fold does not match everything.
      await mint('move-subject', namespaces: {'wavi': 'rw'});
      await keyValueStore.put('public:_apsk.move-subject.a.__e@alice',
          AtData()..data = 'signing-key');
      expect(
          await enMgr.movePerEnrollmentDataFor({'${wsWrite}someone-else'},
              to: EnrollmentConstants.perEnrollmentRevoked),
          isEmpty);
    });

    test('per-enrollment data moves out of the approved location too',
        () async {
      await mint('apsk-holder',
          namespaces: {'wavi': 'rw'}, approvedBy: etu.primaryEnId);
      await keyValueStore.put('public:_apsk.apsk-holder.a.__e@alice',
          AtData()..data = 'signing-key');

      final r = await enroll(
          'enroll:revoke:'
          '${jsonEncode({'enrollmentId': '${wsWrite}apsk-holder'})}',
          callerId: etu.primaryEnId);
      expect(r.isError, isFalse, reason: '${r.errorMessage}');

      expect(await keyValueStore.exists('public:_apsk.apsk-holder.a.__e@alice'),
          isFalse,
          reason: 'the approved-location copy is gone');
      expect(await keyValueStore.exists('public:_apsk.apsk-holder.r.__e@alice'),
          isTrue,
          reason: 'and it is parked in the revoked location, which is what '
              'revoking a published signing key IS');
    });
  });


  group('per-enrollment reserved keys are owned by the folded id', () {
    test('a caller\'s own key is not foreign however it is spelled', () {
      expect(
          AbstractVerbHandler.isForeignPerEnrollmentReservedKey(
              '_apsk.abc.a.__e@alice', 'abc',
              isMutating: true),
          isFalse,
          reason: 'precondition: the canonical spelling is its own');

      for (final ws in [wsRead, wsWrite, ' ']) {
        expect(
            AbstractVerbHandler.isForeignPerEnrollmentReservedKey(
                '_apsk.${ws}abc.a.__e@alice', 'abc',
                isMutating: true),
            isFalse,
            reason: 'the keystore folds this key to the caller\'s own, so a '
                'guard calling it foreign is answering about a record that '
                'is not the one being served');
      }
    });

    test('...and another enrollment\'s key still is', () {
      // The control: the fold does not make every caller's key its own.
      expect(
          AbstractVerbHandler.isForeignPerEnrollmentReservedKey(
              '_apsk.${wsWrite}xyz.a.__e@alice', 'abc',
              isMutating: true),
          isTrue);
    });
  });

  /// Which whitespace `AtKey.getKeyType` accepts decides which non-canonical
  /// spellings reach a WRITE at all, pinned here rather than assumed.
  group('which folding whitespace survives the write-path key validator', () {
    const id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

    KeyType typeOf(String prefix) => AtKey.getKeyType(
        '$prefix$id.new.enrollments.__manage@alice'.toLowerCase(),
        enforceNameSpace: false);

    test('a space, a tab and a no-break space are refused', () {
      for (final ws in [' ', '\t', wsRead]) {
        expect(typeOf(ws), KeyType.invalidKey,
            reason: 'these spellings fold, but never reach a guard: the '
                'write is refused first');
        expect(canonicalAtKey('$ws$id'), id,
            reason: 'they DO fold, so a read still resolves to the record');
      }
    });

    test('an ideographic space, an en quad and a line separator are ACCEPTED',
        () {
      for (final ws in ['\u{3000}', '\u{2000}', '\u{2028}']) {
        expect(typeOf(ws), isNot(KeyType.invalidKey),
            reason: 'these fold AND pass validation, so they reach the write '
                'and the guards above are what has to stop them');
        expect(canonicalAtKey('$ws$id'), id);
      }
    });
  });

  /// A built key's job is to be COMPARABLE against a key an enumeration
  /// returned. ⚠️ AT-REST PIN: frozen; `keys:` hands these names to
  /// clients.
  group('a built key is the key the store holds', () {
    /// Everything the production write path stored under the PEK regex.
    Future<List<String>> storedPeks() async =>
        (await keyValueStore.getKeys(regex: EnrollmentConstants.regexForPEK))
            .toList();

    Future<List<String>> storedSeks() async =>
        (await keyValueStore.getKeys(regex: EnrollmentConstants.regexForSEK))
            .toList();

    /// An approved enrollment whose encryption keys the APPROVE path wrote.
    Future<String> approvedWithEncryptionKeys() async {
      final id = await etu.createPendingEnrollment(
          appName: 'pek-app',
          deviceName: 'pek-device',
          namespaces: {'wavi': 'rw'},
          apkamKeysExpiryDuration: null);
      await etu.approveEnrollment(etu.primaryEnId, id);
      return id;
    }

    test('keyForPEK and keyForSEK name the records the approve path wrote',
        () async {
      final id = await approvedWithEncryptionKeys();

      expect(await storedPeks(), isNotEmpty,
          reason: 'precondition: the corpus is non-empty, or every '
              'membership test below reports a clean zero');
      expect(await storedSeks(), isNotEmpty, reason: 'likewise');

      expect(await storedPeks(), contains(enMgr.keyForPEK(id)),
          reason: 'the built key has to be BYTE-IDENTICAL to the enumerated '
              'one: the orphan sweep matches enumerated candidates against '
              'built ones, and `keys:` authorises a caller for its own '
              'encryption keys by name');
      expect(await storedSeks(), contains(enMgr.keyForSEK(id)),
          reason: 'likewise');
    });

    test('...and their at-rest form is these exact strings', () {
      // ⚠️ AT-REST PIN: raw literal, frozen; records on disk are addressable
      // only by this form.
      const id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
      expect(enMgr.keyForPEK(id),
          'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.default_enc_private_key'
          '.__manage@alice');
      expect(enMgr.keyForSEK(id),
          'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.default_self_enc_key'
          '.__manage@alice');
    });

    test('a non-canonical id builds the same key for both', () async {
      final id = await approvedWithEncryptionKeys();
      for (final spelling in [
        ' $id',
        id.toUpperCase(),
        '$wsWrite$id',
        '$id\t',
        '$id$wsWrite',
        '$id$wsRead',
      ]) {
        expect(enMgr.keyForPEK(spelling), enMgr.keyForPEK(id),
            reason: 'the PEK key built from "$spelling" must name the record '
                'the approve path wrote, or `keys:` authorises a caller for a '
                'name the store does not hold');
        expect(enMgr.keyForSEK(spelling), enMgr.keyForSEK(id),
            reason: 'likewise for the SEK key');
      }
    });


    /// The one key builder whose components are CLIENT-CHOSEN: the app and
    /// device names arrive from the wire.
    const String app = 'MyApp';
    const String device = 'MyDevice';

    EnrollDataStoreValue legacyHolder() => EnrollDataStoreValue(
        'session', app, device, 'the-apps-own-apkam-key')
      ..namespaces = {'wavi': 'rw'}
      ..approval = EnrollApproval(EnrollmentStatus.approved.name);

    /// Writes the key under the RAW spelling a server that wrote it handed
    /// the keystore, and returns the key as the store enumerates it.
    Future<String> seedLegacyApkamKey() async {
      await keyValueStore.put(
          'public:$app.$device.pkam.__pkams.__public_keys$alice',
          AtData()..data = 'the-apps-own-apkam-key',
          skipCommit: true);
      final stored = await (await keyValueStore.getKeys(
              regex: '\\.pkam\\.__pkams\\.__public_keys@'))
          .toList();
      expect(stored, hasLength(1),
          reason: 'precondition: exactly one such key is on disk, so the '
              'assertions below cannot match a neighbour');
      return stored.single;
    }

    test('keyForLegacyPK names the record the store holds, not the spelling '
        'the client sent', () async {
      final String asStored = await seedLegacyApkamKey();

      expect(asStored,
          'public:myapp.mydevice.pkam.__pkams.__public_keys@alice',
          reason: 'RAW-LITERAL and AT-REST: this is what the keystore folded '
              'the client\'s "MyApp"/"MyDevice" down to, and the only form a '
              'record written by an older server is addressable under');
      expect(enMgr.keyForLegacyPK(legacyHolder()), asStored,
          reason: 'the builder has to produce the ENUMERATED string. It is '
              'the one builder whose components come from the wire, so a '
              'capital would otherwise build a key the store does not hold '
              'under that spelling — and every comparison against an '
              'enumerated key would then answer about a different string');
    });

    test('CONTROL: the startup sweep removes it either way', () async {
      // The control that the fixture is a real record the sweep reaches.
      await seedLegacyApkamKey();
      await enMgr.put(
          'legacy-holder',
          AtData()..data = jsonEncode(legacyHolder().toJson()),
          EnrollmentStatus.approved);

      expect(await enMgr.removeLegacyApkamPublicKeys(),
          contains(enMgr.buildEnrollmentKey('legacy-holder')));
      expect(
          await keyValueStore
              .exists('public:myapp.mydevice.pkam.__pkams.__public_keys@alice'),
          isFalse,
          reason: 'the key that leaks the app and device names is gone');
    });
  });
}
