import 'dart:async';

import 'package:at_secondary/src/notification/monitor_sink.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:test/test.dart';

void main() {
  const LivePush e1 = (enrollmentId: 'e1', authType: AuthType.apkam);
  const LivePush e2 = (enrollmentId: 'e2', authType: AuthType.apkam);

  group('Given a report on a received notification', () {
    late List<List<LivePush>> sent;
    late LivePushReport report;

    setUp(() {
      sent = <List<LivePush>>[];
      report = LivePushReport(sent.add, timeout: const Duration(seconds: 10));
    });

    tearDown(() => report.seal());

    test(
        'when no feed takes the notification, then it is sent just after the call that sealed it',
        () async {
      report.seal();
      expect(sent, isEmpty, reason: 'not inside the call that sealed it');
      await pumpEventQueue();

      expect(sent, [<LivePush>[]]);
    });

    test(
        'when a feed settles before every feed is counted, then it waits for the rest',
        () async {
      report.settle(report.expect(), e1);
      final int second = report.expect();
      report.seal();
      await pumpEventQueue();
      expect(sent, isEmpty);

      report.settle(second, e2);
      expect(sent, isEmpty, reason: 'not inside the call that settled it');
      await pumpEventQueue();

      expect(sent, [
        [e1, e2],
      ]);
    });

    test(
        'when a feed fails after it was counted, then abandoning its slot sends the report once every feed is counted',
        () async {
      final int first = report.counted;
      report.expect();

      report.abandon(first);
      await pumpEventQueue();
      expect(sent, isEmpty);
      report.seal();
      await pumpEventQueue();

      expect(sent, [<LivePush>[]]);
    });

    test(
        'when a slot counted in the failed push was already settled, then abandoning leaves it as it was',
        () async {
      final int first = report.counted;
      report.settle(report.expect(), e1);
      report.expect();

      report.abandon(first);
      report.seal();
      await pumpEventQueue();

      expect(sent, [
        [e1],
      ]);
    });

    test(
        'when sending it fails, then the failure is logged and goes no further',
        () async {
      final List<Object> escaped = <Object>[];
      late LivePushReport failing;
      runZonedGuarded(() {
        failing = LivePushReport((List<LivePush> _) => throw StateError('x'),
            timeout: const Duration(seconds: 10));
      }, (Object e, StackTrace _) => escaped.add(e));

      failing.seal();
      await pumpEventQueue();

      expect(escaped, isEmpty);
      expect(failing.done, completes);
    });
  });
}
