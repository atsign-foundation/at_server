import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:at_telemetry/at_telemetry.dart';
import 'package:at_telemetry/at_telemetry_otel.dart';
import 'package:at_utils/at_logger.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

final class AtServerTelemetryDiskExporter implements AtTelemetryExporter {
  static bool _libraryConfigured = false;

  final Uri _endpoint;
  final String _keyId;
  final String _audience;
  final AtTelemetryRsaSigner _signer;
  final Database _database;
  final int _maxRecords;
  final int _maxBytes;
  final http.Client _client;
  final bool _ownsClient;
  final void Function(Object)? _onError;
  final AtSignLogger _logger = AtSignLogger('AtServerTelemetryDiskExporter');
  final AtTelemetryOtelLogsCodec _codec = const AtTelemetryOtelLogsCodec();
  Future<void>? _draining;
  Timer? _timer;
  Duration _retryDelay = const Duration(seconds: 1);
  bool _closed = false;
  int droppedRecords = 0;

  AtServerTelemetryDiskExporter._({
    required Uri endpoint,
    required String keyId,
    required String audience,
    required AtTelemetryRsaSigner signer,
    required Database database,
    required int maxRecords,
    required int maxBytes,
    required http.Client client,
    required bool ownsClient,
    void Function(Object)? onError,
  })  : _endpoint = endpoint,
        _keyId = keyId,
        _audience = audience,
        _signer = signer,
        _database = database,
        _maxRecords = maxRecords,
        _maxBytes = maxBytes,
        _client = client,
        _ownsClient = ownsClient,
        _onError = onError {
    _scheduleDrain();
  }

  static AtServerTelemetryDiskExporter open({
    required Uri endpoint,
    required String keyId,
    required String audience,
    required AtTelemetryRsaSigner signer,
    required String storagePath,
    required int maxRecords,
    required int maxBytes,
    http.Client? client,
    void Function(Object)? onError,
  }) {
    if (endpoint.scheme != 'https' ||
        !endpoint.hasAuthority ||
        endpoint.host.isEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        (endpoint.path.isNotEmpty &&
            endpoint.path != '/' &&
            !endpoint.path.endsWith('/v1/logs'))) {
      throw ArgumentError.value(endpoint, 'endpoint', 'invalid OTLP endpoint');
    }
    if (maxRecords < 1 || maxBytes < 1) {
      throw ArgumentError('Telemetry queue limits must be positive');
    }
    if (!_libraryConfigured) {
      _libraryConfigured = true;
      if (Platform.isLinux) {
        sqlite_open.open.overrideFor(sqlite_open.OperatingSystem.linux, () {
          try {
            return DynamicLibrary.open('libsqlite3.so.0');
          } on ArgumentError {
            return DynamicLibrary.open('libsqlite3.so');
          }
        });
      }
    }

    Directory(storagePath).createSync(recursive: true);
    final String filename =
        '${sha256.convert(utf8.encode(keyId)).toString()}.sqlite';
    final Database database = sqlite3.open(p.join(storagePath, filename));
    try {
      database.execute('PRAGMA journal_mode = DELETE');
      database.execute('PRAGMA synchronous = FULL');
      database.execute('PRAGMA busy_timeout = 5000');
      database.execute('CREATE TABLE IF NOT EXISTS telemetry_queue ('
          'id INTEGER PRIMARY KEY AUTOINCREMENT, payload BLOB NOT NULL)');
      return AtServerTelemetryDiskExporter._(
        endpoint: endpoint.replace(path: '/v1/logs'),
        keyId: keyId,
        audience: audience,
        signer: signer,
        database: database,
        maxRecords: maxRecords,
        maxBytes: maxBytes,
        client: client ?? http.Client(),
        ownsClient: client == null,
        onError: onError,
      );
    } catch (_) {
      database.dispose();
      rethrow;
    }
  }

  @override
  Future<void> export(AtTelemetryEvent event) {
    if (_closed) {
      throw StateError('Exporter is closed');
    }
    final List<int> payload = _codec.encodeExportRequest(
      <AtTelemetryEvent>[event],
      serviceName: 'at_secondary_server',
    );
    if (_enqueue(payload)) {
      _scheduleDrain();
    }
    return Future<void>.value();
  }

  bool _enqueue(List<int> payload) {
    if (payload.length > _maxBytes) {
      _reportDropped(1, 'oversized');
      return false;
    }

    _database.execute('BEGIN IMMEDIATE');
    try {
      final List<Row> rows = _database.select(
        'SELECT id, length(payload) AS bytes FROM telemetry_queue ORDER BY id',
      );
      int count = rows.length;
      int bytes = 0;
      for (final Row row in rows) {
        bytes += row['bytes'] as int;
      }
      int removed = 0;
      for (final Row row in rows) {
        if (count < _maxRecords && bytes + payload.length <= _maxBytes) {
          break;
        }
        _database.execute(
          'DELETE FROM telemetry_queue WHERE id = ?',
          <Object?>[row['id']],
        );
        count--;
        bytes -= row['bytes'] as int;
        removed++;
      }
      _database.execute(
        'INSERT INTO telemetry_queue (payload) VALUES (?)',
        <Object?>[payload],
      );
      _database.execute('COMMIT');
      if (removed > 0) {
        _reportDropped(removed);
      }
      return true;
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  void _reportDropped(int count, [String reason = 'oldest']) {
    droppedRecords += count;
    _logger.warning('Telemetry queue full, dropped $count $reason record(s)');
  }

  void _scheduleDrain() {
    if (_closed || _timer != null || _draining != null) {
      return;
    }
    _timer = Timer(Duration.zero, () {
      _timer = null;
      unawaited(_startDrain());
    });
  }

  Future<void> _startDrain() {
    if (_draining case final Future<void> active) {
      return active;
    }
    _timer?.cancel();
    _timer = null;
    final Future<void> drain = _sendQueued();
    _draining = drain;
    unawaited(drain.whenComplete(() {
      _draining = null;
      if (!_closed && _timer == null &&
          _database.select('SELECT 1 FROM telemetry_queue LIMIT 1').isNotEmpty) {
        _scheduleDrain();
      }
    }));
    return drain;
  }

  Future<void> _sendQueued() async {
    while (!_closed) {
      try {
        final List<Row> rows = _database.select(
          'SELECT id, payload FROM telemetry_queue ORDER BY id LIMIT 1',
        );
        if (rows.isEmpty) {
          return;
        }
        final Row row = rows.single;
        await _send(row['payload'] as List<int>);
        _database.execute(
          'DELETE FROM telemetry_queue WHERE id = ?',
          <Object?>[row['id']],
        );
        _retryDelay = const Duration(seconds: 1);
      } catch (error) {
        _onError?.call(error);
        if (!_closed) {
          final Duration delay = _retryDelay;
          _retryDelay = Duration(
            seconds: (_retryDelay.inSeconds * 2).clamp(1, 60),
          );
          _timer = Timer(delay, () {
            _timer = null;
            unawaited(_startDrain());
          });
        }
        return;
      }
    }
  }

  Future<void> _send(List<int> payload) async {
    final AtTelemetryHttpSignature signed = await AtTelemetryHttpSignature.sign(
      body: payload,
      path: _endpoint.path,
      keyId: _keyId,
      audience: _audience,
      signer: _signer,
    );
    final http.Request request = http.Request('POST', _endpoint)
      ..followRedirects = false
      ..headers.addAll(<String, String>{
        'content-type': AtTelemetryHttpSignature.contentType,
        AtTelemetryHttpSignature.digestHeader: signed.digest,
        AtTelemetryHttpSignature.audienceHeader: signed.audience,
        AtTelemetryHttpSignature.inputHeader: signed.input,
        AtTelemetryHttpSignature.signatureHeader: signed.signature,
      })
      ..bodyBytes = payload;
    final http.StreamedResponse response = await _client
        .send(request)
        .timeout(const Duration(seconds: 10));
    await response.stream.drain<void>().timeout(const Duration(seconds: 10));
    if (response.statusCode != HttpStatus.ok) {
      throw StateError('Telemetry rejected: HTTP ${response.statusCode}');
    }
  }

  @override
  Future<void> flush() async {
    if (_draining case final Future<void> active) {
      await active;
    }
    if (!_closed) {
      await _startDrain();
    }
  }

  @override
  Future<void> shutdown() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _timer?.cancel();
    _timer = null;
    try {
      await _draining;
    } finally {
      if (_ownsClient) {
        _client.close();
      }
      _database.dispose();
    }
  }
}
