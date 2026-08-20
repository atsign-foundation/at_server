// Guards the isolation property `test_utils.dart`'s mock bundle is
// supposed to have: each `verbTestsSetUp()` call builds a *generation*
// of mocks, and nothing left over from an earlier generation may write
// into the current generation's socket listener.
//
// Why it matters (issue #2747): `PerAtSignNotifSender.send()` retries a
// failed delivery forever, so a notification raised by one test is still
// being retried while later tests run. Its `notify:id:<fresh-uuid>:…`
// command can never match a registered mock, so it always lands on the
// catch-all `write` stub — which answers by pushing an error line into a
// socket listener. If that listener is the *current* test's, the current
// test reads an error naming a request it never made.

import 'dart:convert';

import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  verbTestsSetUpLogging();

  setUpAll(() async {
    await verbTestsSetUpAll();
  });

  test(
      'a superseded generation of mocks cannot write into the current '
      'generation\'s socket listener', () async {
    await verbTestsSetUp();
    final staleConnection = mockOutboundConnection;
    final staleReads = <String>[];
    mockSecureSocket.listen((dynamic d) => staleReads.add(utf8.decode(d)),
        onDone: () {}, onError: (e, st) {});
    await verbTestsTearDown();

    await verbTestsSetUp();
    final currentReads = <String>[];
    mockSecureSocket.listen((dynamic d) => currentReads.add(utf8.decode(d)),
        onDone: () {}, onError: (e, st) {});

    // A notification left in flight from the earlier test, writing on
    // the outbound connection that test's notify pool holds.
    await staleConnection
        .write('notify:id:296926cc-0f59-48d3-822f-1bd5e6b571a4:update:'
            'messageType:key:notifier:SYSTEM:@bob:phone.wavi@alice\n');

    expect(currentReads, isEmpty,
        reason: 'a write on a superseded outbound connection reached the '
            'current generation\'s reader');

    // Positive control: the catch-all did fire, and answered on the
    // stale generation's own listener.
    expect(staleReads, hasLength(1));
    expect(staleReads.single, contains('No mock response defined'));
    expect(staleReads.single, contains('notify:id:'));

    await verbTestsTearDown();
  });
}
