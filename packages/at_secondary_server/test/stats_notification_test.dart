import 'dart:collection';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_pool.dart';
import 'package:at_secondary/src/notification/stats_notification_service.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';

class MockAtCommitLog extends Mock implements AtCommitLog {}

class MockInboundConnection extends Mock implements InboundConnection {}

InboundConnection mockInboundConnection1 = MockInboundConnection();
InboundConnection mockInboundConnection2 = MockInboundConnection();

class MockInboundConnectionPool extends Mock implements InboundConnectionPool {
  @override
  UnmodifiableListView<InboundConnection> getConnections() {
    return UnmodifiableListView<InboundConnection>(
        [mockInboundConnection1, mockInboundConnection2]);
  }
}

void main() {
  AtCommitLog mockAtCommitLog = MockAtCommitLog();
  InboundConnectionPool mockInboundConnectionPool = MockInboundConnectionPool();

  test(
      'stats notification service test - stats written only to monitor connection',
      () async {
    bool inboundConn1Written = false;
    bool inboundConn2Written = false;
    StatsNotificationService statsNotificationService =
        StatsNotificationService.getInstance();

    expect(statsNotificationService.state,
        StatsNotificationServiceState.notScheduled);

    statsNotificationService.atCommitLog = mockAtCommitLog;
    statsNotificationService.inboundConnectionPool = mockInboundConnectionPool;

    when(() => mockAtCommitLog.lastCommittedSequenceNumber())
        .thenAnswer((_) => 4);

    when(() => mockInboundConnection1.write(
        any(that: startsWith('notification:')))).thenAnswer((invocation) {
      inboundConn1Written = true;
    });

    when(() => mockInboundConnection2
            .write(any(that: startsWith('notification:'))))
        .thenAnswer((Invocation invocation) {
      inboundConn2Written = true;
    });

    when(() => mockInboundConnection1.isMonitor).thenAnswer((_) => true);
    when(() => mockInboundConnection2.isMonitor).thenAnswer((_) => false);

    var statsNotificationJobTimeInterval = Duration(milliseconds: 50);
    await statsNotificationService.schedule('@alice',
        interval: statsNotificationJobTimeInterval);
    expect(statsNotificationService.state,
        StatsNotificationServiceState.scheduled);

    await Future.delayed(
        statsNotificationJobTimeInterval + Duration(milliseconds: 10));

    statsNotificationService.cancel();
    expect(statsNotificationService.state,
        StatsNotificationServiceState.notScheduled);

    expect(inboundConn1Written, true);
    expect(inboundConn2Written, false);
  });
}
