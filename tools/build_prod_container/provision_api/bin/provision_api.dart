import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

const String homedir = '/atsign';
const String secondaryBin = '$homedir/bin/at_secondary_server';
const String supervisorConfDir = '/atsign/supervisor/conf.d';
const String supervisorSock = '$homedir/supervisor.sock';
const String atServersDir = '$homedir/atservers';
const String baseCertsDir = '$homedir/secondary/base/certs';
const String baseConfigDir = '$homedir/secondary/base/config';
const int basePort = 5000;

Future<void> main(List<String> arguments) async {
  final router = Router();

  router.get('/atSigns', _listAtSigns);
  router.get('/atSigns/<atSign>', _getAtSign);
  router.post('/atSigns/<atSign>', _provisionAtSign);
  router.delete('/atSigns/<atSign>', _deleteAtSign);
  router.post('/atSigns/<atSign>/restart', _restartAtSign);
  router.post('/atSigns/<atSign>/reset', _resetAtSign);

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addHandler(router.call);

  final port = int.tryParse(Platform.environment['PROVISION_API_PORT'] ?? '') ?? 3000;
  final server = await io.serve(handler, InternetAddress.anyIPv4, port);
  print('provision_api listening on port ${server.port}');
}

// --- Helpers ---

String _normalizeAtSign(String atSign) {
  return atSign.startsWith('@') ? atSign : '@$atSign';
}

String _confPath(String atSign, int port) =>
    '$supervisorConfDir/${port}_$atSign.conf';

String _atServerDir(String atSign) => '$atServersDir/$atSign';

String _generateCram() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

Future<int> _allocatePort() async {
  final confDir = Directory(supervisorConfDir);
  final usedPorts = <int>{};
  await for (final entity in confDir.list()) {
    final name = entity.path.split('/').last;
    final match = RegExp(r'^(\d+)_@').firstMatch(name);
    if (match != null) usedPorts.add(int.parse(match.group(1)!));
  }
  int port = basePort;
  while (usedPorts.contains(port)) port++;
  return port;
}

Future<Map<String, dynamic>?> _findAtSign(String atSign) async {
  final confDir = Directory(supervisorConfDir);
  await for (final entity in confDir.list()) {
    final name = entity.path.split('/').last;
    if (name.contains('_$atSign.conf')) {
      final match = RegExp(r'^(\d+)_').firstMatch(name);
      if (match != null) {
        return {'port': int.parse(match.group(1)!), 'confPath': entity.path};
      }
    }
  }
  return null;
}

Future<String> _supervisorCtl(List<String> args) async {
  final result = await Process.run('supervisorctl', [
    '-c', '/etc/supervisor/supervisord.conf',
    '-s', 'unix://$supervisorSock',
    ...args,
  ]);
  return '${result.stdout}${result.stderr}'.trim();
}

Future<void> _writeConf(String atSign, int port, String cram) async {
  final conf = '''
[program:${port}_$atSign]
directory = ${_atServerDir(atSign)}
command = $secondaryBin -a $atSign -p $port -s $cram
autostart = true
stdout_logfile = $homedir/logs/$atSign.log
redirect_stderr = true
username = atsign
autorestart = true
''';
  await File(_confPath(atSign, port)).writeAsString(conf);
}

Future<void> _registerInRedis(String atSign, int port) async {
  final host = Platform.environment['PROXY_URL']?.split(':').first ??
      'vip.ve.atsign.zone';
  final key = atSign.startsWith('@') ? atSign.substring(1) : atSign;
  // EXTERNAL_BASE_PORT lets the host map a different port range to the container.
  // e.g. if container uses 5000+ but host maps 15000->5000, set EXTERNAL_BASE_PORT=15000.
  final externalBase = int.tryParse(Platform.environment['EXTERNAL_BASE_PORT'] ?? '');
  final externalPort = externalBase != null ? externalBase + (port - basePort) : port;
  final result = await Process.run('redis-cli', [
    '-a', 'foobared',
    '--no-auth-warning',
    'set', key, '$host:$externalPort',
  ]);
  if (result.exitCode != 0) {
    throw Exception('redis-cli failed: ${result.stderr}');
  }
}

Future<void> _deregisterFromRedis(String atSign) async {
  final key = atSign.startsWith('@') ? atSign.substring(1) : atSign;
  await Process.run('redis-cli', [
    '-a', 'foobared',
    '--no-auth-warning',
    'del', key,
  ]);
}

Response _json(dynamic body, {int status = 200}) {
  return Response(status,
      body: jsonEncode(body),
      headers: {'content-type': 'application/json'});
}

// --- Handlers ---

Future<Response> _listAtSigns(Request request) async {
  final confDir = Directory(supervisorConfDir);
  final atSigns = <Map<String, dynamic>>[];
  await for (final entity in confDir.list()) {
    final name = entity.path.split('/').last;
    final match = RegExp(r'^(\d+)_(@\w+)\.conf$').firstMatch(name);
    if (match != null) {
      final port = int.parse(match.group(1)!);
      final atSign = match.group(2)!;
      final status = await _supervisorCtl(['status', '${port}_$atSign']);
      atSigns.add({'atSign': atSign, 'port': port, 'status': status});
    }
  }
  return _json(atSigns);
}

Future<Response> _getAtSign(Request request, String atSign) async {
  atSign = _normalizeAtSign(atSign);
  final info = await _findAtSign(atSign);
  if (info == null) return _json({'error': 'not found'}, status: 404);
  final port = info['port'] as int;
  final status = await _supervisorCtl(['status', '${port}_$atSign']);
  return _json({'atSign': atSign, 'port': port, 'status': status});
}

Future<Response> _provisionAtSign(Request request, String atSign) async {
  atSign = _normalizeAtSign(atSign);
  final existing = await _findAtSign(atSign);
  if (existing != null) {
    return _json({'error': '$atSign already provisioned'}, status: 409);
  }

  final port = await _allocatePort();
  final cram = _generateCram();
  final dir = Directory(_atServerDir(atSign));

  await dir.create(recursive: true);
  // Symlink shared certs and config (idempotent)
  final certsLink = Link('${dir.path}/certs');
  if (!await certsLink.exists()) await certsLink.create(baseCertsDir);
  final configLink = Link('${dir.path}/config');
  if (!await configLink.exists()) await configLink.create(baseConfigDir);
  // Write CRAM secret
  await File('${dir.path}/CRAM').writeAsString(cram);

  await _writeConf(atSign, port, cram);
  await _registerInRedis(atSign, port);
  await _supervisorCtl(['update']);
  await _supervisorCtl(['start', '${port}_$atSign']);

  return _json({'atSign': atSign, 'port': port, 'cram': cram}, status: 201);
}

Future<Response> _deleteAtSign(Request request, String atSign) async {
  atSign = _normalizeAtSign(atSign);
  final info = await _findAtSign(atSign);
  if (info == null) return _json({'error': 'not found'}, status: 404);

  final port = info['port'] as int;
  final confPath = info['confPath'] as String;

  await _supervisorCtl(['stop', '${port}_$atSign']);
  await _supervisorCtl(['remove', '${port}_$atSign']);
  await File(confPath).delete();
  await _deregisterFromRedis(atSign);

  return _json({'atSign': atSign, 'deleted': true});
}

Future<Response> _restartAtSign(Request request, String atSign) async {
  atSign = _normalizeAtSign(atSign);
  final info = await _findAtSign(atSign);
  if (info == null) return _json({'error': 'not found'}, status: 404);

  final port = info['port'] as int;
  final status = await _supervisorCtl(['restart', '${port}_$atSign']);
  return _json({'atSign': atSign, 'status': status});
}

Future<Response> _resetAtSign(Request request, String atSign) async {
  atSign = _normalizeAtSign(atSign);
  final info = await _findAtSign(atSign);
  if (info == null) return _json({'error': 'not found'}, status: 404);

  final port = info['port'] as int;
  await _supervisorCtl(['stop', '${port}_$atSign']);

  // Wipe storage, keep certs/config symlinks and CRAM
  final dir = Directory(_atServerDir(atSign));
  await for (final entity in dir.list()) {
    final name = entity.path.split('/').last;
    if (!['certs', 'config', 'CRAM'].contains(name)) {
      await entity.delete(recursive: true);
    }
  }

  await _supervisorCtl(['start', '${port}_$atSign']);
  return _json({'atSign': atSign, 'reset': true});
}
