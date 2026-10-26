import 'dart:convert';
import 'dart:io';

import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/connection/pol_peer.dart';
import 'package:at_lookup/at_lookup.dart';
import 'package:test/test.dart';

/// Catalogue: features/stream/stream_verb.feature
///
/// @xavier plays @alice and @jeremy plays @bob, the peer that proves itself
/// by pol, and @carol.
void main() {
  const String xavier = '@xavier';
  const String jeremy = '@jeremy';
  const String rootDomain = 'vip.ve.atsign.zone';
  final int rootPort =
      int.tryParse(Platform.environment['VIRTUALENV_BASE_PORT'] ?? '') ?? 64;
  const String init = 'stream:init$jeremy namespace:wavi s1 f.txt 12';

  late SecondaryAddress xavierAddress;
  late OutboundConnectionFactory xavierClient;
  late OutboundConnectionFactory jeremyClient;

  Future<SecondaryAddress> addressOf(String atSign) =>
      CacheableSecondaryAddressFinder(rootDomain, rootPort)
          .findSecondary(atSign);

  Future<OutboundConnectionFactory> connect(String atSign) async {
    final SecondaryAddress address = await addressOf(atSign);
    return OutboundConnectionFactory()
        .initiateConnectionWithListener(atSign, address.host, address.port);
  }

  Future<OutboundConnectionFactory> clientOf(String atSign) async {
    final OutboundConnectionFactory client = await connect(atSign);
    expect((await client.authenticateConnection()).trim(), 'data:success',
        reason: 'the client of $atSign must authenticate by pkam');
    return client;
  }

  Future<String> send(OutboundConnectionFactory client, String command) async =>
      (await client.sendRequestToServer(command)).trim();

  /// The notifications of type sent that @xavier's atServer holds.
  Future<int> sent() async {
    final String reply = await send(xavierClient, 'stats:11');
    final dynamic value =
        (jsonDecode(reply.replaceFirst('data:', '')) as List).single['value'];
    final Map stats = value is String ? jsonDecode(value) : value;
    return stats['type']['sent'];
  }

  setUpAll(() async {
    xavierAddress = await addressOf(xavier);
    xavierClient = await clientOf(xavier);
    jeremyClient = await clientOf(jeremy);
  });

  tearDownAll(() async {
    await xavierClient.close();
    await jeremyClient.close();
  });

  group('A stream command is refused', () {
    test("@alice's client authenticated by pkam, $init", () async {
      final int before = await sent();

      expect(await send(xavierClient, init), contains('AT0003'));

      expect(await sent(), before, reason: 'no notification is queued');
      expect(await send(xavierClient, 'info'), startsWith('data:'),
          reason: 'it keeps its connection');
    });

    test('a peer that has proved itself as @bob by pol, $init', () async {
      final (
        SecureSocket socket,
        Future<String?> Function() next,
        String cookie
      ) = await polAs(jeremy, jeremyClient, xavierAddress);
      addTearDown(socket.destroy);
      addTearDown(() => send(jeremyClient, 'delete:$cookie'));
      final int before = await sent();

      socket.write('$init\n');

      expect(await next(), contains('AT0003'));
      expect(await sent(), before, reason: 'no notification is queued');
    }, timeout: Timeout(Duration(minutes: 2)));

    for (final String command in [
      'stream:resume$jeremy startByte:5 s1',
      'stream:receive s1',
      'stream:done s1',
    ]) {
      test('a connection that has not authenticated, $command', () async {
        final OutboundConnectionFactory unauthenticated = await connect(xavier);
        addTearDown(unauthenticated.close);
        final int before = await sent();

        expect(await send(unauthenticated, command), contains('AT0003'));

        expect(await sent(), before, reason: 'no notification is queued');
      });
    }
  });
}
