import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/info_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_all_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_multi_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// FROZEN: the notify:multi wire literal at_commons pins; a client sends
/// exactly this, so the server must take it unchanged.
const frozenCommand = 'notify:multi:update:ttln:900000:isEncrypted:true'
    ':appMetadata:eyJwcm92aWRlcklkIjoiYXQvc3ltbWV0cmljL0FFUy9HQ00vZ3JvdXAiLCJja0tpZCI6ImFiY2QiLCJpdiI6ImFYWT0iLCJucyI6ImNoYXQubXlhcHAiLCJja05zIjoiY2hhdC5teWFwcCJ9'
    ':@bob,@sitaram:msg.chat.myapp@alice:CIPHERTEXT';

void main() {
  late NotifyMultiVerbHandler handler;

  setUp(() async {
    await verbTestsSetUp();
    handler = NotifyMultiVerbHandler(keyValueStore, notificationManager);
    inboundConnection.metadata
      ..isAuthenticated = true
      ..authType = AuthType.cram;
  });
  tearDown(() async => await verbTestsTearDown());

  /// Runs [command] and returns the reply map of recipient to id.
  Future<Map<String, dynamic>> multi(String command) async {
    final response = await handler.processInternal(command, inboundConnection);
    return jsonDecode(response.data!) as Map<String, dynamic>;
  }

  /// Every notification the atServer has stored.
  Future<List<AtNotification>> stored() => notifStore.iterate().toList();

  /// The stored notification for [toAtSign].
  Future<AtNotification> storedFor(String toAtSign) async =>
      (await stored()).singleWhere((n) => n.toAtSign == toAtSign);

  group('notify:multi delivers', () {
    test('each recipient gets the value and its metadata', () async {
      await multi(frozenCommand);
      expect((await stored()).map((n) => n.toAtSign).toSet(),
          {'@bob', '@sitaram'});
      for (final recipient in ['@bob', '@sitaram']) {
        final n = await storedFor(recipient);
        expect(n.notification, '$recipient:msg.chat.myapp@alice');
        expect(n.atValue, 'CIPHERTEXT');
        expect(n.fromAtSign, '@alice');
        expect(n.opType, OperationType.update);
        expect(n.messageType, MessageType.key);
        expect(n.atMetadata!.isEncrypted, isTrue);
        expect(
            n.atMetadata!.appMetadata!.toJson(),
            {
              'providerId': 'at/symmetric/AES/GCM/group',
              'ckKid': 'abcd',
              'iv': 'aXY=',
              'ns': 'chat.myapp',
              'ckNs': 'chat.myapp',
            },
            reason: 'the recipient needs the provider, key id and iv to '
                'decrypt the value');
      }
    });

    test('ttln sets each notification\'s expiry', () async {
      await multi(frozenCommand);
      for (final n in await stored()) {
        expect(n.ttl, 900000);
        // NOTE expiresAt is stamped when the notification is built, a few
        // milliseconds after notificationDateTime.
        expect(n.expiresAt!.difference(n.notificationDateTime!).inMilliseconds,
            inInclusiveRange(900000, 901000));
      }
    });

    test('each recipient\'s atServer is sent the value and its metadata',
        () async {
      await multi(frozenCommand);
      final n = await storedFor('@bob');
      final body = notificationManager.prepareNotifyCommandBody(n);
      // FROZEN: what the sender's atServer sends a recipient's atServer; the
      // id and the remaining ttln are the only parts that vary.
      expect(
          body
              .replaceFirst('id:${n.id}:', 'id:<id>:')
              .replaceFirst(RegExp(r':ttln:\d+:'), ':ttln:<ms>:'),
          'id:<id>:update:messageType:key:notifier:system:ttln:<ms>'
          ':ttl:0:ttb:0:isEncrypted:true'
          ':appMetadata:eyJwcm92aWRlcklkIjoiYXQvc3ltbWV0cmljL0FFUy9HQ00vZ3JvdXAiLCJja0tpZCI6ImFiY2QiLCJpdiI6ImFYWT0iLCJucyI6ImNoYXQubXlhcHAiLCJja05zIjoiY2hhdC5teWFwcCJ9'
          ':@bob:msg.chat.myapp@alice:CIPHERTEXT');
      final HashMap<String, String?> received =
          getVerbParam(Notify().syntax(), 'notify:$body');
      expect(received[AtConstants.isEncrypted], 'true',
          reason: 'the recipient\'s atServer parses it as a plain notify');
      expect(received[AtConstants.atValue], 'CIPHERTEXT');
    });

    test('the reply is keyed by the normalised recipient', () async {
      final reply = await multi(frozenCommand);
      expect(reply.keys, ['@bob', '@sitaram']);
      expect(reply['@bob'], (await storedFor('@bob')).id);
      expect(reply['@sitaram'], (await storedFor('@sitaram')).id);
    });

    test('an atSign named twice is notified once', () async {
      final reply =
          await multi('notify:multi:@bob,@BOB:msg.chat.myapp@alice:v');
      expect(reply.keys, ['@bob']);
      expect(await stored(), hasLength(1));
    });

    for (final namespaces in [
      {'chat.myapp': 'rw'},
      {'*': 'rw'},
    ]) {
      test('for an enrollment holding $namespaces', () async {
        final enrollmentId =
            await createAndPersistAnEnrollment('myapp', 'pixel', namespaces);
        inboundConnection.metadata
          ..authType = AuthType.apkam
          ..enrollmentId = enrollmentId;
        await multi(frozenCommand);
        expect(await stored(), hasLength(2),
            reason: 'an enrollment that may write the key may notify it, as '
                'with notify:all');
      });
    }

    test('the atServer\'s own atSign is notified as the notify verb does it',
        () async {
      await multi('notify:multi:@alice:msg.chat.myapp@alice:v');
      final n = await storedFor('@alice');
      expect(n.type, NotificationType.received);
      expect(n.notificationStatus, NotificationStatus.delivered);
    });
  });

  group('notify:multi refuses', () {
    // FROZEN: the metadata fields notify:multi refuses, by their wire names.
    const refused = {
      'ttr': ':ttr:60000',
      'ccd': ':ccd:true',
      'sharedKeyEnc': ':sharedKeyEnc:abc',
      'pubKeyCS': ':pubKeyCS:abc',
      'pubKeyHash': ':pubKeyHash:abc',
      'hashingAlgo': ':hashingAlgo:sha256',
      'skeEncKeyName': ':skeEncKeyName:abc',
      'skeEncAlgo': ':skeEncAlgo:abc',
      'isBinary': ':isBinary:true',
      'encoding': ':encoding:base64',
      'sharedKeyStatus': ':sharedKeyStatus:abc',
      'dataSignature': ':dataSignature:abc',
    };
    for (final MapEntry(key: field, value: fragment) in refused.entries) {
      test('$field, naming it, before anything is stored', () async {
        await expectLater(
            multi('notify:multi$fragment:@bob,@sitaram:msg.chat.myapp@alice:v'),
            throwsA(isA<InvalidSyntaxException>()
                .having((e) => e.message, 'message', contains(field))));
        expect(await stored(), isEmpty);
      });
    }

    test('a key another atSign owns, before anything is stored', () async {
      await expectLater(multi('notify:multi:@bob:msg.chat.myapp@colin:v'),
          throwsA(isA<UnAuthorizedException>()));
      expect(await stored(), isEmpty);
    });

    test('a recipient without its @', () async {
      await expectLater(
          multi('notify:multi:@bob,sitaram:msg.chat.myapp@alice:v'),
          throwsA(isA<InvalidSyntaxException>()));
      expect(await stored(), isEmpty);
    });

    test('a malformed metadata field rather than reading it as a recipient',
        () async {
      await expectLater(
          multi('notify:multi:update:ttl:abc@evil:isEncrypted:true'
              ':@bob,@sitaram:msg.chat.myapp@alice:CIPHERTEXT'),
          throwsA(isA<InvalidSyntaxException>()),
          reason: 'with a looser recipient group this parses as recipient '
              'ttl, key abc and sender evil');
      expect(await stored(), isEmpty);
    });

    test('an unauthenticated connection', () async {
      inboundConnection.metadata.isAuthenticated = false;
      await expectLater(
          multi(frozenCommand), throwsA(isA<UnAuthenticatedException>()));
      expect(await stored(), isEmpty);
    });

    test('a connection from another atServer', () async {
      inboundConnection.metadata
        ..isAuthenticated = false
        ..isPolAuthenticated = true;
      await expectLater(
          multi(frozenCommand), throwsA(isA<UnAuthenticatedException>()),
          reason: 'notify:multi is for clients; atServers send plain notify');
      expect(await stored(), isEmpty);
    });

    test('a key in another enrollment\'s reserved namespace, even under *',
        () async {
      final otherId = await createAndPersistAnEnrollment(
          'other', 'pixel', {'chat.myapp': 'rw'});
      final enrollmentId =
          await createAndPersistAnEnrollment('myapp', 'pixel', {'*': 'rw'});
      inboundConnection.metadata
        ..authType = AuthType.apkam
        ..enrollmentId = enrollmentId;
      final reserved = AbstractVerbHandler.enrollmentReservedNamespace(otherId);
      await expectLater(multi('notify:multi:@bob:ck.$reserved@alice:v'),
          throwsA(isA<UnAuthorizedException>()),
          reason: 'an enrollment\'s reserved keys are its own, whatever '
              'another enrollment holds');
      expect(await stored(), isEmpty);
    });

    test('a root shared key, from an enrollment that may write nothing',
        () async {
      final enrollmentId = await createAndPersistAnEnrollment(
          'myapp', 'pixel', {'chat.myapp': 'r'});
      inboundConnection.metadata
        ..authType = AuthType.apkam
        ..enrollmentId = enrollmentId;
      await expectLater(multi('notify:multi:@bob:shared_key.bob@alice:v'),
          throwsA(isA<UnAuthorizedException>()),
          reason: 'notify:multi changes what recipients hold, as notify:all '
              'does, so a read-only enrollment may not send a shared key');
      expect(await stored(), isEmpty);
    });

    test('a key in a namespace the enrollment may only read', () async {
      final enrollmentId = await createAndPersistAnEnrollment(
          'myapp', 'pixel', {'chat.myapp': 'r'});
      inboundConnection.metadata
        ..authType = AuthType.apkam
        ..enrollmentId = enrollmentId;
      await expectLater(
          multi(frozenCommand), throwsA(isA<UnAuthorizedException>()));
      expect(await stored(), isEmpty);
    });

    test('a key outside the enrollment\'s namespaces', () async {
      final enrollmentId =
          await createAndPersistAnEnrollment('wavi', 'pixel', {'wavi': 'rw'});
      inboundConnection.metadata
        ..authType = AuthType.apkam
        ..enrollmentId = enrollmentId;
      await expectLater(
          multi(frozenCommand), throwsA(isA<UnAuthorizedException>()));
      expect(await stored(), isEmpty);
    });
  });

  group('notify:multi routing', () {
    test('only the notify:multi handler accepts it', () {
      expect(handler.accept(frozenCommand), isTrue);
      expect(
          NotifyVerbHandler(keyValueStore, notificationManager)
              .accept(frozenCommand),
          isFalse,
          reason: 'plain notify takes every notify: command it does not '
              'exclude, and is registered first');
      expect(
          NotifyAllVerbHandler(keyValueStore, notificationManager)
              .accept(frozenCommand),
          isFalse);
    });

    test('the verb handler manager resolves it to the notify:multi handler',
        () {
      final manager = DefaultVerbHandlerManager(
        keyValueStore,
        mockOutboundClientManager,
        cacheManager,
        statsNotificationService,
        notificationManager,
        enMgr,
        AtSecondaryServerImpl.getInstance().currentAtSign,
        commitLog: atCommitLog,
        accessLog: atAccessLog,
      );
      expect(
          manager.getVerbHandler(frozenCommand), isA<NotifyMultiVerbHandler>());
    });
  });

  group('info lists notify.multi', () {
    for (final command in ['info', 'info:brief']) {
      test('in $command', () async {
        final response = await InfoVerbHandler(keyValueStore)
            .processInternal(command, inboundConnection);
        final List features = jsonDecode(response.data!)['features'];
        expect(features.map((f) => f['name']), contains('notify.multi'),
            reason: 'a client sends notify:multi only to an atServer that '
                'lists it');
      });
    }
  });
}
