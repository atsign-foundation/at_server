import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/gate/gatekeeper.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// The mark a notification from a quarantined atSign is stored with.
void main() {
  final Atsign bob = '@bob'.toAtsign();
  final Atsign chuck = '@chuck'.toAtsign();

  late NotifyVerbHandler handler;
  Gatekeeper gate() => AtSecondaryServerImpl.getInstance().gatekeeper;

  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await verbTestsSetUp();
    handler = NotifyVerbHandler(keyValueStore, notificationManager);
    await gate().setDefault(GateDefault.closed);
    await gate().setRule('invitations.chat', GateMode.open);
    await gate().admit('invitations.chat', bob);
  });

  tearDown(() async => await verbTestsTearDown());

  Future<AtNotification> delivered(Atsign from, String id) async {
    inboundConnection.metadata
      ..isAuthenticated = false
      ..isPolAuthenticated = true
      ..fromAtSign = from;
    await handler.processInternal(
        'notify:id:$id:@alice:$id.invitations.chat$from', inboundConnection);
    return (await notificationManager.get(id))!;
  }

  group('Given an open namespace admitting @bob', () {
    test(
        "when a quarantined atSign's notification is accepted, then it is"
        ' stored marked', () async {
      expect((await delivered(chuck, 'q1')).quarantined, isTrue);
    });

    test(
        "when an admitted atSign's notification follows it, then that one is"
        ' stored unmarked', () async {
      await delivered(chuck, 'q1');
      expect((await delivered(bob, 'a1')).quarantined, isFalse);
    });

    test(
        'when the quarantined sender is admitted afterwards, then the stored'
        ' mark is unchanged', () async {
      await delivered(chuck, 'q1');
      await gate().admit('invitations.chat', chuck);
      expect((await notificationManager.get('q1'))!.quarantined, isTrue);
    });
  });
}
