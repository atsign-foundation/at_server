import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/utils/auth_utils.dart';

/// A connection to one atServer that frames its responses by line, completing
/// each request as its response arrives.
class AtWire {
  static final RegExp _response =
      RegExp(r'^(?:@(?:[^@:\s]+@)?)?((?:data|error|notification):.*)$');

  final SecureSocket _socket;
  final Queue<Completer<String>> _pending = Queue();
  final StreamController<String> _notifications = StreamController.broadcast();
  final List<int> _buffer = [];

  AtWire._(this._socket) {
    _socket.listen(_onData,
        onError: (Object e) => _failAll('socket error: $e'),
        onDone: () => _failAll('socket closed'));
  }

  /// A connection to [atSign]'s atServer at [host]:[port], authenticated by
  /// PKAM with the demo keys.
  static Future<AtWire> authenticated(
      String atSign, String host, int port) async {
    final AtWire wire = AtWire._(await SecureSocket.connect(host, port));
    final String challenge = _data(await wire.request('from:$atSign'));
    final String digest = AuthenticationUtils.generatePKAMDigest(
        pkamPrivateKeyMap[atSign]!, challenge);
    final String answer = await wire.request('pkam:$digest');
    if (answer != 'data:success') {
      throw StateError('pkam as $atSign answered "$answer"');
    }
    return wire;
  }

  /// The `notification:` lines this connection receives, without the prefix.
  Stream<String> get notifications => _notifications.stream;

  /// Sends [command] without waiting for an answer.
  void send(String command) => _socket.write('$command\n');

  /// Sends [command] and answers its response line, `data:` or `error:`.
  Future<String> request(String command,
      {Duration timeout = const Duration(seconds: 60)}) {
    final Completer<String> answer = Completer();
    _pending.add(answer);
    send(command);
    return answer.future.timeout(timeout);
  }

  Future<void> close() async {
    await _socket.close();
    _socket.destroy();
  }

  static String _data(String line) {
    if (!line.startsWith('data:')) {
      throw StateError('expected data, got "$line"');
    }
    return line.substring('data:'.length);
  }

  void _onData(List<int> data) {
    _buffer.addAll(data);
    int newline;
    while ((newline = _buffer.indexOf(0x0a)) >= 0) {
      final String text = utf8.decode(_buffer.sublist(0, newline));
      _buffer.removeRange(0, newline + 1);
      final Match? match = _response.firstMatch(text);
      if (match == null) {
        continue;
      }
      final String line = match.group(1)!;
      if (line.startsWith('notification:')) {
        _notifications.add(line.substring('notification:'.length).trim());
      } else if (_pending.isNotEmpty) {
        _pending.removeFirst().complete(line);
      }
    }
  }

  void _failAll(String reason) {
    while (_pending.isNotEmpty) {
      _pending.removeFirst().completeError(StateError(reason));
    }
  }
}

/// Sets the fault proxy's mode with a control line, which it answers `ok`.
Future<String> setFault(int controlPort, String line) async {
  final Socket socket =
      await Socket.connect(InternetAddress.loopbackIPv4, controlPort);
  final Future<String> answer =
      utf8.decoder.bind(socket).transform(const LineSplitter()).first;
  socket.write('$line\n');
  final String reply = await answer.timeout(const Duration(seconds: 10));
  socket.destroy();
  if (!reply.startsWith('ok')) {
    throw StateError('fault proxy answered "$reply" to "$line"');
  }
  return reply;
}

/// Runs supervisorctl in the virtualenv [container] with [arguments], and
/// answers what it printed.
Future<String> supervisor(String container, List<String> arguments) async {
  final ProcessResult result = await Process.run(
      'docker', ['exec', container, 'supervisorctl', ...arguments]);
  if (result.exitCode != 0) {
    throw StateError('supervisorctl ${arguments.join(' ')} exited '
        '${result.exitCode}: ${result.stdout}${result.stderr}');
  }
  return '${result.stdout}'.trim();
}

/// The pid supervisorctl's `status` line reports for a running program.
int supervisedPid(String status) {
  final Match? match = RegExp(r'RUNNING\s+pid (\d+)').firstMatch(status);
  if (match == null) {
    throw StateError('not running: "$status"');
  }
  return int.parse(match.group(1)!);
}
