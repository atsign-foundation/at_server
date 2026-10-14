import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/auth_utils.dart';
import 'package:at_lookup/at_lookup.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Catalogue: features/lookup/pol_lookup_owner.feature
///
/// @xavier plays @alice and @jeremy plays @chuck, the peer that proves itself
/// by pol. Each test publishes its pol cookie and any record it reads under
/// names of its own, and removes them.
void main() {
  const String xavier = '@xavier';
  const String jeremy = '@jeremy';
  const String rootDomain = 'vip.ve.atsign.zone';
  final int rootPort =
      int.tryParse(Platform.environment['VIRTUALENV_BASE_PORT'] ?? '') ?? 64;

  late SecondaryAddress xavierAddress;
  late OutboundConnectionFactory xavierClient;
  late OutboundConnectionFactory jeremyClient;

  Future<SecondaryAddress> addressOf(String atSign) =>
      CacheableSecondaryAddressFinder(rootDomain, rootPort)
          .findSecondary(atSign);

  Future<OutboundConnectionFactory> clientOf(String atSign) async {
    final SecondaryAddress address = await addressOf(atSign);
    final OutboundConnectionFactory client = await OutboundConnectionFactory()
        .initiateConnectionWithListener(atSign, address.host, address.port);
    expect(await client.authenticateConnection(), 'data:success',
        reason: 'the client of $atSign must authenticate');
    return client;
  }

  Future<String> send(OutboundConnectionFactory client, String command) async =>
      (await client.sendRequestToServer(command)).trim();

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
  /// pol, presenting the virtualenv's client certificate as every atServer
  /// in it does to another. Its reader answers null once the atServer has
  /// closed the connection.
  Future<(SecureSocket, Future<String?> Function())> polAsJeremy() async {
    const String certs = '../../tools/build_virtual_environment/ve_base/'
        'contents/atsign/secondary/base/certs/mtls';
    final SecureSocket socket = await SecureSocket.connect(
        xavierAddress.host, xavierAddress.port,
        context: SecurityContext(withTrustedRoots: true)
          ..useCertificateChain('$certs/fullchain.pem')
          ..usePrivateKey('$certs/privkey.pem'));
    final StreamController<String> lines = StreamController<String>();
    String pending = '';
    socket.listen((data) {
      pending += utf8.decode(data);
      int end;
      while ((end = pending.indexOf('\n')) != -1) {
        lines.add(pending.substring(0, end).trim());
        pending = pending.substring(end + 1);
      }
      // NOTE a prompt ends an answer without a newline, and pol's answer is
      // the prompt it opens.
      if (RegExp(r'^@?[^\s:@]*@$').hasMatch(pending.trim())) {
        if (pending.trim() != '@') {
          lines.add(pending.trim());
        }
        pending = '';
      }
    }, onDone: lines.close, onError: (_) => lines.close());
    final StreamIterator<String> answers = StreamIterator(lines.stream);
    Future<String?> next() async {
      if (!await answers.moveNext().timeout(const Duration(seconds: 30))) {
        return null;
      }
      final String line = answers.current;
      return RegExp(r'^@(data|error):').hasMatch(line)
          ? line.substring(1)
          : line;
    }

    final String signingKey =
        (await send(jeremyClient, 'llookup:$jeremy:signing_privatekey$jeremy'))
            .replaceFirst('data:', '');
    socket.write('from:$jeremy\n');
    final String? proof = await next();
    expect(proof, startsWith('data:proof:'));
    final List<String> sessionAndChallenge =
        proof!.substring('data:proof:'.length).split(':');
    final String cookie = 'public:${sessionAndChallenge[0]}';
    expect(
        await send(
            jeremyClient,
            'update:$cookie '
            '${AuthenticationUtils.generatePKAMDigest(signingKey, sessionAndChallenge[1])}'),
        startsWith('data:'));
    socket.write('pol\n');
    expect(await next(), '$jeremy@');
    await send(jeremyClient, 'delete:$cookie');
    return (socket, next);
  }

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
        expect(reply,
            contains("Lookup from $jeremy may read only $xavier's keys, not @bob's"));
        expect(await next(), isNull, reason: 'the connection is closed');
        await socket.close();
      }, timeout: Timeout(Duration(minutes: 2)));
    }
  });

  test(
      'A peer that has proved itself by pol still looks up what the called '
      'atSign shared with it', () async {
    final String key = 'phone${Uuid().v4().substring(0, 8)}.wavi';
    expect(await send(xavierClient, 'update:$jeremy:$key$xavier +44 1234'),
        startsWith('data:'));
    final (SecureSocket socket, Future<String?> Function() next) =
        await polAsJeremy();

    socket.write('lookup:$key$xavier\n');

    expect(await next(), 'data:+44 1234');
    await socket.close();
    await send(xavierClient, 'delete:$jeremy:$key$xavier');
  }, timeout: Timeout(Duration(minutes: 2)));
}
