import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  final handler = GlobalExceptionHandler.getInstance();
  final tooLong = InvalidAtSignException(
      'invalid @sign: must have at most 55 characters after the @');

  setUp(() {
    verbTestsSetUpLogging();
    AtSecondaryServerImpl.getInstance().currentAtSign = alice;
  });

  group('Given an atSign at_commons refuses', () {
    test(
        'when the connection has not authenticated, '
        'then it is answered AT0003 and closed', () async {
      final connection =
          FakeInboundConnection(FakeSocket(), InboundConnectionMetadata());
      await handler.handle(tooLong, atConnection: connection);
      expect(connection.writes, [
        'error:AT0003-Exception: invalid @sign: must have at most 55'
            ' characters after the @\n@'
      ]);
      expect(connection.closeCount, 1);
    });

    test(
        'when the connection is an authenticated client, '
        'then it is answered AT0003 and stays open', () async {
      final connection = FakeInboundConnection(
          FakeSocket(),
          InboundConnectionMetadata()
            ..isAuthenticated = true
            ..authType = AuthType.cram);
      await handler.handle(tooLong, atConnection: connection);
      expect(connection.writes, [
        'error:AT0003-Invalid syntax : invalid @sign: must have at most 55'
            ' characters after the @\n@alice@'
      ]);
      expect(connection.closeCount, 0);
    });

    test(
        'when the connection is a peer that has proved itself by pol, '
        'then it is answered AT0003 and stays open', () async {
      final connection = FakeInboundConnection(
          FakeSocket(),
          InboundConnectionMetadata()
            ..isPolAuthenticated = true
            ..fromAtSign = bob);
      await handler.handle(tooLong, atConnection: connection);
      expect(connection.writes, [
        'error:AT0003-Exception: invalid @sign: must have at most 55'
            ' characters after the @\n@'
      ]);
      expect(connection.closeCount, 0);
    });

    test('when a batch looks up its error code, then the code is AT0003', () {
      expect(handler.getErrorCode(tooLong), 'AT0003');
    });
  });
}
