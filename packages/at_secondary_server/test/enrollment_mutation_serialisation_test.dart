import 'dart:async';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'enrollment_test_utils.dart';
import 'test_utils.dart';

/// Enrollment mutations are read-decide-write over a keystore with no
/// compare-and-set, and the decisions they rest on are questions about the
/// WHOLE store — "would any unexpiring root survive this act?" above all. Two
/// mutations in flight at once therefore each pass an individually correct
/// check and strand the atSign between them, and a per-record lock cannot see
/// it, because neither writer touches the other's record.
///
/// Every test here is a pair, and the control is what makes the pair an
/// instrument. Serialisation is the only thing that can make the concurrent
/// case behave like the serial one, so a concurrent assertion that held with
/// the section removed would be measuring nothing — and every control is drawn
/// from a property the section does not touch, so it stays green when the
/// section is gone.
///
/// The pairs come in two shapes, because the harm comes in two kinds.
///
/// RACED, where two acts genuinely compete and the harm is a state neither
/// order produces: the concurrent arrangement must leave the atSign with a
/// root it can restore itself from, and the control runs the same two acts one
/// after the other.
///
/// HELD, where the act under test is raced against the section itself: the
/// section is held, the act is started, and the store is read while it waits.
/// That is the same claim as a race with the timing taken out — whether a race
/// lands in the gap between one act's read and its write depends on how many
/// awaits each side happens to take, which is not a property of the code under
/// test. Its control is a LATENCY control: the identical act, with nothing
/// holding the section, must have written inside the same window. Without it a
/// hold assertion is equally satisfied by an act that never ran and by one
/// merely slower than the wait, so serialisation working and an inert probe
/// are indistinguishable.
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

  /// A connection of its OWN, authenticated as [enrollmentId].
  ///
  /// Never the shared `inboundConnection`: two concurrent commands would
  /// otherwise take turns overwriting one another's enrollment id on it, and
  /// the harness — not the server — would decide who each command ran as.
  DummyInboundConnection connectionFor(String enrollmentId) {
    final c = DummyInboundConnection();
    c.metadata
      ..isAuthenticated = true
      ..authType = AuthType.apkam
      ..sessionID = Uuid().v4()
      ..enrollmentId = enrollmentId;
    return c;
  }

  /// An approved, fully privileged, never-expiring enrollment written straight
  /// to the store, admitted by nobody.
  ///
  /// No approver, deliberately: an enrollment that descends from another is
  /// refused a revoke of its own ancestor by the descends-from rule, which
  /// would refuse one arm of the symmetric arrangement below for a reason
  /// that has nothing to do with concurrency.
  Future<String> addUnexpiringRoot(String id) async {
    final value = EnrollDataStoreValue(
        Uuid().v4(), 'app-$id', 'device-$id', 'apkam-public-key-$id')
      ..namespaces = {
        EnrollmentConstants.allNamespaces: 'rw',
        EnrollmentConstants.enrollManageNamespace: 'rw',
      }
      ..approval = EnrollApproval(EnrollmentStatus.approved.name);
    await enMgr.put(id, AtData()..data = jsonEncode(value.toJson()),
        EnrollmentStatus.approved);
    return id;
  }

  /// `enroll:revoke` of [targetId] over a connection authenticated as
  /// [revokerId]. Returns the refusal, or null if it went through.
  Future<Object?> revoke(String revokerId, String targetId) async {
    final p = EnrollParams()..enrollmentId = targetId;
    try {
      await etu.evh.processVerb(
        Response(),
        getVerbParam(
            VerbSyntax.enroll, 'enroll:revoke:${jsonEncode(p.toJson())}'),
        connectionFor(revokerId),
      );
      return null;
    } catch (e) {
      return e;
    }
  }

  /// A retrofit: [predecessorId] enrols a successor that REPLACES it.
  /// Returns the successor's id.
  Future<String> selfEnroll(
    String predecessorId, {
    String appName = 'rf-app',
    Duration? apkamKeysExpiryDuration,
    Map<String, dynamic>? apsk,
  }) async {
    final ep = EnrollParams()
      ..appName = appName
      ..deviceName = 'rf-device'
      ..apkamPublicKey = 'apkam public key $appName'
      ..apkamKeysExpiryDuration = apkamKeysExpiryDuration
      ..apsk = apsk;
    final r = Response();
    await etu.evh.processVerb(
      r,
      getVerbParam(
          VerbSyntax.enroll, 'enroll:request:${jsonEncode(ep.toJson())}'),
      connectionFor(predecessorId),
    );
    expect(r.isError, false, reason: '${r.errorMessage}');
    return jsonDecode(r.data!)['enrollmentId'] as String;
  }

  Future<DateTime?> expiryOf(String id) async =>
      (await keyValueStore.get(enMgr.buildEnrollmentKey(id)))
          ?.metaData
          ?.expiresAt;

  Future<String> stateOf(String id) async =>
      EnrollDataStoreValue.fromJson(jsonDecode(
              (await keyValueStore.get(enMgr.buildEnrollmentKey(id)))!.data!))
          .approval!
          .state;

  /// Two never-expiring roots, neither descended from the other. `primary` is
  /// the CRAM enrollment the harness creates; the second is written straight
  /// to the store.
  Future<String> twoRoots() async {
    final second = await addUnexpiringRoot('second-root');
    expect(await expiryOf(etu.primaryEnId), isNull);
    expect(await expiryOf(second), isNull);
    expect(await enMgr.hasUnexpiringRootEnrollment({}), isTrue,
        reason: 'precondition: the atSign has a root it can restore itself '
            'from');
    return second;
  }

  group('two enroll:revoke commands at once', () {
    test('cannot both count the root the other is about to remove', () async {
      final second = await twoRoots();

      // Each names the other. Run one after the other, the second is refused
      // because the first has already gone; run them together and each walk
      // finishes before either write, so each sees the other still approved
      // and unexpiring, each concludes the atSign is safe, and the atSign is
      // left with no root at all.
      final outcomes = await Future.wait([
        revoke(etu.primaryEnId, second),
        revoke(second, etu.primaryEnId),
      ]);

      expect(await enMgr.hasUnexpiringRootEnrollment({}), isTrue,
          reason: 'an unexpiring root must survive two concurrent revokes: '
              'the liveness question is about the whole store, so two '
              'individually correct answers are still wrong together');
      expect(outcomes.where((e) => e == null).length, 1,
          reason: 'exactly one of the two acts happens; the other is refused '
              'on the state the first left');
    });

    test('SERIAL CONTROL: the second is refused on what the first left',
        () async {
      final second = await twoRoots();

      final first = await revoke(etu.primaryEnId, second);
      final andThen = await revoke(second, etu.primaryEnId);

      expect(first, isNull, reason: 'the first revoke leaves a root standing '
          'and is allowed');
      expect(andThen, isNotNull,
          reason: 'the second would take the last one and is refused — this '
              'is the refusal the concurrent case has to reproduce, and it '
              'needs no serialisation to work, so it stays green when the '
              'critical section is removed');
      expect(await enMgr.hasUnexpiringRootEnrollment({}), isTrue);
    });
  });

  group('a retrofit cap arming while an enroll:revoke runs', () {
    /// A short-lived successor of `primary`, plus a second root so that
    /// capping `primary` is permitted at the moment it is decided.
    ///
    /// SHORT-LIVED is load-bearing: an unexpiring successor is itself a root,
    /// so capping its predecessor would strand nothing and the interleaving
    /// would not matter.
    Future<(String, String)> capArrangement() async {
      final second = await twoRoots();
      final successor = await selfEnroll(etu.primaryEnId,
          apkamKeysExpiryDuration: Duration(minutes: 1));
      expect(await expiryOf(successor), isNotNull,
          reason: 'precondition: the successor is NOT itself a permanent root');
      return (second, successor);
    }

    test('cannot cap one root while the other is being revoked', () async {
      final (second, successor) = await capArrangement();

      // The arming asks whether an unexpiring root survives capping `primary`
      // and finds the second; the revoke asks whether one survives removing
      // the second and finds `primary`, still uncapped. Both are right about
      // the store they read and wrong about the store they leave.
      await Future.wait([
        enMgr.armRetrofitCapOnFirstAuth(successor),
        revoke(etu.primaryEnId, second),
      ]);

      expect(await enMgr.hasUnexpiringRootEnrollment({}), isTrue,
          reason: 'a cap arming and a revoke are mutations of two DIFFERENT '
              'records, so nothing scoped to one record can stop them '
              'stranding the atSign between them');
    });

    test('SERIAL CONTROL: arming first, the revoke is then refused', () async {
      final (second, successor) = await capArrangement();

      await enMgr.armRetrofitCapOnFirstAuth(successor);
      expect(await expiryOf(etu.primaryEnId), isNotNull,
          reason: 'precondition: the cap really did arm');
      final refusal = await revoke(etu.primaryEnId, second);

      expect(refusal, isNotNull,
          reason: 'the revoke now sees a capped predecessor and refuses to '
              'take the last permanent root — no serialisation needed, so '
              'this stays green when the critical section is removed');
      expect(await enMgr.hasUnexpiringRootEnrollment({}), isTrue);
    });

    test('SERIAL CONTROL: revoking first, the cap then declines', () async {
      final (second, successor) = await capArrangement();

      expect(await revoke(etu.primaryEnId, second), isNull,
          reason: 'precondition: the revoke is allowed while primary stands');
      await enMgr.armRetrofitCapOnFirstAuth(successor);

      expect(await expiryOf(etu.primaryEnId), isNull,
          reason: 'the arming now finds no other permanent root and spares '
              'the predecessor — no serialisation needed, so this stays '
              'green when the critical section is removed');
      expect(await enMgr.hasUnexpiringRootEnrollment({}), isTrue);
    });
  });

  group('a revoke and a cap arming writing the same record', () {
    /// A successor of `primary` that published an `_apsk`, plus a second root
    /// so the arming gets as far as writing its stamp onto that successor.
    Future<(String, String)> lostUpdateArrangement() async {
      final second = await twoRoots();
      final successor = await selfEnroll(etu.primaryEnId,
          apkamKeysExpiryDuration: Duration(minutes: 1),
          apsk: {'signingPublicKey': 'k', 'signingAlgo': 'mldsa65'});
      expect(
          await keyValueStore.exists('public:_apsk.$successor'
              '.${EnrollmentConstants.perEnrollmentApproved}${enMgr.atSign}'),
          isTrue,
          reason: 'precondition: the successor published a signing key at the '
              'live address');
      return (second, successor);
    }

    test('the store cannot end up disagreeing with the answer given',
        () async {
      final (_, successor) = await lostUpdateArrangement();

      // Both write a WHOLE-RECORD snapshot of the successor: the revoke flips
      // its state, the arming stamps `predecessorCapArmedAt` on it. Whichever
      // wrote second reinstated everything the other had changed — the verb
      // answering `revoked` over a record the store held `approved`, with the
      // credential's published `_apsk` back at the live address.
      final outcomes = await Future.wait([
        revoke(etu.primaryEnId, successor),
        enMgr.armRetrofitCapOnFirstAuth(successor).then((_) => null),
      ]);
      expect(outcomes.first, isNull,
          reason: 'precondition: the revoke was allowed and answered revoked');

      expect(await stateOf(successor), EnrollmentStatus.revoked.name,
          reason: 'the store must hold what the verb answered; a lost update '
              'here republishes a revoked credential');
      expect(
          await keyValueStore.exists('public:_apsk.$successor'
              '.${EnrollmentConstants.perEnrollmentApproved}${enMgr.atSign}'),
          isFalse,
          reason: 'and the revoked credential\'s signing key must not be back '
              'at the live address');
      expect(
          await keyValueStore.exists('public:_apsk.$successor'
              '.${EnrollmentConstants.perEnrollmentRevoked}${enMgr.atSign}'),
          isTrue,
          reason: 'it belongs at the parked address');
    });

    test('SERIAL CONTROL: revoking then arming leaves the record revoked',
        () async {
      final (_, successor) = await lostUpdateArrangement();

      expect(await revoke(etu.primaryEnId, successor), isNull);
      await enMgr.armRetrofitCapOnFirstAuth(successor);

      expect(await stateOf(successor), EnrollmentStatus.revoked.name,
          reason: 'the arming reads the record it is about to write, so run '
              'after the revoke it carries the revoked state forward — no '
              'serialisation needed, so this stays green when the critical '
              'section is removed');
      expect(
          await keyValueStore.exists('public:_apsk.$successor'
              '.${EnrollmentConstants.perEnrollmentApproved}${enMgr.atSign}'),
          isFalse);
    });
  });

  group('adopting a capped approver\'s children', () {
    /// A predecessor P that admitted three children, a short-lived successor S
    /// of P, and a second root so that capping P is permitted. Arming S caps P
    /// and re-parents every child onto S. Returns P, one child, and S.
    Future<(String, String, String)> adoptionArrangement() async {
      await twoRoots();
      final predecessor = await etu.createPendingEnrollment(
          appName: 'approver',
          deviceName: 'device',
          namespaces: {
            EnrollmentConstants.allNamespaces: 'rw',
            EnrollmentConstants.enrollManageNamespace: 'rw',
          },
          apkamKeysExpiryDuration: null);
      await etu.approveEnrollment(etu.primaryEnId, predecessor);

      String? child;
      for (var i = 0; i < 3; i++) {
        child = await etu.createPendingEnrollment(
            appName: 'child$i',
            deviceName: 'device',
            namespaces: {'wavi': 'rw'},
            apkamKeysExpiryDuration: null);
        await etu.approveEnrollment(predecessor, child);
      }
      expect(await enMgr.descendantsOf(predecessor), contains(child),
          reason: 'precondition: the child really does hang off the '
              'predecessor');

      final successor = await selfEnroll(predecessor,
          appName: 'approver', apkamKeysExpiryDuration: Duration(minutes: 1));
      return (predecessor, child!, successor);
    }

    Future<String?> approverOf(String id) async =>
        EnrollDataStoreValue.fromJson(jsonDecode(
                (await keyValueStore.get(enMgr.buildEnrollmentKey(id)))!.data!))
            .approvedByEnrollmentId;

    test('the stamp, the cap and the adoption are all inside the section',
        () async {
      // Observed by HOLDING the section rather than by racing something
      // against it: whether a race lands in the gap between the adoption's
      // read of a child and its write of that child depends on how many
      // awaits each side happens to take, which is not a property of the
      // code under test. Holding the section and looking is the same claim
      // with the timing taken out — measured against a hold of 100ms, which
      // is three orders of magnitude more than the reads the arming makes
      // before it queues.
      //
      // The adoption is the half that matters most. Its lost update is
      // PERMANENT and silent: nothing ever re-parents again, so a child left
      // naming a predecessor on its way out is outside every later revocation
      // cascade for the rest of its life, with no error raised and no retry.
      final (predecessor, child, successor) = await adoptionArrangement();

      final gate = Completer<void>();
      final holder = enMgr.serialiseMutation(() => gate.future);
      final arming = enMgr.armRetrofitCapOnFirstAuth(successor);
      await Future<void>.delayed(Duration(milliseconds: 100));

      final armedDuringHold =
          (await enMgr.getEnrollmentById(successor)).predecessorCapArmedAt;
      final cappedDuringHold = await expiryOf(predecessor);
      final approverDuringHold = await approverOf(child);

      gate.complete();
      await Future.wait([holder, arming]);

      expect(approverDuringHold, predecessor,
          reason: 'the re-parent must not happen while another mutation holds '
              'the section: it is a read-modify-write of a whole child '
              'record, and the write that overtakes it is never repeated');
      expect(armedDuringHold, isNull,
          reason: 'nor the stamp on the successor');
      expect(cappedDuringHold, isNull,
          reason: 'nor the cap on the predecessor');

      expect(await approverOf(child), successor,
          reason: 'and all three land once the section is free — otherwise '
              'this would be measuring an arming that simply never ran');
      expect(
          (await enMgr.getEnrollmentById(successor)).predecessorCapArmedAt,
          isNotNull);
      expect(await expiryOf(predecessor), isNotNull);
    });

    test('SERIAL CONTROL: revoking then arming leaves both writes standing',
        () async {
      final (predecessor, child, successor) = await adoptionArrangement();

      expect(await revoke(etu.primaryEnId, child), isNull);
      await enMgr.armRetrofitCapOnFirstAuth(successor);

      expect(await expiryOf(predecessor), isNotNull);
      expect(await approverOf(child), successor,
          reason: 'the adoption reads each child immediately before writing '
              'it, so run after the revoke it re-parents the revoked child '
              'rather than skipping it — no serialisation needed, so this '
              'stays green when the critical section is removed');
      expect(await stateOf(child), EnrollmentStatus.revoked.name,
          reason: 'and carries the revoked state forward rather than writing '
              'an older snapshot back over it');
    });
  });

  group('the critical section itself', () {
    test('is re-entrant, so a mutation reached from inside another one runs',
        () async {
      // `Mutex.protect` is not re-entrant — a nested `protect` never
      // completes — so without this a mutation reached from inside another
      // one would hang the connection that started it rather than answer
      // wrongly. Zone values are what tell "already inside" from "another
      // caller waiting".
      final order = <String>[];
      await enMgr.serialiseMutation(() async {
        order.add('outer');
        await Future<void>.delayed(Duration(milliseconds: 1));
        await enMgr.serialiseMutation(() async => order.add('nested'));
        order.add('outer done');
      }).timeout(Duration(seconds: 5),
          onTimeout: () => fail('a nested mutation deadlocked'));

      expect(order, ['outer', 'nested', 'outer done']);
    });

    test('runs genuinely concurrent mutations one at a time', () async {
      final order = <String>[];
      await Future.wait([
        enMgr.serialiseMutation(() async {
          order.add('A in');
          await Future<void>.delayed(Duration(milliseconds: 20));
          order.add('A out');
        }),
        enMgr.serialiseMutation(() async {
          order.add('B in');
          await Future<void>.delayed(Duration(milliseconds: 1));
          order.add('B out');
        }),
      ]);

      expect(order, ['A in', 'A out', 'B in', 'B out'],
          reason: 'B must not start until A has finished, however much '
              'shorter B is');
    });

    test('is released by a REFUSED verb, not just a successful one', () async {
      // Every refusal on these paths is a throw out of the middle of the
      // critical section, and a lock left held by one would wedge every later
      // enrollment mutation on the atSign — a worse failure than the race the
      // section exists to stop, and one no other test would notice.
      final second = await twoRoots();
      expect(await revoke(etu.primaryEnId, second), isNull);
      expect(await revoke(second, etu.primaryEnId), isNotNull,
          reason: 'precondition: the second revoke really is refused, so a '
              'throw really did leave the section');

      var reachedTheSection = false;
      await enMgr.serialiseMutation(() async {
        reachedTheSection = true;
      }).timeout(Duration(seconds: 5),
          onTimeout: () => fail('the section was left held by a refused verb'));
      expect(reachedTheSection, isTrue);
    });

    test('an authentication with nothing to arm never takes the lock',
        () async {
      // The early exits in armRetrofitCapOnFirstAuth are outside the section
      // deliberately: it runs on EVERY APKAM authentication and everything
      // except a retrofit's successor leaves at the first three tests.
      // Reaching them through the lock put every authentication behind
      // whatever mutation was in flight.
      final plain = await addUnexpiringRoot('replaced-nothing');

      final held = enMgr.serialiseMutation(() async {
        await Future<void>.delayed(Duration(milliseconds: 300));
      });
      final sw = Stopwatch()..start();
      await enMgr.armRetrofitCapOnFirstAuth(plain);
      sw.stop();
      await held;

      expect(sw.elapsedMilliseconds, lessThan(200),
          reason: 'an enrollment that replaced nothing has nothing to arm, so '
              'it must answer while a mutation is in flight rather than queue '
              'behind it');
    });
  });

  // =====================================================================
  // The four sections a race cannot reach, held and looked at.
  // =====================================================================

  /// How long a HELD case waits before reading the store, and how long its
  /// latency control gives the same act to finish unobstructed.
  ///
  /// Three orders of magnitude more than the handful of keystore reads each of
  /// these acts makes before it reaches its critical section — which is what
  /// the latency control measures rather than assumes.
  const Duration holdWindow = Duration(milliseconds: 100);

  /// Takes the atSign's enrollment-mutation section and holds it until the
  /// returned completer is completed.
  ///
  /// The returned future is the holder: complete the gate and await it, or the
  /// section is still held when the test ends and every later mutation queues
  /// behind a completer nobody owns any more.
  (Completer<void>, Future<void>) holdTheSection() {
    final gate = Completer<void>();
    return (gate, enMgr.serialiseMutation(() => gate.future));
  }

  Future<int> enrollmentCount() async =>
      (await enMgr.getAllEnrollmentKeys()).length;

  group('enroll:request', () {
    test('mints no enrollment while another mutation holds the section',
        () async {
      // The sharpest of the four. A retrofit reads its predecessor, checks it
      // is approved, reads its stored deadline and mints a successor carrying
      // its grants verbatim — so a revoke of that predecessor landing
      // mid-decision is answered by a fresh, approved credential holding
      // exactly what the revoke was taking away. The successor is a PEER
      // rather than a child, so no later cascade reaches it through the
      // predecessor either.
      final before = await enrollmentCount();

      final (gate, holder) = holdTheSection();
      final request = selfEnroll(etu.primaryEnId);
      await Future<void>.delayed(holdWindow);
      final duringHold = await enrollmentCount();

      gate.complete();
      final successor = await request;
      await holder;

      expect(duringHold, before,
          reason: 'the whole read-decide-write is one mutation: nothing may '
              'be minted while another enrollment mutation is in flight, '
              'because the decision the mint rests on is a question about the '
              'store that mutation is changing');
      expect(await enrollmentCount(), before + 1,
          reason: 'and it lands once the section is free — otherwise this '
              'would be measuring a request that simply never ran');
      expect(await stateOf(successor), EnrollmentStatus.approved.name);
    });

    test('LATENCY CONTROL: unobstructed, the same request mints inside the '
        'same window', () async {
      // Identical act, identical window, nothing holding the section. Without
      // it the case above is equally satisfied by a request that threw, or by
      // one that simply takes longer than the wait — neither of which is
      // serialisation, and both of which look exactly like it.
      final before = await enrollmentCount();

      final request = selfEnroll(etu.primaryEnId);
      await Future<void>.delayed(holdWindow);
      final duringWindow = await enrollmentCount();
      await request;

      expect(duringWindow, before + 1,
          reason: 'the window is ample for the act, so "nothing minted" above '
              'is a statement about the lock rather than about latency — and '
              'this needs no serialisation, so it stays green when the '
              'critical section is removed');
    });

    test('SERIAL CONTROL: a revoke landing FIRST refuses the retrofit',
        () async {
      // The serial outcome the hazard is stated against: run one after the
      // other and the request is refused on the state the revoke left. That
      // refusal is what the section exists to keep reachable, and it needs no
      // serialisation of its own, so it stays green when the section is gone.
      final second = await twoRoots();
      expect(await revoke(second, etu.primaryEnId), isNull,
          reason: 'precondition: the revoke is allowed, since the other root '
              'survives it');
      expect(await stateOf(etu.primaryEnId), EnrollmentStatus.revoked.name,
          reason: 'precondition: the predecessor really is revoked');

      Object? refusal;
      try {
        await selfEnroll(etu.primaryEnId);
      } catch (e) {
        refusal = e;
      }
      expect(refusal, isA<UnAuthorizedException>(),
          reason: 'a revoked predecessor may not hand its grants to a fresh, '
              'approved credential');
    });
  });

  group('enroll:update', () {
    /// `enroll:update` is SELF-ONLY, so the connection has to be
    /// authenticated as its target. Metadata rather than a key rotation: the
    /// subject is the section, and a rotation would add a signature
    /// verification deciding the outcome for another reason entirely.
    Future<void> updateMetadata(String enId, Map<String, dynamic> md) async {
      final p = EnrollParams()
        ..enrollmentId = enId
        ..metadata = md;
      final r = Response();
      await etu.evh.processVerb(
        r,
        getVerbParam(
            VerbSyntax.enroll, 'enroll:update:${jsonEncode(p.toJson())}'),
        connectionFor(enId),
      );
      expect(r.isError, false, reason: '${r.errorMessage}');
    }

    Future<Map<String, dynamic>?> metadataOf(String id) async =>
        EnrollDataStoreValue.fromJson(jsonDecode(
                (await keyValueStore.get(enMgr.buildEnrollmentKey(id)))!.data!))
            .metadata;

    test('writes nothing while another mutation holds the section', () async {
      // The record is read at the top, an APKAM signature verification is
      // awaited in the middle, and the WHOLE record is written back at the
      // bottom — so anything another mutation wrote to it in between is
      // reinstated by a snapshot taken before that write. The re-read just
      // before the write refuses on a changed STATUS and on nothing else;
      // every other field is carried forward from the stale snapshot.
      final target = await addUnexpiringRoot('update-target');
      expect(await metadataOf(target), isNull,
          reason: 'precondition: nothing has written metadata yet');

      final (gate, holder) = holdTheSection();
      final update = updateMetadata(target, {'keyPackage': 'kp-1'});
      await Future<void>.delayed(holdWindow);
      final duringHold = await metadataOf(target);

      gate.complete();
      await update;
      await holder;

      expect(duringHold, isNull,
          reason: 'the read-decide-write must not start while another '
              'mutation is changing the record it is about to snapshot');
      expect(await metadataOf(target), {'keyPackage': 'kp-1'},
          reason: 'and it lands once the section is free — otherwise this '
              'would be measuring an update that simply never ran');
    });

    test('LATENCY CONTROL: unobstructed, the same update writes inside the '
        'same window', () async {
      final target = await addUnexpiringRoot('update-target');

      final update = updateMetadata(target, {'keyPackage': 'kp-1'});
      await Future<void>.delayed(holdWindow);
      final duringWindow = await metadataOf(target);
      await update;

      expect(duringWindow, {'keyPackage': 'kp-1'},
          reason: 'the window is ample for the act, so "nothing written" '
              'above is a statement about the lock rather than about latency '
              '— and this needs no serialisation, so it stays green when the '
              'critical section is removed');
    });
  });

  group('enroll:delete', () {
    /// A revoked enrollment — one of the two states `enroll:delete` accepts.
    Future<String> deletable() async {
      final victim = await addUnexpiringRoot('delete-target');
      expect(await revoke(etu.primaryEnId, victim), isNull,
          reason: 'precondition: the revoke is allowed while primary stands');
      return victim;
    }

    Future<void> deleteEnrollment(String callerId, String targetId) async {
      final p = EnrollParams()..enrollmentId = targetId;
      final r = Response();
      await etu.evh.processVerb(
        r,
        getVerbParam(
            VerbSyntax.enroll, 'enroll:delete:${jsonEncode(p.toJson())}'),
        connectionFor(callerId),
      );
      expect(r.isError, false, reason: '${r.errorMessage}');
    }

    test('removes nothing while another mutation holds the section', () async {
      // Delete is the one act that is IRREVERSIBLE, and its write takes other
      // records with it: the per-enrollment data goes through the pre-remove
      // hook, and for the housekeeping record the legacy PKAM key goes too. It
      // also severs an approval link, which puts everything behind that link
      // permanently out of reach of a later cascade — so a delete that decided
      // against a store another mutation was rewriting cannot be repaired
      // afterwards.
      final victim = await deletable();
      final key = enMgr.buildEnrollmentKey(victim);

      final (gate, holder) = holdTheSection();
      final delete = deleteEnrollment(etu.primaryEnId, victim);
      await Future<void>.delayed(holdWindow);
      final existedDuringHold = await keyValueStore.exists(key);

      gate.complete();
      await delete;
      await holder;

      expect(existedDuringHold, isTrue,
          reason: 'the record is read, the caller\'s authority and the '
              'record\'s state are decided against it, and only then is it '
              'removed — the whole of that is one mutation');
      expect(await keyValueStore.exists(key), isFalse,
          reason: 'and it lands once the section is free — otherwise this '
              'would be measuring a delete that simply never ran');
    });

    test('LATENCY CONTROL: unobstructed, the same delete removes inside the '
        'same window', () async {
      final victim = await deletable();
      final key = enMgr.buildEnrollmentKey(victim);

      final delete = deleteEnrollment(etu.primaryEnId, victim);
      await Future<void>.delayed(holdWindow);
      final existedDuringWindow = await keyValueStore.exists(key);
      await delete;

      expect(existedDuringWindow, isFalse,
          reason: 'the window is ample for the act, so "still there" above is '
              'a statement about the lock rather than about latency — and '
              'this needs no serialisation, so it stays green when the '
              'critical section is removed');
    });
  });

  group('minting the legacy identity', () {
    /// The one state the housekeeping enrollment is minted in: a keystore
    /// holding a usable `at_pkam_publickey` and NO enrollment record at all.
    ///
    /// The roster is emptied through [EnrollmentManager.remove] rather than
    /// through the keystore directly, so the manager's cache goes with it — a
    /// stale entry would make the re-read inside the section answer from
    /// before the empty.
    Future<void> emptyRosterWithLegacyKey() async {
      for (final ek in await enMgr.getAllEnrollmentKeys()) {
        await enMgr.remove(enId: enMgr.getIdFromKey(ek));
      }
      expect(await enrollmentCount(), 0,
          reason: 'precondition: the store holds no enrollment, which is the '
              'only state the identity is minted in');
      await keyValueStore.put(AtConstants.atPkamPublicKey,
          AtData()..data = 'the-legacy-pkam-key',
          skipCommit: true);
    }

    String hKey() =>
        enMgr.buildEnrollmentKey(EnrollmentManager.housekeepingEnrollmentId);

    test('mints nothing while another mutation holds the section', () async {
      // Only the CREATE is serialised — the already-created case is answered
      // outside it, because that is the case every legacy authentication
      // takes. The create re-asks BOTH of its questions inside the section,
      // and another mutation can be changing the answer to either:
      // `enroll:delete` of this record removes the legacy key in the same
      // breath, so a decision taken outside would re-create the identity that
      // delete had just retired, and an enrollment landing meanwhile is what
      // turns a bootstrap into a key that arrived some other way.
      await emptyRosterWithLegacyKey();

      final (gate, holder) = holdTheSection();
      final minting = enMgr.ensureHousekeepingEnrollment();
      await Future<void>.delayed(holdWindow);
      final existedDuringHold = await keyValueStore.exists(hKey());

      gate.complete();
      final minted = await minting;
      await holder;

      expect(existedDuringHold, isFalse,
          reason: 'the create re-reads the record, the legacy key and the '
              'whole roster and then writes an unexpiring, fully privileged '
              'root with no approver — it must not decide that against a '
              'store another mutation is in the middle of changing');
      expect(minted, isNotNull);
      expect(await keyValueStore.exists(hKey()), isTrue,
          reason: 'and it lands once the section is free — otherwise this '
              'would be measuring a mint that simply never ran');
    });

    test('LATENCY CONTROL: unobstructed, the same mint writes inside the same '
        'window', () async {
      await emptyRosterWithLegacyKey();

      final minting = enMgr.ensureHousekeepingEnrollment();
      await Future<void>.delayed(holdWindow);
      final existedDuringWindow = await keyValueStore.exists(hKey());
      await minting;

      expect(existedDuringWindow, isTrue,
          reason: 'the window is ample for the act, so "nothing minted" above '
              'is a statement about the lock rather than about latency — and '
              'this needs no serialisation, so it stays green when the '
              'critical section is removed');
    });

    test('the ALREADY-CREATED case answers while the section is held',
        () async {
      // The other half of the same decision, deliberately OUTSIDE the
      // section: this is the case every legacy authentication takes, so
      // putting it behind the lock would queue authentication behind whatever
      // enrollment mutation happened to be in flight.
      await emptyRosterWithLegacyKey();
      expect(await enMgr.ensureHousekeepingEnrollment(), isNotNull,
          reason: 'precondition: the record now exists');

      final (gate, holder) = holdTheSection();
      final sw = Stopwatch()..start();
      final again = await enMgr.ensureHousekeepingEnrollment();
      sw.stop();
      gate.complete();
      await holder;

      expect(again, isNotNull);
      expect(sw.elapsedMilliseconds, lessThan(holdWindow.inMilliseconds),
          reason: 'an atSign that already holds the record must answer while '
              'a mutation is in flight rather than queue behind it');
    });
  });
}
