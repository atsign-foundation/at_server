import 'dart:async';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
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
/// Every test here is a pair: the concurrent arrangement, which must leave the
/// atSign with a root it can restore itself from, and the SERIAL control that
/// runs the same two acts one after the other. The control is what makes the
/// pair an instrument. Serialisation is the only thing that can make the
/// concurrent case behave like the serial one, so a concurrent assertion that
/// held with the section removed would be measuring nothing — and the control
/// is drawn from a property the section does not touch, so it stays green when
/// the section is gone.
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
}
