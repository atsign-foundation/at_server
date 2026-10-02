import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/notify_all_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:crypton/crypton.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  late NotifyAllVerbHandler handler;

  setUp(() async {
    await verbTestsSetUp();
    handler = NotifyAllVerbHandler(keyValueStore, notificationManager);
    inboundConnection.metadata.isAuthenticated = true;
    inboundConnection.metadata.authType = AuthType.cram;
    AtSecondaryServerImpl.getInstance().signingKey =
        RSAKeypair.fromRandom().privateKey.toString();
  });
  tearDown(() async => await verbTestsTearDown());

  /// Runs [command] and returns the reply map of recipient to id.
  Future<Map<String, dynamic>> notifyAll(String command) async {
    final response = Response();
    final HashMap<String, String?> params =
        getVerbParam(VerbSyntax.notifyAll, command);
    await handler.processVerb(response, params, inboundConnection);
    return jsonDecode(response.data!) as Map<String, dynamic>;
  }

  /// Every notification the atServer has stored.
  Future<List<AtNotification>> stored() => notifStore.iterate().toList();

  test('a recipient is stored as an atSign', () async {
    await notifyAll('notify:all:bob:phone.wavi$alice');
    final n = (await stored()).single;
    expect(n.toAtSign, bob, reason: 'a bare token names the same atSign');
    expect(n.notification, '$bob:phone.wavi$alice');
  });

  test('an atSign named twice is notified once', () async {
    await notifyAll('notify:all:bob,$bob:phone.wavi$alice');
    expect(await stored(), hasLength(1),
        reason: 'bob and @bob are one recipient');
  });

  test('the reply is keyed by the normalised atSign', () async {
    final reply = await notifyAll('notify:all:bob,$bob:phone.wavi$alice');
    expect(reply.keys, [bob]);
    expect(reply[bob], (await stored()).single.id);
  });

  test('an empty recipient list answers {} and stores nothing', () async {
    expect(await notifyAll('notify:all::phone.wavi$alice'), isEmpty);
    expect(await stored(), isEmpty);
  });

  test('an empty recipient token is dropped', () async {
    expect((await notifyAll('notify:all:,bob:phone.wavi$alice')).keys, [bob]);
  });

  test('the atServer\'s own atSign is notified as the notify verb does it',
      () async {
    await notifyAll('notify:all:$alice:phone.wavi$alice');
    final n = (await stored()).single;
    expect(n.type, NotificationType.received);
    expect(n.notificationStatus, NotificationStatus.delivered);
  });

  test('a text notify:all is sent by the atServer\'s own atSign', () async {
    await notifyAll('notify:all:messageType:text:$bob:hello');
    final n = (await stored()).single;
    expect(n.fromAtSign, alice);
  });

  test('a key another atSign owns is refused before anything is stored',
      () async {
    await expectLater(
        notifyAll('notify:all:$bob:phone.wavi@carol'),
        throwsA(isA<UnAuthorizedException>().having((e) => e.message, 'message',
            '@carol is not authorized to send notification as $alice')),
        reason: 'the notify verb refuses this, with this message');
    expect(await stored(), isEmpty);
  });

  test('notificationDateTime is UTC', () async {
    await notifyAll('notify:all:$bob:phone.wavi$alice');
    expect((await stored()).single.notificationDateTime!.isUtc, isTrue,
        reason: 'the notify verb stores UTC, and a reader elsewhere must not '
            'read a local time as its own');
  });
}
