import 'dart:io';

import 'package:at_functional_test/connection/answer_reader.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/auth_utils.dart';
import 'package:at_lookup/at_lookup.dart';

/// The virtualenv's client certificate, which every atServer in it presents
/// to another, relative to this package.
const String _certs = '../../tools/build_virtual_environment/ve_base/'
    'contents/atsign/secondary/base/certs/mtls';

/// Opens a connection to [address] on which [peer] proves itself by pol, as
/// [peer]'s atServer does, with [peerClient], [peer]'s own authenticated
/// client, signing the challenge and holding the pol cookie.
///
/// Returns the connection, the reader of its answers, and the key of the
/// cookie, which the caller deletes through [peerClient] once done. Throws a
/// [StateError] when the atServer does not accept the proof.
Future<(SecureSocket, Future<String?> Function(), String)> polAs(String peer,
    OutboundConnectionFactory peerClient, SecondaryAddress address) async {
  final SecureSocket socket =
      await SecureSocket.connect(address.host, address.port,
          context: SecurityContext(withTrustedRoots: true)
            ..useCertificateChain('$_certs/fullchain.pem')
            ..usePrivateKey('$_certs/privkey.pem'));
  final Future<String?> Function() next = answersOf(socket);

  final String signingKey = (await peerClient
          .sendRequestToServer('llookup:$peer:signing_privatekey$peer'))
      .trim()
      .replaceFirst('data:', '');
  socket.write('from:$peer\n');
  final String? proof = await next();
  if (proof == null || !proof.startsWith('data:proof:')) {
    socket.destroy();
    throw StateError('from:$peer was answered $proof');
  }
  final List<String> sessionAndChallenge =
      proof.substring('data:proof:'.length).split(':');
  final String cookie = 'public:${sessionAndChallenge[0]}';
  await peerClient.sendRequestToServer('update:$cookie '
      '${AuthenticationUtils.generatePKAMDigest(signingKey, sessionAndChallenge[1])}');
  socket.write('pol\n');
  final String? proved = await next();
  if (proved != '$peer@') {
    socket.destroy();
    throw StateError('pol was answered $proved');
  }
  return (socket, next, cookie);
}
