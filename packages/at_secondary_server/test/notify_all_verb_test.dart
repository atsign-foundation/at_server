import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/notify_all_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
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

  test('a key naming no sender is sent by the atServer\'s own atSign',
      () async {
    await notifyAll('notify:all:$bob:phone.wavi');
    expect((await stored()).single.notification, '$bob:phone.wavi$alice',
        reason: 'the notify verb sends a key that names no sender as its own');
  });

  group('notify:all judges each recipient as notify does', () {
    // FROZEN: enrollments and keys whose decisions turn on the recipient,
    // the key's shape or the enrollment's access.
    const enrollments = <String, Map<String, String>?>{
      'cram': null,
      'chat.myapp:r': {'chat.myapp': 'r'},
      'chat.myapp:rw': {'chat.myapp': 'rw'},
      '*:rw': {'*': 'rw'},
    };
    const recipientsAndKeys = [
      ('@bob', 'msg.chat.myapp'),
      ('@bob', 'x.other'),
      ('@bob', 'shared_key'),
      ('@bob', 'shared_key.bob'),
      ('@alice', 'signing_privatekey'),
    ];

    /// Whether [verbHandler] lets the connection run [command].
    Future<bool> allows(dynamic verbHandler, String command) async {
      try {
        await verbHandler.processInternal(command, inboundConnection);
        return true;
      } on UnAuthorizedException {
        return false;
      }
    }

    for (final MapEntry(key: name, value: namespaces) in enrollments.entries) {
      test('for $name', () async {
        if (namespaces != null) {
          inboundConnection.metadata
            ..authType = AuthType.apkam
            ..enrollmentId = await createAndPersistAnEnrollment(
                'myapp', 'pixel', namespaces);
        }
        final notify = NotifyVerbHandler(keyValueStore, notificationManager);
        final decisions = <bool>{};
        for (final (recipient, key) in recipientsAndKeys) {
          final byNotify =
              await allows(notify, 'notify:$recipient:$key$alice:v');
          decisions.add(byNotify);
          expect(await allows(handler, 'notify:all:$recipient:$key$alice:v'),
              byNotify,
              reason: '$recipient:$key$alice for $name');
        }
        if (name == 'chat.myapp:rw' || name == '*:rw') {
          expect(decisions, {true, false},
              reason: 'control: this enrollment is allowed some keys and '
                  'refused others');
        }
      });
    }

    test('refuses every recipient when one is refused', () async {
      handler = _RefusesColin(keyValueStore, notificationManager);
      await expectLater(
          notifyAll('notify:all:$bob,@colin:phone.wavi$alice'),
          throwsA(isA<UnAuthorizedException>().having((e) => e.message,
              'message', contains('@colin:phone.wavi$alice'))));
      expect(await stored(), isEmpty,
          reason: 'every recipient is judged before any is stored, so $bob, '
              'judged first and allowed, is not notified either');
    });
  });
}

/// Refuses the key it is asked about for @colin, as an access check that
/// turns on the recipient would.
class _RefusesColin extends NotifyAllVerbHandler {
  _RefusesColin(super.keyStore, super.notificationManager);

  @override
  Future<bool> isAuthorized(InboundConnectionMetadata inboundConnectionMetadata,
          {String? atKey,
          String? namespace,
          String enrolledNamespaceAccess = '',
          String operation = ''}) async =>
      !(atKey?.startsWith('@colin:') ?? false) &&
      await super.isAuthorized(inboundConnectionMetadata,
          atKey: atKey,
          namespace: namespace,
          enrolledNamespaceAccess: enrolledNamespaceAccess,
          operation: operation);
}
