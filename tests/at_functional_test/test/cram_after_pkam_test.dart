import 'dart:convert';

import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/auth_utils.dart';
import 'package:test/test.dart';

/// Catalogue: features/authentication/cram_after_pkam.feature
void main() {
  final String atSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  final String host =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  final int port =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  /// Connections opened by a test, closed in tearDown.
  final List<OutboundConnectionFactory> open = [];

  tearDown(() async {
    for (final c in open) {
      try {
        await c.close();
      } on Exception {
        // The atServer may have closed it already.
      }
    }
    open.clear();
  });

  /// A connection to [atSign]'s atServer that has authenticated with
  /// [authType].
  Future<OutboundConnectionFactory> authenticatedWith(
      AuthType authType) async {
    final c = await OutboundConnectionFactory()
        .initiateConnectionWithListener(atSign, host, port);
    open.add(c);
    expect((await c.authenticateConnection(authType: authType)).trim(),
        'data:success');
    return c;
  }

  /// The challenge a `from:` on [c] is answered with.
  Future<String> challenge(OutboundConnectionFactory c) async =>
      (await c.sendRequestToServer('from:$atSign')).replaceAll('data:', '');

  /// The proof [verb] answers a fresh challenge on [c] with.
  Future<String> proofFor(String verb, OutboundConnectionFactory c) async =>
      verb == 'cram'
          ? AuthenticationUtils.getCRAMDigest(atSign, await challenge(c))
          : AuthenticationUtils.generatePKAMDigest(
              pkamPrivateKeyMap[atSign]!, await challenge(c));

  /// Whether the atServer has stopped answering on [c].
  Future<bool> isClosed(OutboundConnectionFactory c) async {
    try {
      return (await c.sendRequestToServer('noop:0', maxWaitMilliSeconds: 5000))
          .isEmpty;
    } on Exception {
      return true;
    }
  }

  test(
      'A cram after a successful pkam on the same connection is refused and '
      'closes it', () async {
    final c = await authenticatedWith(AuthType.pkam);

    final String response =
        await c.sendRequestToServer('cram:${await proofFor('cram', c)}');

    expect(response,
        'error:AT0009:cram may not follow a successful pkam on this connection');
    expect(await isClosed(c), isTrue);
  });

  group('An authentication inside a batch is refused', () {
    for (final (AuthType auth, String verb) in [
      (AuthType.pkam, 'cram'),
      (AuthType.cram, 'cram'),
      (AuthType.pkam, 'pkam'),
      (AuthType.cram, 'pkam'),
    ]) {
      test('$verb on a connection authenticated with ${auth.name}', () async {
        final c = await authenticatedWith(auth);
        final String command = '$verb:${await proofFor(verb, c)}';

        final String response = await c.sendRequestToServer('batch:${jsonEncode([
              {'id': 1, 'command': command}
            ])}');

        final List entries = jsonDecode(response.replaceFirst('data:', ''));
        expect(entries.single['id'], 1);
        expect(entries.single['response']['error_code'], 'AT0009');
        expect(await isClosed(c), isFalse);
        expect(await c.sendRequestToServer('scan'), startsWith('data:'),
            reason: 'still authenticated');
      });
    }
  });

  test('A pkam after a cram on the same connection still succeeds', () async {
    final c = await authenticatedWith(AuthType.cram);

    expect(await c.sendRequestToServer('pkam:${await proofFor('pkam', c)}'),
        'data:success');
  });
}
