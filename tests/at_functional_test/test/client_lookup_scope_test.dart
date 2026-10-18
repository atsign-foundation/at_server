import 'dart:convert';
import 'dart:io';

import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_lookup/at_lookup.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Catalogue: features/lookup/client_lookup_scope.feature
///
/// @xavier plays @alice and @jeremy plays @bob. @carol is an atSign named
/// only in the key. Each test writes its records under names of its own, and
/// removes them.
void main() {
  const String xavier = '@xavier';
  const String jeremy = '@jeremy';
  const String rootDomain = 'vip.ve.atsign.zone';
  final int rootPort =
      int.tryParse(Platform.environment['VIRTUALENV_BASE_PORT'] ?? '') ?? 64;

  late OutboundConnectionFactory xavierClient;
  late OutboundConnectionFactory jeremyClient;

  Future<OutboundConnectionFactory> clientOf(String atSign) async {
    final SecondaryAddress address =
        await CacheableSecondaryAddressFinder(rootDomain, rootPort)
            .findSecondary(atSign);
    final OutboundConnectionFactory client = await OutboundConnectionFactory()
        .initiateConnectionWithListener(atSign, address.host, address.port);
    expect(await client.authenticateConnection(), 'data:success',
        reason: 'the client of $atSign must authenticate');
    return client;
  }

  Future<String> send(OutboundConnectionFactory client, String command) async =>
      (await client.sendRequestToServer(command)).trim();

  setUpAll(() async {
    xavierClient = await clientOf(xavier);
    jeremyClient = await clientOf(jeremy);
  });

  tearDownAll(() async {
    await xavierClient.close();
    await jeremyClient.close();
  });

  group(
      "A client's lookup of another atSign's key with a scope is refused "
      "without asking that atSign's atServer", () {
    const String key = 'phone.wavi';

    for (final (String lookup, String named) in [
      ('lookup:public:$key$jeremy', 'public:$key$jeremy'),
      ('lookup:@carol:$key$jeremy', '@carol:$key$jeremy'),
      ('lookup:all:public:$key$jeremy', 'public:$key$jeremy'),
    ]) {
      test(lookup, () async {
        final String reply = await send(xavierClient, lookup);

        expect(reply, startsWith('error:'));
        final Map error = jsonDecode(reply.substring('error:'.length));
        expect(error['errorCode'], 'AT0009');
        expect(
            error['errorDescription'],
            contains('Lookup from $xavier may name the key only as '
                '$key$jeremy, not $named'));
        expect(await send(xavierClient, 'info:brief'), startsWith('data:'),
            reason: 'the connection stays open');
      });
    }
  });

  test("A client still looks up another atSign's key named bare", () async {
    final String key = 'phone${Uuid().v4().substring(0, 8)}.wavi';
    addTearDown(() => send(jeremyClient, 'delete:$xavier:$key$jeremy'));
    expect(await send(jeremyClient, 'update:$xavier:$key$jeremy +44 5678'),
        startsWith('data:'));

    expect(await send(xavierClient, 'lookup:$key$jeremy'), 'data:+44 5678');
  }, timeout: Timeout(Duration(minutes: 2)));

  test("A client's lookup of its own atSign's key may name a scope", () async {
    final String key = 'phone${Uuid().v4().substring(0, 8)}.wavi';
    addTearDown(() => send(xavierClient, 'delete:public:$key$xavier'));
    expect(await send(xavierClient, 'update:public:$key$xavier +44 1234'),
        startsWith('data:'));

    expect(
        await send(xavierClient, 'lookup:public:$key$xavier'), 'data:+44 1234');
  });
}
