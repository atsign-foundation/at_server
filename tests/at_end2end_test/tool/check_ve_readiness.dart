// Readiness probes for a locally-run virtualenv, driven by the SAME
// config/config.yaml the e2e tests read — so the ports can only ever be the
// ports under test.
//
// Lives in tool/ rather than test/ deliberately: `dart test` globs test/, and
// these probes are meaningless in CI (which runs the pack against the
// long-lived @cicd atSigns, not against a container).
//
// Modes:
//   atservers  the atDirectory resolves each test atSign, and each atServer
//              accepts a TLS connection
//   pkam       each test atSign answers `lookup:pkaminstalled` with data:yes
//              (i.e. install_PKAM_Keys has landed its keys)
//
// Exits 0 when ready, 1 (with a reason on stderr) when it gives up.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_end2end_test/conf/config_util.dart';

const int maxTries = 60;
const Duration retryDelay = Duration(seconds: 2);

class _AtSign {
  final String name;
  final String host;
  final int port;

  _AtSign(this.name, this.host, this.port);

  @override
  String toString() => '$name ($host:$port)';
}

Future<void> main(List<String> args) async {
  if (args.length != 1 || !['atservers', 'pkam'].contains(args[0])) {
    stderr.writeln('usage: check_ve_readiness.dart <atservers|pkam>');
    exit(2);
  }
  final mode = args[0];

  final yaml = ConfigUtil.getYaml()!;
  final rootHost = yaml['root_server']['url'] as String;
  final rootPort = yaml['root_server']['port'] as int;
  final atSigns = <_AtSign>[
    _AtSign(
      yaml['first_atsign_server']['first_atsign_name'],
      yaml['first_atsign_server']['first_atsign_url'],
      yaml['first_atsign_server']['first_atsign_port'],
    ),
    _AtSign(
      yaml['second_atsign_server']['second_atsign_name'],
      yaml['second_atsign_server']['second_atsign_url'],
      yaml['second_atsign_server']['second_atsign_port'],
    ),
  ];

  switch (mode) {
    case 'atservers':
      for (final atSign in atSigns) {
        await _waitFor(
          'atDirectory $rootHost:$rootPort resolves ${atSign.name}',
          () => _resolvesInAtDirectory(rootHost, rootPort, atSign.name),
        );
        await _waitFor(
          'atServer for $atSign accepts connections',
          () => _accepts(atSign),
        );
      }
      break;
    case 'pkam':
      for (final atSign in atSigns) {
        await _waitFor(
          'PKAM keys installed for $atSign',
          () => _pkamInstalled(atSign),
        );
      }
      break;
  }
  exit(0);
}

/// Retries [probe] until it returns true, or gives up after [maxTries] and
/// exits nonzero — a readiness check that returns success on exhaustion just
/// moves the failure into the test run, where it reads as a product bug.
Future<void> _waitFor(String what, Future<bool> Function() probe) async {
  for (var i = 1; i <= maxTries; i++) {
    bool ok;
    try {
      ok = await probe();
    } catch (e) {
      ok = false;
      if (i == maxTries) {
        stderr.writeln('Last failure while waiting for $what: $e');
      }
    }
    if (ok) {
      print('OK: $what');
      return;
    }
    print('Waiting for $what ... ($i/$maxTries)');
    await Future.delayed(retryDelay);
  }
  stderr.writeln('FAILED: gave up waiting for $what');
  exit(1);
}

/// The atDirectory answers a bare atSign with `<host>:<port>` (or `null` when
/// it does not know it yet — the secondaries register themselves at startup).
Future<bool> _resolvesInAtDirectory(String host, int port, String atSign) async {
  final socket = await SecureSocket.connect(host, port,
      timeout: Duration(seconds: 5));
  try {
    final response = await _exchange(socket, '${atSign.replaceAll('@', '')}\n');
    return response.contains(':') && !response.startsWith('null');
  } finally {
    socket.destroy();
  }
}

Future<bool> _accepts(_AtSign atSign) async {
  final socket = await SecureSocket.connect(atSign.host, atSign.port,
      timeout: Duration(seconds: 5));
  socket.destroy();
  return true;
}

Future<bool> _pkamInstalled(_AtSign atSign) async {
  final socket = await SecureSocket.connect(atSign.host, atSign.port,
      timeout: Duration(seconds: 5));
  try {
    final response =
        await _exchange(socket, 'lookup:pkaminstalled${atSign.name}\n');
    return response.startsWith('data:yes');
  } finally {
    socket.destroy();
  }
}

/// Writes [command] and returns the first payload line the server sends back.
///
/// `@` is the unauthenticated prompt, emitted both on connect and after each
/// response — and it is NOT reliably on a line of its own. The observed chunks
/// for `lookup:pkaminstalled@alice🛠` are `"@"` then `"data:yes\n@"`, so the
/// accumulated buffer reads `@data:yes\n@`: the prompt is glued to the front of
/// the payload and has to be stripped, not skipped.
Future<String> _exchange(SecureSocket socket, String command) async {
  final completer = Completer<String>();
  final buffer = StringBuffer();
  socket.listen((data) {
    buffer.write(utf8.decode(data));
    for (final line in buffer.toString().split('\n')) {
      final trimmed = line.trim().replaceFirst(RegExp(r'^@+'), '');
      if (trimmed.isNotEmpty && !completer.isCompleted) {
        completer.complete(trimmed);
      }
    }
  }, onError: (e) {
    if (!completer.isCompleted) completer.completeError(e);
  }, onDone: () {
    if (!completer.isCompleted) {
      completer.completeError(StateError('connection closed with no response'));
    }
  });
  socket.write(command);
  return completer.future.timeout(Duration(seconds: 10));
}
