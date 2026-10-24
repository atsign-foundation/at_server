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

    test('when no feed takes the notification, then it is sent at once', () {
      report.seal();

      expect(sent, [<LivePush>[]]);
    });

    test(
        'when a feed settles before every feed is counted, then it waits for the rest',
        () {
      report.settle(report.expect(), e1);
      expect(sent, isEmpty);
      final int second = report.expect();
      report.seal();
      expect(sent, isEmpty);

      report.settle(second, e2);

      expect(sent, [
        [e1, e2],
      ]);
    });
  });
}
