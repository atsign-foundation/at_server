import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_telemetry/at_telemetry.dart';
import 'package:at_utils/at_logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'at_server_telemetry_signing_key.dart';

// Sends each of the atServer's telemetry records to its collector straight
// away, as one signed OTLP/JSON POST over HTTPS. Requests go one at a time,
// in the order their sequence numbers were taken, so the collector sees them
// in order. Any 2xx means delivered. Anything else, or a network failure, is
// logged and the record dropped; the collector sees the gap in the sequence.
// Every request has a deadline that aborts it, connecting included, and
// shutdown has one too, so nothing here can hold the server up. Nothing here
// throws or leaves an error unhandled, since an uncaught error stops the
// atServer.
final class AtServerTelemetryHttpExporter
    implements AtTelemetryLogRecordExporter {
  static const String logsPath = '/v1/logs';
  static const Duration defaultRequestTimeout = Duration(seconds: 10);
  static const Duration defaultShutdownTimeout = Duration(seconds: 10);

  final AtSignLogger _logger = AtSignLogger('AtServerTelemetryHttpExporter');
  final Uri endpoint;
  final String audience;
  final String producer;
  final String bootId;
  final AtServerTelemetrySigningKey _key;
  final http.Client _client;
  final bool _ownsClient;
  final Duration _requestTimeout;
  final Duration _shutdownTimeout;
  final Completer<void> _abortAll = Completer<void>();
  Future<void> _sending = Future<void>.value();
  Future<void>? _shutdown;
  int _nextNumber = 0;
  bool _closed = false;

  AtServerTelemetryHttpExporter({
    required Uri endpoint,
    required this.producer,
    required this.bootId,
    required AtServerTelemetrySigningKey key,
    http.Client? client,
    Duration requestTimeout = defaultRequestTimeout,
    Duration shutdownTimeout = defaultShutdownTimeout,
  })  : endpoint = logsEndpointFor(endpoint),
        audience = endpoint.host,
        _key = key,
        // The request deadline cannot abort a connect, so the client's own
        // connection timeout bounds it
        _client = client ??
            IOClient(HttpClient()..connectionTimeout = requestTimeout),
        _ownsClient = client == null,
        _requestTimeout = requestTimeout,
        _shutdownTimeout = shutdownTimeout {
    if (requestTimeout <= Duration.zero || shutdownTimeout <= Duration.zero) {
      throw ArgumentError('Timeouts must be positive');
    }
  }

  static Uri logsEndpointFor(Uri endpoint) {
    if (!endpoint.hasAuthority ||
        endpoint.host.isEmpty ||
        (endpoint.scheme != 'http' && endpoint.scheme != 'https') ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        (endpoint.path.isNotEmpty &&
            endpoint.path != '/' &&
            endpoint.path != logsPath)) {
      throw ArgumentError.value(endpoint, 'endpoint', 'invalid OTLP endpoint');
    }
    return endpoint.replace(path: logsPath);
  }

  @override
  Future<bool> export(
    AtTelemetryLogRecord logRecord,
    AtTelemetryResource resource,
  ) {
    if (_closed) {
      return Future<bool>.value(false);
    }
    final AtTelemetrySequence sequence =
        AtTelemetrySequence(bootId: bootId, number: _nextNumber++);
    final Future<bool> delivery =
        _sending.then((void _) => _send(logRecord, resource, sequence));
    // Never holds an error, so one failed send cannot stop the next
    _sending = delivery.then((bool _) {}, onError: (Object _) {});
    return delivery;
  }

  // Waits for every request already started
  @override
  Future<void> flush() => _sending;

  @override
  Future<void> shutdown() => _shutdown ??= _shutdownOnce();

  Future<void> _shutdownOnce() async {
    _closed = true;
    try {
      await flush().timeout(_shutdownTimeout);
    } on TimeoutException {
      _logger.warning('Telemetry shutdown timed out after $_shutdownTimeout; '
          'abandoning what is still being sent');
    }
    if (!_abortAll.isCompleted) {
      _abortAll.complete();
    }
    if (_ownsClient) {
      _client.close();
    }
  }

  Future<bool> _send(
    AtTelemetryLogRecord logRecord,
    AtTelemetryResource resource,
    AtTelemetrySequence sequence,
  ) async {
    try {
      return await _sendOrThrow(logRecord, resource, sequence);
    } on Object catch (error) {
      _logger.warning('Dropped telemetry $sequence: $error');
      return false;
    }
  }

  Future<bool> _sendOrThrow(
    AtTelemetryLogRecord logRecord,
    AtTelemetryResource resource,
    AtTelemetrySequence sequence,
  ) async {
    if (_abortAll.isCompleted) {
      return false;
    }

    final List<int> body;
    final AtTelemetryHttpSignature signature;
    try {
      body = utf8.encode(const AtTelemetryLogsCodec().encodeExportRequest(
          <AtTelemetryLogRecord>[logRecord],
          resource: resource));
      signature = await AtTelemetryHttpSignature.sign(
        body: body,
        path: logsPath,
        keyId: _key.keyId,
        audience: audience,
        producer: producer,
        sequence: sequence,
        signer: _key.signer,
      );
    } on Object catch (error) {
      _logger.warning('Dropped telemetry $sequence that could not be '
          'encoded or signed: $error');
      return false;
    }

    final Completer<void> abort = Completer<void>();
    final Timer deadline = Timer(_requestTimeout, () {
      if (!abort.isCompleted) {
        abort.complete();
      }
    });
    unawaited(_abortAll.future.then((void _) {
      if (!abort.isCompleted) {
        abort.complete();
      }
    }));

    final http.AbortableRequest request = http.AbortableRequest(
      'POST',
      endpoint,
      abortTrigger: abort.future,
    )
      ..headers.addAll(signature.headers)
      ..bodyBytes = body;

    try {
      final http.StreamedResponse response = await _client.send(request);
      // Drained so the connection can be reused; aborts with the request
      await response.stream.drain<void>();
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return true;
      }
      _logger.warning('Collector answered ${response.statusCode} for '
          'telemetry $sequence; dropping it');
      return false;
    } on http.RequestAbortedException {
      _logger.warning('Telemetry $sequence timed out after $_requestTimeout; '
          'dropping it');
      return false;
    } on Object catch (error) {
      _logger.warning('Telemetry $sequence not sent: ${error.runtimeType}; '
          'dropping it');
      return false;
    } finally {
      deadline.cancel();
    }
  }
}
