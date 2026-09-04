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
/// with spaces stripped, so `' abc'`, `'A b c'` and `'abc'` are three
/// spellings of one enrollment, while comparisons above the keystore are
/// exact `String ==`. An unfolded spelling therefore reaches the right record
/// while comparing unequal to it, and every guard phrased as "is this the
/// enrollment we are acting on?" answers no about the enrollment being acted
/// on. Two things close that, and both are pinned here: the wire folds an
/// incoming id to exactly the keystore's fold, and the key builders return
/// keys in exactly the form the keystore holds them, so a built key is
/// comparable against an enumerated one.
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
  /// `AtKey.getKeyType` runs on the WRITE path and refuses a space, a tab or
  /// a no-break space, so those never reach a guard; it accepts U+3000, which
  /// `String.trim()` strips like a space. A no-break space here would pass
  /// for the wrong reason, refused by the validator rather than the guard.
  const String wsWrite = '\u{3000}';

  /// U+00A0 NO-BREAK SPACE, refused by the write-path key validator, so it is
  /// used only where the path under test is a read or a comparison.
  const String wsRead = '\u{00A0}';

  /// Writes an enrollment straight to the store under [id], always canonical:
  /// the non-canonical spellings are what the TESTS send, never what is
  /// stored.
  Future<void> mint(String id,
      {Map<String, String> namespaces = const {'*': 'rw', '__manage': 'rw'},
      EnrollmentStatus status = EnrollmentStatus.approved,
      String? approvedBy,
      Duration? ttl}) async {
    final v = EnrollDataStoreValue('s', 'app-$id', 'device-$id', 'pk-$id')
      ..namespaces = Map<String, String>.from(namespaces)
      ..approval = EnrollApproval(status.name)
      ..parentEnrollmentId = approvedBy;
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

  /// The status ON DISK, never through [EnrollmentManager]'s cache: the cache
  /// is keyed by the key the writer built, so a cached read cannot tell a
  /// write that landed on the record from one that missed it.
  Future<String> storedStatusOf(String id) async {
    final rec = await keyValueStore.get(enMgr.buildEnrollmentKey(id));
    if (rec?.data == null) return 'ABSENT';
    return (jsonDecode(rec!.data!)['approval']?['state']).toString();
  }

  // ---- the fold itself, measured against the store ----

  /// [canonicalAtKey] is the keystore's OWN fold, not a second copy. Every
  /// guard below rests on the two agreeing, and two spellings of one rule can
  /// drift with nothing going red, since a non-canonical key still resolves.
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
      // The negative control: a fold that collapsed everything would satisfy
      // every case above. An INTERIOR no-break space is not stripped, only a
      // leading or trailing one.
      const other = 'canon-${wsRead}subject.canon.test@alice';
      expect(await keyValueStore.exists(other), isFalse);
      expect(canonicalAtKey(other), isNot(canonicalKey));
    });
  });

  // ---- entry point 1: the id presented on a `pkam:` command ----

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

      // The control, drawn from the capability rather than the property under
      // test: the canonical spelling authenticates, so a failure below is
      // about the spelling, not about a signature the server will not take.
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
      // A legacy pkam presents no enrollment id and the handler branches on
      // exactly that, so folding must not turn null into ''.
      expect(EnrollmentManager.canonicalEnrollmentIdOrNull(null), isNull);
      expect(EnrollmentManager.canonicalEnrollmentIdOrNull('   '), isEmpty);
    });
  });

  // ---- entry point 2: the id inside an `enroll:*` params document ----

  group('the enroll entry point folds the id it is given', () {
    test('a self-revoke cannot be spelled around', () async {
      // Unfolded, this compares unequal to the id on the connection, so the
      // refusal does not fire and the same id sweeps none of the subtree.
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
      // The control: without it the refusal above is satisfied by
      // `enroll:revoke` refusing everything.
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
      // Unfolded, `'   '` is not empty, passes validation and is carried into
      // a key naming no enrollment.
      await expectLater(
          () => enroll('enroll:revoke:${jsonEncode({'enrollmentId': '   '})}',
              callerId: etu.primaryEnId),
          throwsA(isA<IllegalArgumentException>().having((e) => e.message,
              'message', contains('enrollmentId is mandatory'))));
    });
  });

  /// `hasUnexpiringRootEnrollment` asks what would SURVIVE an act, so it
  /// excludes the ids the act is about to remove by building each one's key
  /// and matching it against the keys an enumeration returns. A key built
  /// from an unfolded id matches nothing, so the enrollment being revoked is
  /// counted as the root that survives its own revocation and the atSign is
  /// stranded while the verb reports success.
  group('the last-root refusal counts what the act removes', () {
    /// A fully privileged caller that is NOT a descendant of the CRAM root,
    /// so the descends-from-target refusal cannot be what answers, and that
    /// EXPIRES, so it cannot itself satisfy the liveness walk.
    Future<String> outsideCaller() async {
      await mint('outside-caller', ttl: Duration(hours: 1));
      return 'outside-caller';
    }

    /// Drives the revoke and returns (what it threw, the target's status ON
    /// DISK afterwards, what it answered) without asserting anything, so each
    /// caller can assert exactly one thing.
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
      // The control: a second permanent root exists, so a `true` here can
      // only come from the walk finding it. Without it the case above is
      // satisfied by the walk returning false for everything.
      await mint('a-second-root');
      expect(
          await enMgr
              .hasUnexpiringRootEnrollment({'$wsWrite${etu.primaryEnId}'}),
          isTrue,
          reason: 'the exclusion is honoured AND the other root is found');
    });

    test('the enrollment key built from an id is the key the store holds',
        () async {
      // The mechanism the case above rests on: the exclusion is done by KEY,
      // so the builder is where a non-canonical id stops mattering.
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
        // TRAILING, the half a leading spelling cannot reach: composition
        // puts whatever trails the id in the MIDDLE of the key, past the
        // trim, and the space-strip catches a plain space and nothing else,
        // so folding only the COMPOSED string leaves the key naming no
        // record.
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
      // The per-enrollment key builders carry the same contract, asserted
      // against the STORE in 'a built key is the key the store holds' below.
      // Comparing a builder against ITSELF under two spellings would pin only
      // the fold's idempotence: both sides move together under any change to
      // the builder, so the pair stays equal while naming a record the
      // keystore does not hold.
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
      // A separate case, not a second assertion: `expect` throws on failure,
      // so a failing refusal assertion would take the on-disk one with it,
      // and the on-disk state is the whole harm.
      final caller = await outsideCaller();
      final outcome = await revokeLastRootAs(caller);
      expect(outcome.$2, EnrollmentStatus.approved.name,
          reason: 'the atSign must still hold a fully privileged, permanent '
              'enrollment it can restore itself from');
    });

    test('...while the same command is allowed once another permanent root '
        'exists', () async {
      // The control for the refusal: identical command, spelling and caller,
      // differing only in that the act does not strand the atSign. Without it
      // the case above is satisfied by a revoke refused for any reason.
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
  /// comparing each link against the id being revoked. The links come out of
  /// the keystore folded, the id came off the wire, and an unfolded one
  /// matches no link. The walk then returns EMPTY, which is indistinguishable
  /// from an enrollment that admitted nobody, so the cascade reports success
  /// having swept nothing.
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

    test('...and still returns nothing for an enrollment that admitted nobody',
        () async {
      // The control separating "the walk found the subtree" from "the walk
      // returns everything": an empty answer must stay reachable.
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
      // Called directly: `put` and the cascade both hand
      // movePerEnrollmentDataFor ids that are already canonical, so its own
      // fold is reachable no other way. It matches folded keys out of the
      // keystore, so an unfolded id moves nothing and reports an empty list,
      // which reads exactly like an enrollment with no per-enrollment data.
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
      // The control: a fold that matched everything would satisfy the case
      // above while relocating other enrollments' data on every write.
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
      // The move matches the id segment of keys the KEYSTORE returned, so an
      // unfolded id moves nothing and the revoked enrollment's published
      // signing key stays where every reader looks for a live one.
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

  // ---- a caller's own reserved-namespace keys ----

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
      // The control: a fold that made everything its own would satisfy the
      // case above and hand every caller every other caller's signing key.
      expect(
          AbstractVerbHandler.isForeignPerEnrollmentReservedKey(
              '_apsk.${wsWrite}xyz.a.__e@alice', 'abc',
              isMutating: true),
          isTrue);
    });
  });

  /// Which whitespace `AtKey.getKeyType` accepts decides which non-canonical
  /// spellings reach a WRITE at all, and so which of the guards above are the
  /// only thing between a spelling and the record it resolves to. That is a
  /// fact about another package, pinned rather than assumed: if it changes,
  /// several cases above pass for a reason that has stopped being true.
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
  /// returned, so each is pinned twice. ⚠️ A RAW-LITERAL pin, because the
  /// string is an at-rest address: records on disk are reachable only by it
  /// and the `keys:` verb hands the encryption-key names to clients, so an
  /// intended change edits the literal in the same commit and that edit is
  /// the review. And an enumeration pin, which is what proves the literal is
  /// the address the store used rather than a second guess at it.
  group('a built key is the key the store holds', () {
    /// Everything the production write path stored under the PEK regex.
    Future<List<String>> storedPeks() async =>
        (await keyValueStore.getKeys(regex: EnrollmentConstants.regexForPEK))
            .toList();

    Future<List<String>> storedSeks() async =>
        (await keyValueStore.getKeys(regex: EnrollmentConstants.regexForSEK))
            .toList();

    /// An approved enrollment whose encryption keys the APPROVE path wrote.
    /// `primary` is CRAM auto-approved and never carries them, so using it
    /// would enumerate an empty set and every `contains` below be vacuous.
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
      // ⚠️ RAW-LITERAL, not composed from the constants the builder uses: a
      // comparison against the constants that define a value pins nothing.
      // FROZEN, because records on disk are addressable only by this form and
      // `keys:` hands these names to clients.
      const id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
      expect(enMgr.keyForPEK(id),
          'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.default_enc_private_key'
          '.__manage@alice');
      expect(enMgr.keyForSEK(id),
          'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.default_self_enc_key'
          '.__manage@alice');
    });

    test('a non-canonical id builds the same key for both', () async {
      // Idempotence of the fold, a different claim from the two above and no
      // substitute for either.
      final id = await approvedWithEncryptionKeys();
      for (final spelling in [
        ' $id',
        id.toUpperCase(),
        '$wsWrite$id',
        // Trailing, for the reason given in 'the enrollment key built from an
        // id is the key the store holds': folding only the composed string
        // strands trailing whitespace in the middle of the key.
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

    // ---- the legacy APKAM public key ----

    /// The one key builder whose components are CLIENT-CHOSEN: the app and
    /// device names arrive from the wire, so a capital in either builds a
    /// string the keystore does not hold the record under.
    ///
    /// A CAPITAL rather than a space, because `HiveAtKeyValueStore.put`
    /// lowercases the key and then runs `AtKey.getKeyType` on it before the
    /// canonical fold, so a spaced name is refused at the write and no record
    /// is reachable under one. Case is the only difference a STORED record
    /// can carry, and so the only half of the fold it can measure.
    ///
    /// Nothing on this server writes this key; the fixture writes it as a
    /// server that copied the enrolling app's APKAM public key here did, with
    /// the names exactly as the client sent them.
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
      // Deliberately NOT the pin: `keyStore.exists` and `keyStore.remove`
      // fold what they are handed, so the sweep reaches the record whether or
      // not the builder folded first. Removing the fold from keyForLegacyPK
      // reddens the case above and leaves this one green. It is the control
      // that the fixture is a real record the sweep reaches, so the equality
      // above is about the string rather than about an absent key.
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
