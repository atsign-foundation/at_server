import 'dart:io';

import 'package:at_functional_test/connection/answer_reader.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/auth_utils.dart';
import 'package:at_lookup/at_lookup.dart';
import 'package:test/test.dart';

const String _rootDomain = 'vip.ve.atsign.zone';
final int _rootPort =
    int.tryParse(Platform.environment['VIRTUALENV_BASE_PORT'] ?? '') ?? 64;

/// The address of [atSign]'s atServer, from the virtualenv's atDirectory.
Future<SecondaryAddress> addressOf(String atSign) =>
    CacheableSecondaryAddressFinder(_rootDomain, _rootPort)
        .findSecondary(atSign);

/// An authenticated client of [atSign]'s atServer.
Future<OutboundConnectionFactory> clientOf(String atSign) async {
  final SecondaryAddress address = await addressOf(atSign);
  final OutboundConnectionFactory client = await OutboundConnectionFactory()
      .initiateConnectionWithListener(atSign, address.host, address.port);
  expect(await client.authenticateConnection(), 'data:success',
      reason: 'the client of $atSign must authenticate');
  return client;
}

/// Sends [command] on [client] and answers its reply, trimmed.
Future<String> send(OutboundConnectionFactory client, String command) async =>
    (await client.sendRequestToServer(command)).trim();

/// A connection to the atServer at [address] on which [peer] has proved
/// itself by pol, presenting the virtualenv's client certificate as every
/// atServer in it does to another, and the reader of its answers.
/// [peerClient], a client of [peer]'s own atServer, publishes the pol cookie,
/// which is removed at tear-down.
Future<(SecureSocket, Future<String?> Function())> polAs(String peer,
    OutboundConnectionFactory peerClient, SecondaryAddress address) async {
  const String certs = '../../tools/build_virtual_environment/ve_base/'
      'contents/atsign/secondary/base/certs/mtls';
  final SecureSocket socket =
      await SecureSocket.connect(address.host, address.port,
          context: SecurityContext(withTrustedRoots: true)
            ..useCertificateChain('$certs/fullchain.pem')
            ..usePrivateKey('$certs/privkey.pem'));
  addTearDown(socket.destroy);
  final Future<String?> Function() next = answersOf(socket);

  final String signingKey =
      (await send(peerClient, 'llookup:$peer:signing_privatekey$peer'))
          .replaceFirst('data:', '');
  socket.write('from:$peer\n');
  final String? proof = await next();
  expect(proof, startsWith('data:proof:'));
  final List<String> sessionAndChallenge =
      proof!.substring('data:proof:'.length).split(':');
  final String cookie = 'public:${sessionAndChallenge[0]}';
  addTearDown(() => send(peerClient, 'delete:$cookie'));
  expect(
      await send(
          peerClient,
          'update:$cookie '
          '${AuthenticationUtils.generatePKAMDigest(signingKey, sessionAndChallenge[1])}'),
      startsWith('data:'));
  socket.write('pol\n');
  expect(await next(), '$peer@');
  return (socket, next);
}
