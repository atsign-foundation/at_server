import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/gate/gatekeeper.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// The gate matches a key's namespace whatever case another atServer names
/// it in, as the keystore does.
void main() {
  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await verbTestsSetUp();
    await AtSecondaryServerImpl.getInstance()
        .gatekeeper
        .setRule('chat', GateMode.closed, admit: '@bob'.toAtsign());
    await keyValueStore.put('@chuck:status.chat$alice', AtData()..data = 'v');
    inboundConnection.metadata
      ..isAuthenticated = false
      ..isPolAuthenticated = true
      ..fromAtSign = '@chuck'.toAtsign();
  });

  tearDown(() async => await verbTestsTearDown());

  group('Given a closed namespace under the ungated default', () {
    for (final String command in [
      'lookup:Status.CHAT@alice',
      'notify:id:1:@alice:msg.Chat@chuck',
    ]) {
      test(
          'when another atServer names a key in it in another case, then it is'
          ' not accepted: $command', () async {
        final handler = command.startsWith('notify:')
            ? NotifyVerbHandler(keyValueStore, notificationManager)
            : LookupVerbHandler(
                keyValueStore, mockOutboundClientManager, cacheManager, enMgr,
                accessLog: atAccessLog);
        Exception? refused;
        try {
          await handler.processInternal(command, inboundConnection);
        } on Exception catch (e) {
          refused = e;
        }
        expect(refused, isNotNull, reason: '"$command" was accepted');
        expect(GlobalExceptionHandler.getInstance().getErrorCode(refused!),
            'AT0033');
      });
    }
  });
}
