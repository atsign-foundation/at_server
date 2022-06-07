import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';

class MockAtCommitLog extends Mock implements AtCommitLog {}

class MockInboundConnection extends Mock implements InboundConnection {}

void main() {
  AtCommitLog mockAtCommitLog = MockAtCommitLog();
  InboundConnection mockInboundConnection1 = MockInboundConnection();
  InboundConnection mockInboundConnection2 = MockInboundConnection();

  test(
      'stats notification service test - stats written only to monitor connection',
      () async {
    bool inboundConn1Written = false;
    bool inboundConn2Written = false;
    StatsNotificationService statsNotificationService =
        StatsNotificationService.getInstance();
    statsNotificationService.atCommitLog = mockAtCommitLog;
    statsNotificationService.connectionsList = [
      mockInboundConnection1,
      mockInboundConnection2
    ];

    when(() => mockAtCommitLog.lastCommittedSequenceNumber())
        .thenAnswer((_) => 4);

    when(() => mockInboundConnection1.write(
        any(that: startsWith('notification:')))).thenAnswer((invocation) {
      print('ok');
      inboundConn1Written = true;
    });

    when(() => mockInboundConnection2
            .write(any(that: startsWith('notification:'))))
        .thenAnswer((Invocation invocation) {
      print('not ok');
    });

    when(() => mockInboundConnection1.isMonitor).thenAnswer((_) => true);
    when(() => mockInboundConnection2.isMonitor).thenAnswer((_) => false);

    await statsNotificationService.schedule('@alice');
    await Future.delayed(Duration(
        seconds: AtSecondaryConfig.statsNotificationJobTimeInterval + 1));
    expect(inboundConn1Written, true);
    expect(inboundConn2Written, false);
  });
}
