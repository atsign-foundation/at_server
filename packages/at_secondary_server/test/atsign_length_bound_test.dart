import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/verb/executor/default_verb_executor.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

late DefaultVerbHandlerManager verbs;
late OutboundClientManager outbound;

/// Sends [command] on [connection] as the atServer does: the executor picks
/// the handler, and GlobalExceptionHandler answers whatever it throws.
Future<void> send(String command, FakeInboundConnection connection) async {
  try {
    await DefaultVerbExecutor().execute(command, connection, verbs);
  } on Exception catch (e) {
    await GlobalExceptionHandler.getInstance()
        .handle(e, atConnection: connection);
  }
}

/// A connection that has sent nothing yet.
FakeInboundConnection unauthenticated() =>
    FakeInboundConnection(FakeSocket(), InboundConnectionMetadata());

void main() {
  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await verbTestsSetUp();
    outbound = OutboundClientManager(
        mockSecondaryAddressFinder, mockOutboundConnectionFactory);
    when(() => mockSecondaryAddressFinder.findSecondary(any())).thenAnswer(
        (invocation) async => throw SecondaryNotFoundException(
            'no entry for ${invocation.positionalArguments.single}'));
    verbs = DefaultVerbHandlerManager(
      keyValueStore,
      outbound,
      cacheManager,
      statsNotificationService,
      notificationManager,
      enMgr,
      alice,
      commitLog: atCommitLog,
      accessLog: atAccessLog,
    );
  });
  tearDown(() async => await verbTestsTearDown());

  test('An atSign with a reserved character is refused with AT0003', () async {
    final connection = unauthenticated();
    await send('from:@a!b', connection);
    expect(connection.writes, [
      "error:AT0003-Exception: invalid @sign: Cannot contain !*'`();:&=+\$,/?#[]{} characters\n@"
    ]);
    expect(connection.closeCount, 1);
  });
}
