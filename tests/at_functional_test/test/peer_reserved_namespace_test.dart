import 'dart:io';

import 'package:at_functional_test/connection/answer_reader.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/connection/pol_peer.dart';
import 'package:at_lookup/at_lookup.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Catalogue: features/notify/peer_reserved_namespace.feature
///
/// @xavier plays @alice and @jeremy plays @bob, the peer that proves itself
/// by pol. Each test names its keys with a prefix of its own, and removes its
/// pol cookie.
void main() {
  const String xavier = '@xavier';
  const String jeremy = '@jeremy';
  const String rootDomain = 'vip.ve.atsign.zone';
  final int rootPort =
      int.tryParse(Platform.environment['VIRTUALENV_BASE_PORT'] ?? '') ?? 64;

  late SecondaryAddress xavierAddress;
  late OutboundConnectionFactory xavierClient;
  late OutboundConnectionFactory xavierCramClient;
  late OutboundConnectionFactory jeremyClient;

  Future<SecondaryAddress> addressOf(String atSign) =>
      CacheableSecondaryAddressFinder(rootDomain, rootPort)
          .findSecondary(atSign);

  Future<OutboundConnectionFactory> clientOf(String atSign,
      {AuthType authType = AuthType.pkam}) async {
    final SecondaryAddress address = await addressOf(atSign);
    final OutboundConnectionFactory client = await OutboundConnectionFactory()
        .initiateConnectionWithListener(atSign, address.host, address.port);
    expect((await client.authenticateConnection(authType: authType)).trim(),
        'data:success',
        reason: 'the client of $atSign must authenticate by ${authType.name}');
    return client;
  }

  Future<String> send(OutboundConnectionFactory client, String command) async =>
      (await client.sendRequestToServer(command)).trim();

  String prefix() => 'r${Uuid().v4().substring(0, 8)}';

  /// Whether [client]'s atServer holds a notification whose id is [id].
  Future<bool> holds(OutboundConnectionFactory client, String id) async =>
      await send(client, 'notify:status:$id') != 'data:null';

  /// Sends, as [client], a notification of an app key to [recipient] with an
  /// id of its own, and returns that id.
  Future<String> sendAllowed(
      OutboundConnectionFactory client, String recipient, String p) async {
    final String id = Uuid().v4();
    expect(
        await send(client,
            'notify:id:$id:update:messageType:key:$recipient:$p.wavi$xavier:x'),
        'data:$id');
    return id;
  }

  setUpAll(() async {
    xavierAddress = await addressOf(xavier);
    xavierClient = await clientOf(xavier);
    xavierCramClient = await clientOf(xavier, authType: AuthType.cram);
    jeremyClient = await clientOf(jeremy);
  });

  tearDownAll(() async {
    await xavierClient.close();
    await xavierCramClient.close();
    await jeremyClient.close();
  });

  /// A connection to @xavier's atServer on which @jeremy has proved itself by
  /// pol, and the reader of its answers.
  Future<(SecureSocket, Future<String?> Function())> polAsJeremy() async {
    final (
      SecureSocket socket,
      Future<String?> Function() next,
      String cookie
    ) = await polAs(jeremy, jeremyClient, xavierAddress);
    addTearDown(socket.destroy);
    addTearDown(() => send(jeremyClient, 'delete:$cookie'));
    return (socket, next);
  }

  /// The answer after [answer], past the prompt that may follow it.
  Future<String?> pastPrompt(Future<String?> Function() next) async {
    String? answer = await next();
    if (isPrompt(answer)) {
      answer = await next();
    }
    return answer;
  }

  group("Another atServer's notification into a reserved namespace is dropped",
      () {
    for (final (String example, String Function(String) key) in [
      ('x.__manage', (String p) => '$p.__manage'),
      ('public:__manage.wavi', (String p) => 'public:__manage.$p'),
      (
        'x.new.enrollments.__managex.wavi',
        (String p) => '$p.new.enrollments.__managex.wavi'
      ),
    ]) {
      test(example, () async {
        final (SecureSocket socket, Future<String?> Function() next) =
            await polAsJeremy();
        final String p = prefix();

        socket.write('notify:update:messageType:key:'
            '$xavier:${key(p)}$jeremy:x\n');

        expect(await next(), 'data:success');
        socket.write('notify:update:messageType:key:'
            '$xavier:$p.wavi$jeremy:x\n');
        expect(await pastPrompt(next), 'data:success',
            reason: 'the connection stays open');
        final String listed = await send(xavierClient, 'notify:list:$p');
        expect(listed, contains('$p.wavi'),
            reason: 'the notification after it is stored');
        expect(listed, isNot(contains('__manage')),
            reason: 'nothing is stored for the dropped notification');
      }, timeout: Timeout(Duration(minutes: 2)));
    }
  });

  group(
      "Another atServer's notification whose key is not a well-formed atKey "
      'is dropped', () {
    for (final (String example, String Function(String) key) in [
      ('a colon in the key', (String p) => '$p.__manage:y.wavi'),
      ('a space in the key', (String p) => '$p.__manage y.wavi'),
      ('a stream:init notification', (String p) => 'stream_id.$p '),
    ]) {
      test(example, () async {
        final (SecureSocket socket, Future<String?> Function() next) =
            await polAsJeremy();
        final String p = prefix();

        socket.write('notify:update:messageType:key:'
            '$xavier:${key(p)}$jeremy:x\n');

        expect(await next(), 'data:success');
        socket.write('notify:update:messageType:key:'
            '$xavier:$p.wavi$jeremy:x\n');
        expect(await pastPrompt(next), 'data:success',
            reason: 'the connection stays open');
        final String listed = await send(xavierClient, 'notify:list:$p');
        expect(listed, contains('$p.wavi'),
            reason: 'the notification after it is stored');
        expect(listed, isNot(contains(key(p).trim())),
            reason: 'nothing is stored for the dropped notification');
      }, timeout: Timeout(Duration(minutes: 2)));
    }
  });

  group(
      "An atSign's own client may not send a notification whose key is not a "
      'well-formed atKey', () {
    for (final (String example, String Function(String) key) in [
      ('a colon in the key', (String p) => '$p.__manage:y.wavi'),
      ('a space in the key', (String p) => '$p.__manage y.wavi'),
      ('a # in the key', (String p) => '$p#y.wavi'),
    ]) {
      test(example, () async {
        final String p = prefix();
        final String id = Uuid().v4();

        final String refused = await send(xavierCramClient,
            'notify:id:$id:update:messageType:key:$jeremy:${key(p)}$xavier:x');

        expect(refused, contains('AT0003'));
        expect(await holds(xavierCramClient, id), isFalse,
            reason: 'nothing is sent or stored');
        expect(
            await holds(xavierCramClient,
                await sendAllowed(xavierCramClient, jeremy, p)),
            isTrue,
            reason: 'control: an allowed notification is held under its id');
      });
    }
  });

  group(
      'Another atServer still notifies into an app namespace through a '
      'reserved-looking segment', () {
    for (final String key in ['__ck.wavi', '__en.apkamSymmetricKey.wavi']) {
      test('<id>.$key', () async {
        final (SecureSocket socket, Future<String?> Function() next) =
            await polAsJeremy();
        final String p = prefix();

        socket.write('notify:update:messageType:key:'
            '$xavier:$p.$key$jeremy:x\n');

        expect(await next(), 'data:success');
        expect(await send(xavierClient, 'notify:list:$p'), contains('$p.$key'));
      }, timeout: Timeout(Duration(minutes: 2)));
    }
  });

  group(
      "An atSign's own client may not send a notification into a reserved "
      'namespace', () {
    for (final (String auth, String recipient) in [
      ('cram', jeremy),
      ('pkam', jeremy),
      ('cram', xavier),
      ('pkam', xavier),
    ]) {
      test('$auth, to $recipient', () async {
        final OutboundConnectionFactory client =
            auth == 'cram' ? xavierCramClient : xavierClient;
        final String p = prefix();
        final String id = Uuid().v4();

        final String refused = await send(client,
            'notify:id:$id:update:messageType:key:$recipient:$p.__manage$xavier:x');

        expect(refused, contains('AT0009'));
        expect(
            refused,
            contains('Notification to $recipient may not use reserved '
                'namespace __manage'));
        expect(await holds(client, id), isFalse,
            reason: 'nothing is sent or stored');
        expect(await holds(client, await sendAllowed(client, recipient, p)),
            isTrue,
            reason: 'control: an allowed notification is held under its id');
      });
    }
  });
}
