import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/auth_utils.dart';
import 'package:test/test.dart';

import 'pol_peer.dart';

/// Catalogue: features/connection/exit.feature
void main() {
  final String atSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  final String host =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  final int port =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  /// A raw connection that records everything received and when it closes.
  Future<({SecureSocket socket, StringBuffer received, Future<void> closed})>
      open() async {
    final SecureSocket socket = await SecureSocket.connect(host, port);
    final StringBuffer received = StringBuffer();
    final Completer<void> closed = Completer<void>();
    void markClosed() => closed.isCompleted ? null : closed.complete();
    socket.listen(
      (bytes) => received.write(utf8.decode(bytes)),
      onDone: markClosed,
      onError: (_) => markClosed(),
    );
    return (socket: socket, received: received, closed: closed.future);
  }

  /// A raw connection, as [open] makes, destroyed at tear-down.
  Future<({SecureSocket socket, StringBuffer received, Future<void> closed})>
      connect() async {
    final c = await open();
    addTearDown(c.socket.destroy);
    return c;
  }

  /// Waits until [received], from offset [from] on, contains [text], failing
  /// after ten seconds.
  Future<void> until(StringBuffer received, String text, {int from = 0}) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!received.toString().substring(from).contains(text)) {
      if (DateTime.now().isAfter(deadline)) {
        fail('waited for "$text"; received: $received');
      }
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }

  /// CRAM-authenticates [socket] as [atSign].
  Future<void> cram(SecureSocket socket, StringBuffer received) async {
    socket.write('from:$atSign\n');
    await until(received, 'data:_');
    final String all = received.toString();
    final int start = all.indexOf('data:_') + 'data:'.length;
    final String challenge = all.substring(start, all.indexOf('\n', start));
    socket.write(
      'cram:${AuthenticationUtils.getCRAMDigest(atSign, challenge)}\n',
    );
    // The prompt too, so nothing of the reply is still to arrive.
    await until(received, 'data:success\n$atSign@');
  }

  Future<void> expectClosed(Future<void> closed, StringBuffer received) =>
      closed.timeout(
        const Duration(seconds: 10),
        onTimeout: () =>
            fail('the atServer left the connection open; received: $received'),
      );

  /// Sends [command] on a connection of its own, authenticated as [atSign],
  /// and answers the reply up to its prompt.
  Future<String> sendAlone(String command) async {
    final c = await open();
    try {
      await cram(c.socket, c.received);
      final int from = c.received.length;
      c.socket.write('$command\n');
      await until(c.received, '\n$atSign@', from: from);
      return c.received.toString().substring(from);
    } finally {
      c.socket.destroy();
    }
  }

  group('An atServer closes the connection on @exit', () {
    test('a client that has not authenticated', () async {
      final c = await connect();
      await until(c.received, '@');
      c.socket.write('@exit\n');
      await expectClosed(c.closed, c.received);
      expect(
        c.received.toString(),
        '@',
        reason: 'only the banner arrives; nothing is written for @exit',
      );
    });

    test('a client authenticated as @alice', () async {
      final c = await connect();
      await cram(c.socket, c.received);
      final int before = c.received.length;
      c.socket.write('@exit\n');
      await expectClosed(c.closed, c.received);
      expect(
        c.received.toString().substring(before),
        isEmpty,
        reason: 'nothing is written in reply to @exit',
      );
    });

    // @xavier plays @alice, and @jeremy plays @bob.
    test(
      'a peer atServer that has proved itself as @bob by pol',
      () async {
        final OutboundConnectionFactory jeremyClient =
            await clientOf('@jeremy');
        addTearDown(jeremyClient.close);
        final (SecureSocket socket, Future<String?> Function() next) =
            await polAs('@jeremy', jeremyClient, await addressOf('@xavier'));
        socket.write('@exit\n');
        expect(
          await next(),
          isNull,
          reason: 'the atServer writes nothing and closes the connection',
        );
      },
      timeout: Timeout(Duration(minutes: 2)),
    );
  });

  test(
    'Commands before @exit are answered, and commands after it are not',
    () async {
      final c = await connect();
      await cram(c.socket, c.received);
      final int before = c.received.length;
      // ONE write, so the three commands reach the atServer together.
      c.socket.write('noop:0\n@exit\nnoop:0\n');
      await expectClosed(c.closed, c.received);
      final String after = c.received.toString().substring(before);
      expect(
        'data:ok'.allMatches(after).length,
        1,
        reason: 'the first noop:0 is answered and the second is not; '
            'received after authenticating: $after',
      );
      expect(after, isNot(contains('error:')));
    },
  );

  test('A large response sent before @exit arrives whole', () async {
    final c = await connect();
    await cram(c.socket, c.received);
    final String key = 'exitlarge${DateTime.now().microsecondsSinceEpoch}'
        '.wavi$atSign';
    addTearDown(() => sendAlone('delete:$key'));
    final String value = 'v' * (512 * 1024);
    final int updated = c.received.length;
    c.socket.write('update:$key $value\n');
    await until(c.received, '\n$atSign@', from: updated);
    expect(
      c.received.toString().substring(updated),
      startsWith('data:'),
      reason: 'the update is answered with its commit id',
    );
    final int before = c.received.length;
    // ONE write, so @exit arrives while the llookup's reply is being sent.
    c.socket.write('llookup:$key\n@exit\n');
    await expectClosed(c.closed, c.received);
    final String after = c.received.toString().substring(before);
    expect(
      after.contains('data:$value\n'),
      isTrue,
      reason: 'received ${after.length} characters of a reply of '
          '${value.length + 6}',
    );
  });

  test('A command that only resembles @exit is refused as before', () async {
    final c = await connect();
    await cram(c.socket, c.received);
    c.socket.write('exit\n');
    await until(c.received, 'error:');
    expect(c.received.toString(), contains('AT0003'));
    // The connection stays open: a later command on it is still answered.
    c.socket.write('noop:0\n');
    await until(c.received, 'data:ok');
  });

  test(
    'A command that starts with @exit is judged as the command it is',
    () async {
      final c = await connect();
      await until(c.received, '@');
      final String key =
          'public:exithead${DateTime.now().microsecondsSinceEpoch}$atSign';
      c.socket.write('@exit update:$key 1\n');
      await expectClosed(c.closed, c.received);
      final String after = c.received.toString().substring('@'.length);
      expect(after, startsWith('error:AT0003'));
      expect('error:'.allMatches(after).length, 1, reason: 'received $after');
      expect(
        await sendAlone('llookup:$key'),
        startsWith('error:AT0015'),
        reason: 'the update is not handled, so there is no $key',
      );
    },
  );
}
