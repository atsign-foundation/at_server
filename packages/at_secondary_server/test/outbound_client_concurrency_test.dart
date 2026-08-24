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

  group('concurrent OutboundClientManager.getClient for one pool key', () {
    /// Long enough that two of these running together and two running one
    /// after the other are far apart in wall clock, so the assertion below
    /// has room either side of its threshold on a loaded machine.
    const connectDelay = Duration(milliseconds: 150);

    /// Delays address resolution so that both callers are inside
    /// [OutboundClient.connect] at once — the window between finding no
    /// client in the pool and adding a newly created one to it.
    void slowDownConnecting() {
      when(() => mockSecondaryAddressFinder.findSecondary(bob))
          .thenAnswer((_) async {
        await Future.delayed(connectDelay);
        return at_lookup.SecondaryAddress(bobHost, bobPort);
      });
    }

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
        await Future.delayed(connectDelay);
        return at_lookup.SecondaryAddress(bobHost, bobPort);
      });
      when(() => mockOutboundConnectionFactory.createOutboundConnection(
          bobHost, bobPort, alice)).thenAnswer((_) async {
        return mockOutboundConnection;
      });

      final manager = OutboundClientManager(
          mockSecondaryAddressFinder, mockOutboundConnectionFactory,
          poolSize: 5);

      final stopwatch = Stopwatch()..start();
      await Future.wait([
        manager.getClient(bob, DummyInboundConnection(),
            handshakeRequired: false),
        manager.getClient(alice, DummyInboundConnection(),
            handshakeRequired: false),
      ]);
      stopwatch.stop();

      expect(manager.getActiveConnectionSize(), 2);
      // Two resolutions run together take about one [connectDelay];
      // serialised they take two. Measured on the fixed build: ~170ms
      // together, ~320ms when getClient takes one lock for the whole
      // manager rather than one per pool key.
      expect(stopwatch.elapsedMilliseconds, lessThan(250),
          reason: 'connecting to one atSign must not hold up connecting to'
              ' another');
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
