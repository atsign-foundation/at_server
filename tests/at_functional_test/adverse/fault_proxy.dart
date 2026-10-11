/// A TCP proxy that injects faults into the traffic to one atServer, for the
/// adverse-peer tests. It runs in the virtualenv's network namespace:
///
/// ```sh
/// dart fault_proxy.dart LISTEN_PORT UPSTREAM_PORT CONTROL_PORT
/// ```
///
/// It forwards `127.0.0.1:LISTEN_PORT` to `127.0.0.1:UPSTREAM_PORT` byte for
/// byte, so TLS passes through untouched. A line sent to `CONTROL_PORT` sets
/// the mode for every connection, open or new, and is answered `ok`:
///
/// ```text
/// pass                forward as is
/// delay MS JITTER     hold each chunk, either way, MS ± JITTER ms, in order
/// trickle EVERY       send the upstream's replies one byte every EVERY ms
/// stall               hold the upstream's replies back
/// hangup              close the connection halfway through the next reply
/// stats               answered `ok connections=N up=U down=D`: connections
///                     taken, and bytes forwarded upstream and back
/// ```
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

final Random _random = Random();
String _mode = 'pass';
List<int> _args = [];
Completer<void> _modeChanged = Completer<void>();
int _connections = 0;
int _bytesUp = 0;
int _bytesDown = 0;

Future<void> main(List<String> arguments) async {
  final int listenPort = int.parse(arguments[0]);
  final int upstreamPort = int.parse(arguments[1]);
  final int controlPort = int.parse(arguments[2]);

  final ServerSocket control =
      await ServerSocket.bind(InternetAddress.anyIPv4, controlPort);
  control.listen(_serveControl);
  final ServerSocket proxy =
      await ServerSocket.bind(InternetAddress.loopbackIPv4, listenPort);
  proxy.listen((client) => _bridge(client, upstreamPort));
  stdout.writeln('fault proxy: 127.0.0.1:$listenPort -> '
      '127.0.0.1:$upstreamPort, control on $controlPort');
}

void _serveControl(Socket socket) {
  String pending = '';
  socket.listen((data) {
    pending += String.fromCharCodes(data);
    int newline;
    while ((newline = pending.indexOf('\n')) >= 0) {
      final List<String> words = pending.substring(0, newline).trim().split(' ');
      pending = pending.substring(newline + 1);
      socket.write('${_command(words)}\n');
    }
  }, onError: (_) => socket.destroy(), onDone: socket.destroy);
}

String _command(List<String> words) {
  switch (words.first) {
    case 'stats':
      return 'ok connections=$_connections up=$_bytesUp down=$_bytesDown';
    case 'pass' || 'delay' || 'trickle' || 'stall' || 'hangup':
      _mode = words.first;
      _args = words.skip(1).map(int.parse).toList();
      final Completer<void> changed = _modeChanged;
      _modeChanged = Completer<void>();
      changed.complete();
      stdout.writeln('mode: ${words.join(' ')}');
      return 'ok';
    default:
      return 'error unknown command ${words.first}';
  }
}

Future<void> _bridge(Socket client, int upstreamPort) async {
  _connections++;
  final Socket upstream;
  try {
    upstream = await Socket.connect(InternetAddress.loopbackIPv4, upstreamPort);
  } on SocketException {
    client.destroy();
    return;
  }
  bool open = true;
  void closeBoth() {
    open = false;
    client.destroy();
    upstream.destroy();
  }

  Future<void> toUpstream = Future.value();
  client.listen((chunk) {
    toUpstream = toUpstream.then((_) async {
      if (_mode == 'delay') {
        await _delay();
      }
      if (open) {
        _bytesUp += chunk.length;
        upstream.add(chunk);
      }
    });
  }, onError: (_) => closeBoth(), onDone: closeBoth);

  Future<void> toClient = Future.value();
  upstream.listen((chunk) {
    toClient = toClient.then((_) async {
      while (open && _mode == 'stall') {
        await _modeChanged.future;
      }
      if (!open) return;
      switch (_mode) {
        case 'delay':
          await _delay();
          if (open) {
            _bytesDown += chunk.length;
            client.add(chunk);
          }
        case 'trickle':
          stdout.writeln('trickling a ${chunk.length}-byte chunk');
          for (final int byte in chunk) {
            await Future.delayed(Duration(milliseconds: _args[0]));
            if (!open) return;
            _bytesDown++;
            client.add([byte]);
          }
        case 'hangup':
          _mode = 'pass';
          final List<int> half = chunk.sublist(0, (chunk.length / 2).ceil());
          stdout.writeln('hanging up after ${half.length} of a'
              ' ${chunk.length}-byte chunk');
          _bytesDown += half.length;
          client.add(half);
          await client.flush();
          closeBoth();
        default:
          _bytesDown += chunk.length;
          client.add(chunk);
      }
    });
  }, onError: (_) => closeBoth(), onDone: closeBoth);
}

Future<void> _delay() {
  final int jitter = _args[1] == 0 ? 0 : _random.nextInt(2 * _args[1] + 1) - _args[1];
  return Future.delayed(Duration(milliseconds: max(0, _args[0] + jitter)));
}
