import 'dart:async';
import 'dart:io';

import 'package:at_telemetry/at_telemetry.dart';
import 'package:at_telemetry/at_telemetry_otel.dart';
import 'package:at_utils/at_logger.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

import 'at_server_telemetry_disk_queue.dart';

final class AtServerTelemetryExporter implements AtTelemetryExporter {
  final Uri _endpoint;
  final String _keyId;
  final String _audience;
  final AtTelemetryRsaSigner _signer;
  final AtServerTelemetryDiskQueue? _queue;
  final http.Client _client;
  final bool _ownsClient;
  final AtTelemetrySignedHttpExporter _directExporter;
  final void Function(Object)? _onError;
  final AtSignLogger _logger = AtSignLogger('AtServerTelemetryExporter');
  final AtTelemetryOtelLogsCodec _codec = const AtTelemetryOtelLogsCodec();
  Future<void>? _draining;
  Timer? _timer;
  Duration _retryDelay = const Duration(seconds: 1);
  bool _closed = false;
  bool _diskWriteDisabled = false;

  AtServerTelemetryExporter._({
    required Uri endpoint,
    required String keyId,
    required String audience,
    required AtTelemetryRsaSigner signer,
    required AtServerTelemetryDiskQueue? queue,
    required http.Client client,
    required bool ownsClient,
    void Function(Object)? onError,
  })  : _endpoint = endpoint,
        _keyId = keyId,
        _audience = audience,
        _signer = signer,
        _queue = queue,
        _client = client,
        _ownsClient = ownsClient,
        _directExporter = AtTelemetrySignedHttpExporter(
          endpoint: endpoint,
          serviceName: 'at_secondary_server',
          keyId: keyId,
          audience: audience,
          signer: signer,
          client: client,
          onError: onError,
        ),
        _onError = onError {
    if (queue != null) {
      _scheduleDrain();
    }
  }

  int get droppedRecords => _queue?.droppedRecords ?? 0;
  bool get isDirectExport => _queue == null || _diskWriteDisabled;

  static AtServerTelemetryExporter open({
    required Uri endpoint,
    required String keyId,
    required String audience,
    required AtTelemetryRsaSigner signer,
    required String storagePath,
    required int maxRecords,
    required int maxBytes,
    bool persistToDisk = true,
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
    final AtServerTelemetryDiskQueue? queue = persistToDisk
        ? AtServerTelemetryDiskQueue.open(
            serverId: keyId,
            storagePath: storagePath,
            maxRecords: maxRecords,
            maxBytes: maxBytes,
          )
        : null;
    final http.Client actualClient = client ?? http.Client();
    return AtServerTelemetryExporter._(
      endpoint: endpoint.replace(path: '/v1/logs'),
      keyId: keyId,
      audience: audience,
      signer: signer,
      queue: queue,
      client: actualClient,
      ownsClient: client == null,
      onError: onError,
    );
  }

  @override
  Future<void> export(AtTelemetryEvent event) {
    if (_closed) {
      throw StateError('Exporter is closed');
    }
    final AtServerTelemetryDiskQueue? queue = _queue;
    if (queue == null || _diskWriteDisabled) {
      return _directExporter.export(event);
    }
    final List<int> payload = _codec.encodeExportRequest(
      <AtTelemetryEvent>[event],
      serviceName: 'at_secondary_server',
    );
    try {
      if (queue.write(payload)) {
        _scheduleDrain();
      }
    } on SqliteException catch (error) {
      return _exportDirectly(event, error);
    } on FileSystemException catch (error) {
      return _exportDirectly(event, error);
    }
    return Future<void>.value();
  }

  Future<void> _exportDirectly(AtTelemetryEvent event, Object error) {
    _diskWriteDisabled = true;
    _logger.warning('Telemetry disk write failed: ${error.runtimeType}; '
        'switching to direct signed export');
    return _directExporter.export(event);
  }

  void _scheduleDrain() {
    if (_closed || _queue == null || _timer != null || _draining != null) {
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
    final AtServerTelemetryDiskQueue? queue = _queue;
    if (queue == null) {
      return Future<void>.value();
    }
    final Future<void> drain = _sendQueued(queue);
    _draining = drain;
    unawaited(drain.whenComplete(() {
      _draining = null;
      if (_closed || _timer != null) {
        return;
      }
      try {
        if (queue.isNotEmpty) {
          _scheduleDrain();
        }
      } on SqliteException catch (error) {
        _onError?.call(error);
      } on FileSystemException catch (error) {
        _onError?.call(error);
      }
    }));
    return drain;
  }

  Future<void> _sendQueued(AtServerTelemetryDiskQueue queue) async {
    while (!_closed) {
      try {
        final (int, List<int>)? next = queue.peek();
        if (next == null) {
          return;
        }
        final (int id, List<int> payload) = next;
        await _send(payload);
        queue.acknowledge(id);
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
    final http.StreamedResponse response =
        await _client.send(request).timeout(const Duration(seconds: 10));
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
    await _directExporter.flush();
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
      await _directExporter.shutdown();
    } finally {
      if (_ownsClient) {
        _client.close();
      }
      _queue?.close();
    }
  }
}
