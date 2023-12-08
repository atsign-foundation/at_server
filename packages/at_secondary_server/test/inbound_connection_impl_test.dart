import 'dart:io';

import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';

void main(){
  group('A test to verify the rate limiter on inbound connection', () {
    test('A test to verify requests exceeding the limit are rejected', () {
      Socket? dummySocket;
      AtConnection connection1 = InboundConnectionImpl(dummySocket, 'aaa');
      (connection1 as InboundConnectionImpl).maxRequestsPerTimeFrame = 1;
      connection1.timeFrameInMillis =
          Duration(milliseconds: 10).inMilliseconds;
      expect(connection1.isRequestAllowed(), true);
      expect(connection1.isRequestAllowed(), false);
    });

    test('A test to verify requests after the time window are accepted',
            () async {
          Socket? dummySocket;
          AtConnection connection1 = InboundConnectionImpl(dummySocket, 'aaa');
          (connection1 as InboundConnectionImpl).maxRequestsPerTimeFrame = 1;
          connection1.timeFrameInMillis = Duration(milliseconds: 2).inMilliseconds;
          expect(connection1.isRequestAllowed(), true);
          expect(connection1.isRequestAllowed(), false);
          await Future.delayed(Duration(milliseconds: 2));
          expect(connection1.isRequestAllowed(), true);
        });

    test('A test to verify request from different connection is allowed', () {
      Socket? dummySocket;
      AtConnection connection1 = InboundConnectionImpl(dummySocket, 'aaa');
      AtConnection connection2 = InboundConnectionImpl(dummySocket, 'aaa');
      (connection1 as InboundConnectionImpl).maxRequestsPerTimeFrame = 1;
      (connection2 as InboundConnectionImpl).maxRequestsPerTimeFrame = 1;
      connection1.timeFrameInMillis =
          Duration(milliseconds: 10).inMilliseconds;
      expect(connection1.isRequestAllowed(), true);
      expect(connection1.isRequestAllowed(), false);
      expect(connection2.isRequestAllowed(), true);
    });
  });
}