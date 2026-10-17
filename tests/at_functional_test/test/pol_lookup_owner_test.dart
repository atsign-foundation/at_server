import 'dart:io';

import 'package:at_functional_test/connection/answer_reader.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_lookup/at_lookup.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'pol_peer.dart';

/// Catalogue: features/lookup/pol_lookup_owner.feature
///
/// @xavier plays @alice and @jeremy plays @chuck, the peer that proves itself
/// by pol. Each test publishes its pol cookie and any record it reads under
/// names of its own, and removes them.
void main() {
  const String xavier = '@xavier';
  const String jeremy = '@jeremy';

  late SecondaryAddress xavierAddress;
  late OutboundConnectionFactory xavierClient;
  late OutboundConnectionFactory jeremyClient;

  setUpAll(() async {
    xavierAddress = await addressOf(xavier);
    xavierClient = await clientOf(xavier);
    jeremyClient = await clientOf(jeremy);
  });

  tearDownAll(() async {
    await xavierClient.close();
    await jeremyClient.close();
  });

  /// A connection to @xavier's atServer on which @jeremy has proved itself by
  /// pol, and the reader of its answers.
  Future<(SecureSocket, Future<String?> Function())> polAsJeremy() =>
      polAs(jeremy, jeremyClient, xavierAddress);

  group(
      'A peer that has proved itself by pol may look up only the keys of the '
      'atSign it called', () {
    for (final String lookup in [
      'lookup:public:phone.wavi@bob',
      'lookup:phone.wavi@bob',
    ]) {
      test(lookup, () async {
        final (SecureSocket socket, Future<String?> Function() next) =
            await polAsJeremy();

        socket.write('$lookup\n');

        final String? reply = await next();
        expect(reply, startsWith('error:AT0009'));
        expect(
            reply,
            contains(
                "Lookup from $jeremy may read only $xavier's keys, not @bob's"));
        String? after = await next();
        if (isPrompt(after)) {
          after = await next();
        }
        expect(after, isNull, reason: 'the connection is closed');
      }, timeout: Timeout(Duration(minutes: 2)));
    }
  });

  test(
      'A peer that has proved itself by pol still looks up what the called '
      'atSign shared with it', () async {
    final String key = 'phone${Uuid().v4().substring(0, 8)}.wavi';
    addTearDown(() => send(xavierClient, 'delete:$jeremy:$key$xavier'));
    expect(await send(xavierClient, 'update:$jeremy:$key$xavier +44 1234'),
        startsWith('data:'));
    final (SecureSocket socket, Future<String?> Function() next) =
        await polAsJeremy();

    socket.write('lookup:$key$xavier\n');

    expect(await next(), 'data:+44 1234');
  }, timeout: Timeout(Duration(minutes: 2)));
}
