import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/answer_reader.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Catalogue: features/lookup/unauthenticated_lookup_owner.feature
void main() {
  final String atSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  final String host =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  final int port =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  /// A connection to [atSign]'s atServer that has sent [first], if anything,
  /// and the reader of its answers.
  Future<(SecureSocket, Future<String?> Function())> unauthenticated(
      String? first) async {
    final SecureSocket socket = await SecureSocket.connect(host, port);
    addTearDown(socket.destroy);
    final Future<String?> Function() next = answersOf(socket);
    if (first != null) {
      socket.write('$first\n');
      expect(await next(), startsWith('data:'));
    }
    return (socket, next);
  }

  group(
      'A connection that has not authenticated may look up only the keys of '
      'the atSign it is on', () {
    for (final (String connection, String? first, String lookup) in [
      (
        'a client has sent from:$atSign',
        'from:$atSign',
        'lookup:public:phone.wavi@bob'
      ),
      (
        'a client has sent from:$atSign',
        'from:$atSign',
        'lookup:phone.wavi@bob'
      ),
      (
        'a peer has sent to:$atSign',
        'to:$atSign',
        'lookup:public:phone.wavi@bob'
      ),
      ('a client has sent nothing yet', null, 'lookup:public:phone.wavi@bob'),
    ]) {
      test('$connection | $lookup', () async {
        final (SecureSocket socket, Future<String?> Function() next) =
            await unauthenticated(first);

        socket.write('$lookup\n');

        final String? reply = await next();
        expect(reply, startsWith('error:AT0009'));
        expect(
            reply,
            contains('Lookup on a connection that has not authenticated may '
                "read only $atSign's keys, not @bob's"));
        String? after = await next();
        if (isPrompt(after)) {
          after = await next();
        }
        expect(after, isNull, reason: 'the connection is closed');
      }, timeout: Timeout(Duration(minutes: 2)));
    }
  });

  test(
      "A connection that has not authenticated still looks up this atSign's "
      'public keys', () async {
    final OutboundConnectionFactory owner = await OutboundConnectionFactory()
        .initiateConnectionWithListener(atSign, host, port);
    addTearDown(owner.close);
    expect(await owner.authenticateConnection(), 'data:success');
    final String key = 'phone${Uuid().v4().substring(0, 8)}.wavi';
    addTearDown(() => owner.sendRequestToServer('delete:public:$key$atSign'));
    expect(
        await owner.sendRequestToServer('update:public:$key$atSign +44 1234'),
        startsWith('data:'));
    final (SecureSocket socket, Future<String?> Function() next) =
        await unauthenticated('from:$atSign');

    socket.write('lookup:$key$atSign\n');

    expect(await next(), 'data:+44 1234');
  }, timeout: Timeout(Duration(minutes: 2)));
}
