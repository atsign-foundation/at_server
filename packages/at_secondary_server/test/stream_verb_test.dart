import 'dart:convert';

import 'package:at_secondary/src/connection/inbound/connection_util.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:test/test.dart';

import 'atsign_bound_harness.dart';
import 'test_utils.dart';

/// Catalogue: features/stream/stream_verb.feature
void main() {
  setUpAll(() async => await verbTestsSetUpAll());
  setUp(() async => await setUpAtSignBound());
  tearDown(() async => await verbTestsTearDown());

  Connection alicePkamClient() => Connection(InboundConnectionMetadata()
    ..isAuthenticated = true
    ..authType = AuthType.pkamLegacy);

  /// Sends [command] on [connection] as a command read from its socket is
  /// handled: validated, then executed.
  Future<void> sendFromSocket(String command, Connection connection) async {
    try {
      InboundCommandValidator.validate(utf8.encode(command), connection);
    } on Exception catch (e) {
      await GlobalExceptionHandler.getInstance()
          .handle(e, atConnection: connection);
      return;
    }
    await send(command, connection);
  }

  group('A stream command is refused', () {
    for (final (
          String connection,
          Connection Function() connect,
          String command
        ) in [
      (
        "@alice's client authenticated by pkam",
        alicePkamClient,
        'stream:init@carol namespace:wavi s1 f.txt 12'
      ),
      (
        'a peer that has proved itself as @bob by pol',
        () => peer(bob),
        'stream:init@carol namespace:wavi s1 f.txt 12'
      ),
      (
        'a connection that has not authenticated',
        unauthenticated,
        'stream:resume@carol startByte:5 s1'
      ),
      (
        'a connection that has not authenticated',
        unauthenticated,
        'stream:receive s1'
      ),
      (
        'a connection that has not authenticated',
        unauthenticated,
        'stream:done s1'
      ),
    ]) {
      test('$connection, $command', () async {
        final Connection client = connect();
        final List<Object?> before = await footprint();

        await sendFromSocket(command, client);

        expect(client.writes.first, startsWith('error:AT0003'));
        expect(await footprint(), before,
            reason: 'no notification is queued or stored');
        expect(
            client.closeCount,
            client.metadata.isAuthenticated ||
                    client.metadata.isPolAuthenticated
                ? 0
                : greaterThan(0),
            reason: 'a connection that has authenticated keeps its '
                'connection, and one that has not is closed');
      });
    }
  });
}
