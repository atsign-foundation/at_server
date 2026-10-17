import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/utils/auth_utils.dart';
import 'package:test/test.dart';

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
      connect() async {
    final SecureSocket socket = await SecureSocket.connect(host, port);
    addTearDown(socket.destroy);
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

  /// Waits until [received] contains [text], failing after ten seconds.
  Future<void> until(StringBuffer received, String text) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!received.toString().contains(text)) {
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
    final String value = 'v' * (512 * 1024);
    c.socket.write('update:$key $value\n');
    await until(c.received, 'data:');
    await until(c.received, '\n$atSign@');
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
}
