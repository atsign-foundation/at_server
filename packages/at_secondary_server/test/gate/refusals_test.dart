import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/gate/gatekeeper.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// The scenarios of docs/projects/gatekeeper/features/refusals.feature that
/// one atServer's answer proves, each under its scenario's title.
void main() {
  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await verbTestsSetUp();
    await AtSecondaryServerImpl.getInstance()
        .gatekeeper
        .setDefault(GateDefault.closed);
  });

  tearDown(() async => await verbTestsTearDown());

  test('A gate refusal leaves the connection open', () async {
    final _ClosingConnection connection = _ClosingConnection();
    connection.metadata
      ..isPolAuthenticated = true
      ..fromAtSign = '@chuck'.toAtsign();
    await AtSecondaryServerImpl.getInstance()
        .gatekeeper
        .setRule('chat', GateMode.closed);
    Exception? refused;
    try {
      await NotifyVerbHandler(keyValueStore, notificationManager)
          .processInternal('notify:id:13:@alice:msg.chat@chuck', connection);
    } on Exception catch (e) {
      refused = e;
    }
    await GlobalExceptionHandler.getInstance()
        .handle(refused!, atConnection: connection);
    expect(connection.lastWrittenData, startsWith('error:AT0033-'));
    expect(connection.closed, isFalse);
  });
}

/// A connection that records whether it was closed.
class _ClosingConnection extends DummyInboundConnection {
  bool closed = false;

  @override
  Future<void> close() async => closed = true;
}
