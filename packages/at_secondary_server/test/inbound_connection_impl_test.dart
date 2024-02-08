import 'dart:io';

import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  late MockSocket mockSocket;

  setUp(() async {
    mockSocket = MockSocket();
    when(() => mockSocket.setOption(SocketOption.tcpNoDelay, true))
        .thenReturn(true);
  });

  group('A test to verify the rate limiter on inbound connection', () {
    test('A test to verify requests exceeding the limit are rejected', () {
      AtConnection connection1 = InboundConnectionImpl(mockSocket, 'aaa');
      (connection1 as InboundConnectionImpl).maxRequestsPerTimeFrame = 1;
      connection1.timeFrameInMillis = Duration(milliseconds: 10).inMilliseconds;
      expect(connection1.isRequestAllowed(), true);
      expect(connection1.isRequestAllowed(), false);
    });

    test('A test to verify requests after the time window are accepted',
        () async {
      AtConnection connection1 = InboundConnectionImpl(mockSocket, 'aaa');
      (connection1 as InboundConnectionImpl).maxRequestsPerTimeFrame = 1;
      connection1.timeFrameInMillis = Duration(milliseconds: 2).inMilliseconds;
      expect(connection1.isRequestAllowed(), true);
      expect(connection1.isRequestAllowed(), false);
      await Future.delayed(Duration(milliseconds: 2));
      expect(connection1.isRequestAllowed(), true);
    });

    test('A test to verify request from different connection is allowed', () {
      AtConnection connection1 = InboundConnectionImpl(mockSocket, 'aaa');
      AtConnection connection2 = InboundConnectionImpl(mockSocket, 'aaa');
      (connection1 as InboundConnectionImpl).maxRequestsPerTimeFrame = 1;
      (connection2 as InboundConnectionImpl).maxRequestsPerTimeFrame = 1;
      connection1.timeFrameInMillis = Duration(milliseconds: 10).inMilliseconds;
      expect(connection1.isRequestAllowed(), true);
      expect(connection1.isRequestAllowed(), false);
      expect(connection2.isRequestAllowed(), true);
    });
  });
}
