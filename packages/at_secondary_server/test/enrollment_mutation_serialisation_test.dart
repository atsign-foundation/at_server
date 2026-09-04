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

/// Pins that enrollment mutations run one at a time: each is a
/// read-decide-write over a keystore with no compare-and-set, and the
/// decisions rest on questions about the WHOLE store.
///
/// Every test is a pair: RACED runs two competing acts together, HELD holds
/// the section and reads the store while the act waits.
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

  /// A connection of its OWN, authenticated as [enrollmentId], never the
  /// shared `inboundConnection`.
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

  /// Two never-expiring roots, neither descended from the other.
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

  group('a revoke and a cap arming writing the same record', () {
    /// A successor of `primary` that published an `_apsk`.
    Future<String> lostUpdateArrangement() async {
      final successor = await selfEnroll(etu.primaryEnId,
          apkamKeysExpiryDuration: Duration(minutes: 1),
          apsk: {'signingPublicKey': 'k', 'signingAlgo': 'mldsa65'});
      expect(
          await keyValueStore.exists('public:_apsk.$successor'
              '.${EnrollmentConstants.perEnrollmentApproved}${enMgr.atSign}'),
          isTrue,
          reason: 'precondition: the successor published a signing key at the '
              'live address');
      return successor;
    }

    // NOTE this arm stays green with the critical section removed: nothing in
    // a test can park the arming between its read and its write, so what it
    // pins is the outcome, not the serialisation.
    test('run together, the store holds the revoke the verb answered',
        () async {
      final successor = await lostUpdateArrangement();

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
      final successor = await lostUpdateArrangement();

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
    /// A predecessor P that admitted three children, and a short-lived
    /// successor S of P. Returns P, one child, and S.
    Future<(String, String, String)> adoptionArrangement() async {
      final predecessor = await etu.createPendingEnrollment(
          appName: 'approver',
          deviceName: 'device',
          namespaces: {
            EnrollmentConstants.enrollManageNamespace: 'rw',
            'wavi': 'rw',
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
            .parentEnrollmentId;

    test('the stamp, the cap and the adoption are all inside the section',
        () async {
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
      // NOTE `Mutex.protect` is not re-entrant: a nested `protect` never
      // completes.
      // inside" from "another caller waiting".
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

    test('the cap arming takes no section when there is nothing to arm',
        () async {
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


  /// How long a HELD case waits before reading the store, and how long its
  /// latency control gives the same act unobstructed.
  const Duration holdWindow = Duration(milliseconds: 100);

  /// Takes the atSign's enrollment-mutation section and holds it until the
  /// returned completer completes. Complete the gate and await the returned
  /// future, or the section is still held when the test ends.
  (Completer<void>, Future<void>) holdTheSection() {
    final gate = Completer<void>();
    return (gate, enMgr.serialiseMutation(() => gate.future));
  }

  /// The STORED roster's size.
  Future<int> enrollmentCount() async =>
      (await enMgr.getAllEnrollmentKeys(includeExpired: true)).length;

  group('enroll:request', () {
    test('mints no enrollment while another mutation holds the section',
        () async {
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
      // The latency control: identical act and window, nothing holding the
      // section.
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
      // The serial control: run in order, the request is refused.
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
    /// authenticated as its target.
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
    /// A revoked enrollment, one of the two states `enroll:delete` accepts.
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
}
