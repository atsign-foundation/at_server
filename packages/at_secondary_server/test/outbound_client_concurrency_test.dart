import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// Covers concurrent use of a pooled [OutboundClient].
///
/// A pooled client is shared: every caller wanting the same remote atServer
/// under the same pool key is handed the same object, and therefore the same
/// socket. The tests below drive two callers at once and assert on what each
/// one gets back.
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
}
