import 'package:at_commons/at_commons.dart';
import 'package:at_lookup/at_lookup.dart' as at_lookup;
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// Covers concurrent use of a pooled [OutboundClient] and of
/// [OutboundClientManager.getClient].
///
/// A pooled client is shared: every caller wanting the same remote atServer
/// under the same pool key is handed the same object, and therefore the same
/// socket. Both groups below drive two callers at once and assert on what
/// each one gets back.
void main() {
  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  setUp(() async {
    await verbTestsSetUp();
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  group('concurrent requests on one pooled OutboundClient', () {
    test(
        'two lookups in flight together each receive the response to their own'
        ' request, even when the peer answers them out of order', () async {
      // The peer answers the second request long before the first. A caller
      // that takes whatever arrives first is answered with the other
      // caller's record: well-formed, but not what it asked for.
      final events = <String>[];

      when(() => mockOutboundConnection.write('lookup:all:slow$bob\n'))
          .thenAnswer((_) async {
        events.add('wrote slow');
        Future.delayed(Duration(milliseconds: 150), () {
          events.add('peer answered slow');
          socketOnDataFn('data:SLOW_RECORD\n$alice@'.codeUnits);
        });
      });
      when(() => mockOutboundConnection.write('lookup:all:fast$bob\n'))
          .thenAnswer((_) async {
        events.add('wrote fast');
        Future.delayed(Duration(milliseconds: 10), () {
          events.add('peer answered fast');
          socketOnDataFn('data:FAST_RECORD\n$alice@'.codeUnits);
        });
      });

      await outboundClientWithoutHandshake.connect();
      // The harness sets a 100ms budget, which the deliberately slow peer
      // response here exceeds. The read budget is not what is under test.
      outboundClientWithoutHandshake.lookupTimeoutMillis = 5000;

      final slow = outboundClientWithoutHandshake.lookUp('all:slow$bob',
          handshake: false);
      final fast = outboundClientWithoutHandshake.lookUp('all:fast$bob',
          handshake: false);

      expect(await slow, 'data:SLOW_RECORD',
          reason: 'the caller that asked for the slow record must receive the'
              ' slow record, not whichever response arrived first');
      expect(await fast, 'data:FAST_RECORD',
          reason: 'the caller that asked for the fast record must receive the'
              ' fast record');

      // Asserting the values alone would also pass if the two exchanges
      // happened to be written together and the responses happened to be
      // paired up correctly. Pin the mechanism: the second request is not
      // written until the first exchange has completed.
      expect(
          events,
          [
            'wrote slow',
            'peer answered slow',
            'wrote fast',
            'peer answered fast'
          ],
          reason: 'each request/response pair must complete on the shared'
              ' socket before the next request is written to it');
    });

    test(
        'a lookup and a notify in flight together do not take each'
        ' other\'s response', () async {
      when(() => mockOutboundConnection.write('lookup:all:key$bob\n'))
          .thenAnswer((_) async {
        Future.delayed(Duration(milliseconds: 150),
            () => socketOnDataFn('data:LOOKUP_RESULT\n$alice@'.codeUnits));
      });
      when(() => mockOutboundConnection.write('notify:the-notification\n'))
          .thenAnswer((_) async {
        Future.delayed(Duration(milliseconds: 10),
            () => socketOnDataFn('data:NOTIFY_RESULT\n$alice@'.codeUnits));
      });

      await outboundClientWithoutHandshake.connect();
      outboundClientWithoutHandshake.lookupTimeoutMillis = 5000;
      outboundClientWithoutHandshake.notifyTimeoutMillis = 5000;

      final lookup = outboundClientWithoutHandshake.lookUp('all:key$bob',
          handshake: false);
      final notify = outboundClientWithoutHandshake
          .notify('the-notification', handshake: false);

      expect(await lookup, 'data:LOOKUP_RESULT',
          reason: 'the serialisation must hold across different verbs on the'
              ' shared socket, not just between two lookups');
      expect(await notify, 'data:NOTIFY_RESULT');
    });
  });

  group('queue depth on one pooled client', () {
    test('counts the exchanges waiting, and returns to zero', () async {
      when(() => mockOutboundConnection.write('lookup:all:slow$bob\n'))
          .thenAnswer((_) async {
        Future.delayed(Duration(milliseconds: 150),
            () => socketOnDataFn('data:SLOW\n$alice@'.codeUnits));
      });
      when(() => mockOutboundConnection.write('lookup:all:fast$bob\n'))
          .thenAnswer((_) async {
        Future.delayed(Duration(milliseconds: 10),
            () => socketOnDataFn('data:FAST\n$alice@'.codeUnits));
      });

      await outboundClientWithoutHandshake.connect();
      outboundClientWithoutHandshake.lookupTimeoutMillis = 5000;
      expect(outboundClientWithoutHandshake.queuedRequests, 0);

      final slow = outboundClientWithoutHandshake.lookUp('all:slow$bob',
          handshake: false);
      final fast = outboundClientWithoutHandshake.lookUp('all:fast$bob',
          handshake: false);

      expect(outboundClientWithoutHandshake.queuedRequests, 2,
          reason: 'both exchanges are on this client -- one holding the socket'
              ' and one waiting for it');

      await slow;
      await fast;
      expect(outboundClientWithoutHandshake.queuedRequests, 0,
          reason: 'the count must come back down, or it reports a queue that'
              ' has long since drained');
    });
  });

  group('concurrent OutboundClientManager.getClient for one pool key', () {
    /// Wide enough that a caller reaching address resolution while another
    /// is still inside it will do so within the window. Nothing asserts on
    /// elapsed time, so the value only has to exceed scheduling jitter.
    const connectDelay = Duration(milliseconds: 50);

    /// Records entry to and exit from address resolution, so a test can say
    /// whether two callers were inside [OutboundClient.connect] together
    /// rather than inferring it from how long they took.
    final resolutionEvents = <String>[];

    /// Delays address resolution so that both callers are inside
    /// [OutboundClient.connect] at once — the window between finding no
    /// client in the pool and adding a newly created one to it.
    void slowDownConnecting() {
      when(() => mockSecondaryAddressFinder.findSecondary(bob))
          .thenAnswer((_) async {
        resolutionEvents.add('enter $bob');
        await Future.delayed(connectDelay);
        resolutionEvents.add('exit $bob');
        return at_lookup.SecondaryAddress(bobHost, bobPort);
      });
    }

    setUp(resolutionEvents.clear);

    test('two callers that both miss share one client rather than each'
        ' creating one', () async {
      slowDownConnecting();
      final manager = OutboundClientManager(
          mockSecondaryAddressFinder, mockOutboundConnectionFactory,
          poolSize: 5);

      // Two distinct dummies: the pool matches any dummy against any other,
      // so these are one pool key.
      final results = await Future.wait([
        manager.getClient(bob, DummyInboundConnection(),
            handshakeRequired: false),
        manager.getClient(bob, DummyInboundConnection(),
            handshakeRequired: false),
      ]);

      expect(identical(results[0], results[1]), isTrue,
          reason: 'both callers asked for the same pool key, so both must be'
              ' handed the same client');
      expect(manager.getActiveConnectionSize(), 1,
          reason: 'a second client for one pool key is a connection the pool'
              ' holds but no caller asked for');
    });

    test('callers for different atSigns are not held up by each other',
        () async {
      slowDownConnecting();
      when(() => mockSecondaryAddressFinder.findSecondary(alice))
          .thenAnswer((_) async {
        resolutionEvents.add('enter $alice');
        await Future.delayed(connectDelay);
        resolutionEvents.add('exit $alice');
        return at_lookup.SecondaryAddress(bobHost, bobPort);
      });
      when(() => mockOutboundConnectionFactory.createOutboundConnection(
          bobHost, bobPort, alice)).thenAnswer((_) async {
        return mockOutboundConnection;
      });

      final manager = OutboundClientManager(
          mockSecondaryAddressFinder, mockOutboundConnectionFactory,
          poolSize: 5);

      await Future.wait([
        manager.getClient(bob, DummyInboundConnection(),
            handshakeRequired: false),
        manager.getClient(alice, DummyInboundConnection(),
            handshakeRequired: false),
      ]);

      expect(manager.getActiveConnectionSize(), 2);
      // Assert the overlap itself rather than how long the pair took: both
      // callers must be inside address resolution before either leaves it.
      // A lock covering the whole manager would produce
      // [enter, exit, enter, exit] instead.
      expect(resolutionEvents.take(2), containsAll(['enter $bob', 'enter $alice']),
          reason: 'connecting to one atSign must not hold up connecting to'
              ' another: both callers should be inside connect() together');
    });

    test('poolSize is enforced when two callers for different atSigns miss'
        ' together', () async {
      slowDownConnecting();
      when(() => mockSecondaryAddressFinder.findSecondary(alice))
          .thenAnswer((_) async {
        resolutionEvents.add('enter $alice');
        await Future.delayed(connectDelay);
        resolutionEvents.add('exit $alice');
        return at_lookup.SecondaryAddress(bobHost, bobPort);
      });
      when(() => mockOutboundConnectionFactory.createOutboundConnection(
          bobHost, bobPort, alice)).thenAnswer((_) async {
        return mockOutboundConnection;
      });

      // Room for exactly one. The two callers hold different per-key locks,
      // so nothing but the reservation stops them both creating.
      final manager = OutboundClientManager(
          mockSecondaryAddressFinder, mockOutboundConnectionFactory,
          poolSize: 1);

      final outcomes = await Future.wait([
        manager
            .getClient(bob, DummyInboundConnection(), handshakeRequired: false)
            .then<Object>((c) => c)
            .onError<Exception>((e, _) => e),
        manager
            .getClient(alice, DummyInboundConnection(),
                handshakeRequired: false)
            .then<Object>((c) => c)
            .onError<Exception>((e, _) => e),
      ]);

      expect(outcomes.whereType<OutboundClient>().length, 1,
          reason: 'poolSize is 1, so exactly one caller may be given a client');
      expect(outcomes.whereType<OutboundConnectionLimitException>().length, 1,
          reason: 'the other must be refused rather than quietly taking the'
              ' pool over its declared maximum');
      expect(manager.getActiveConnectionSize(), 1);
    });

    test('a connect that fails gives its reserved slot back', () async {
      when(() => mockSecondaryAddressFinder.findSecondary(bob))
          .thenThrow(SecondaryNotFoundException('no secondary for $bob'));
      when(() => mockSecondaryAddressFinder.findSecondary(alice))
          .thenAnswer((_) async => at_lookup.SecondaryAddress(bobHost, bobPort));
      when(() => mockOutboundConnectionFactory.createOutboundConnection(
          bobHost, bobPort, alice)).thenAnswer((_) async {
        return mockOutboundConnection;
      });

      final manager = OutboundClientManager(
          mockSecondaryAddressFinder, mockOutboundConnectionFactory,
          poolSize: 1);

      await expectLater(
          manager.getClient(bob, DummyInboundConnection(),
              handshakeRequired: false),
          throwsA(isA<Exception>()));

      // The only slot must be free again.
      final client = await manager.getClient(alice, DummyInboundConnection(),
          handshakeRequired: false);
      expect(client.toAtSign, alice,
          reason: 'a reservation whose connect threw must be released, or the'
              ' pool is permanently one slot smaller for the process lifetime');
    });

    test('the per-key lock table does not retain entries', () async {
      final manager = OutboundClientManager(
          mockSecondaryAddressFinder, mockOutboundConnectionFactory,
          poolSize: 5);
      await manager.getClient(bob, DummyInboundConnection(),
          handshakeRequired: false);
      expect(manager.pendingGetClientLocks, 0);
    });
  });
}
