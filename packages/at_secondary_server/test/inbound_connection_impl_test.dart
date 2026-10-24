import 'dart:async';
import 'dart:io';

import 'package:at_commons/at_commons.dart'
    show AtIOException, ConnectionInvalidException;
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() async {
  late FakeSocket mockSocket;

  verbTestsSetUpLogging();

  setUp(() async {
    mockSocket = FakeSocket();
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

  group('Given a connection whose socket takes writes', () {
    test('when it is written to, then its last access time moves on', () async {
      final InboundConnectionImpl connection =
          InboundConnectionImpl(_FailingSocket(), 'writing');
      final DateTime before =
          DateTime.timestamp().subtract(const Duration(seconds: 1));
      connection.metaData.lastAccessed = before;

      await connection.write('data:first\n@');

      expect(connection.metaData.lastAccessed!.isAfter(before), isTrue);
    });

    test('when it has closed, then a write is refused as invalid', () async {
      final InboundConnectionImpl connection =
          InboundConnectionImpl(_FailingSocket(), 'closed');
      connection.metaData.isClosed = true;

      await expectLater(connection.write('data:first\n@'),
          throwsA(isA<ConnectionInvalidException>()));
    });
  });

  group('Given a connection whose socket refuses to be written through', () {
    test('when it is written to, then it is marked stale and the write fails',
        () async {
      final InboundConnectionImpl connection =
          InboundConnectionImpl(FakeSocket(), 'unbindable');

      await expectLater(
          connection.write('data:first\n@'), throwsA(isA<AtIOException>()));
      expect(connection.metaData.isStale, isTrue);
    });
  });

  group('Given a connection whose client has stopped reading', () {
    test('when it is written to, then the bytes waiting are counted as UTF-8',
        () async {
      final AtSecondaryContext? prior =
          AtSecondaryServerImpl.getInstance().serverContext;
      AtSecondaryServerImpl.getInstance().serverContext = AtSecondaryContext()
        ..inboundMaxUnsentBytes = 10;
      addTearDown(
          () => AtSecondaryServerImpl.getInstance().serverContext = prior);
      final InboundConnectionImpl connection =
          InboundConnectionImpl(_FailingSocket(reading: false), 'stalled');

      await connection.write('\u00e9\u00e9\u00e9\u00e9');
      await Future<void>.delayed(Duration.zero);
      expect(connection.unsentBytes, 8, reason: 'four two-byte characters');

      await expectLater(connection.write('\u00e9\u00e9'),
          throwsA(isA<ConnectionInvalidException>()));
      expect(connection.metaData.isClosed, isTrue);
    });
  });

  group('Given an open connection', () {
    test('when it is marked not closed, then its closed future stays pending',
        () async {
      final InboundConnectionMetadata metaData = InboundConnectionMetadata();
      bool closed = false;
      unawaited(metaData.closed.then((_) => closed = true));

      metaData.isClosed = false;
      await Future<void>.delayed(Duration.zero);

      expect(closed, isFalse);
    });
  });

  group('Given a connection whose socket stops taking writes', () {
    test('when it is written to again, then the write is refused', () async {
      final _FailingSocket socket = _FailingSocket();
      final InboundConnectionImpl connection =
          InboundConnectionImpl(socket, 'failing');
      await connection.write('data:first\n@');

      socket.fail();
      await Future<void>.delayed(Duration.zero);

      expect(connection.isInValid(), isTrue);
      await expectLater(connection.write('data:second\n@'),
          throwsA(isA<ConnectionInvalidException>()));
    });
  });
}

/// A socket that takes writes until [fail] is called, or, when
/// [reading] is false, takes none at all.
class _FailingSocket extends FakeSocket {
  _FailingSocket({this.reading = true});

  final bool reading;
  final Completer<void> _transport = Completer<void>();

  void fail() => _transport.completeError(const SocketException('reset'));

  @override
  Future addStream(Stream<List<int>> stream) {
    final StreamSubscription<List<int>> subscription = stream.listen((_) {});
    if (!reading) {
      subscription.pause();
    }
    return _transport.future;
  }
}
