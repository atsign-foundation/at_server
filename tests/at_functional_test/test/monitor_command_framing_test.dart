import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/auth_utils.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Functional coverage of inbound command framing: a client that writes
/// `monitor` and `noop:0` in ONE socket write puts both commands in one read
/// event, and both have to run.
///
/// That is the shape a notification connection carrying its own heartbeat
/// has. Framed as a single command, `monitor:...\nnoop:0` matches no verb
/// syntax — each is anchored `^...$` without `multiLine`, and `.` does not
/// cross a newline — so the client gets one `error:AT0003` frame on a
/// connection that stays open, with no monitor registered for it and the
/// `noop:0` never run. The failure then presents as an atServer with nothing
/// to say, which is why the notification below is the assertion that matters.
///
/// The monitor is read over a RAW socket rather than
/// [OutboundConnectionFactory]: that wrapper's listener only surfaces
/// responses beginning `data:`, `stream:`, `error:` or `@...@`
/// (`OutboundMessageListener._isValidResponse`), and a monitor frame begins
/// `notification:`, so the wrapper structurally cannot read one.
void main() {
  String atSign = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String host = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int port = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  test(
      'a monitor and the noop:0 written with it are both executed, and the '
      'monitor is delivered a notification', () async {
    OutboundConnectionFactory owner = await OutboundConnectionFactory()
        .initiateConnectionWithListener(atSign, host, port);
    expect((await owner.authenticateConnection(authType: AuthType.cram)).trim(),
        'data:success');

    // The notification is created BEFORE the monitor connects and is replayed
    // from a timestamp, so its delivery does not race the monitor's socket
    // becoming ready.
    int since = DateTime.now().toUtc().millisecondsSinceEpoch - 1000;
    String notifiedKey = 'framing-${Uuid().v4().hashCode}.wavi';
    expect(
        (await owner.sendRequestToServer('notify:update:ttr:-1:$atSign:'
                '$notifiedKey$atSign:framing-value'))
            .trim(),
        startsWith('data:'));

    StringBuffer received = StringBuffer();
    Completer<void> monitorAnswered = Completer<void>();
    SecureSocket socket = await SecureSocket.connect(host, port);
    bool cramSent = false;
    bool monitorSent = false;

    // Chunks are accumulated and matched against the whole buffer: the '@'
    // prompt and the `from:` challenge can arrive coalesced in one read, so a
    // startsWith on an individual chunk misses them.
    socket.listen((data) {
      received.write(utf8.decode(data));
      String all = received.toString();
      if (!cramSent && all.contains('data:_')) {
        cramSent = true;
        int start = all.indexOf('data:_') + 'data:'.length;
        int end = all.indexOf('\n', start);
        String challenge =
            all.substring(start, end == -1 ? all.length : end).trim();
        socket.write(
            'cram:${AuthenticationUtils.getCRAMDigest(atSign, challenge)}\n');
      } else if (cramSent && !monitorSent && all.contains('data:success')) {
        monitorSent = true;
        // ONE write, so both commands reach the atServer in one read event.
        // Writing them separately, or flushing between them, would leave the
        // framing unexercised.
        socket.write('monitor:selfNotifications:$since\nnoop:0\n');
      } else if (!monitorAnswered.isCompleted &&
          all.contains('data:ok') &&
          all.contains(notifiedKey)) {
        monitorAnswered.complete();
      }
    });

    socket.write('from:$atSign\n');
    // Bounded rather than a fixed wait: green returns as soon as both the
    // noop's reply and the notification are in, and red still reports what
    // did arrive.
    await monitorAnswered.future.timeout(Duration(seconds: 30),
        onTimeout: () {});
    await socket.close();
    await owner.close();

    String delivered = received.toString();
    // The control: the connection got as far as authenticating, so what
    // follows is about the framing and not about a socket that never worked.
    expect(delivered, contains('data:success'),
        reason: 'the monitor connection must have CRAM-authenticated. '
            'Received: $delivered');
    expect(delivered, contains('data:ok'),
        reason: 'the noop:0 that arrived in the same read event as the '
            'monitor must be executed. Received: $delivered');
    expect(delivered, contains(notifiedKey),
        reason: 'the monitor must be registered and deliver $notifiedKey. '
            'Received: $delivered');
    expect(delivered, isNot(contains('error:AT0003')),
        reason: 'neither command is a syntax error. Received: $delivered');
  }, timeout: Timeout(Duration(minutes: 2)));
}
