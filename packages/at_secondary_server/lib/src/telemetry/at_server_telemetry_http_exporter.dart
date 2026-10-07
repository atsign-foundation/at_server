import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:at_telemetry/at_telemetry.dart';
import 'package:at_utils/at_logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'at_server_telemetry_batch.dart';
import 'at_server_telemetry_delivery_outcome.dart';
import 'at_server_telemetry_outbox.dart';
import 'at_server_telemetry_signing_key.dart';

// Sends the atServer's telemetry to its collector as signed OTLP/JSON over
// HTTPS. Records are batched, each closed batch is persisted to the outbox
// with the next sequence number, and the outbox is drained one request at a
// time, oldest first. Any 2xx removes the batch. 400, 401, 403, 404, 413,
// 415 and other 4xx drop it, since sending it again would fail the same way.
// 408, 429, 5xx and network failures keep it and back off. Every request has
// a deadline that aborts it, connecting included, and shutdown has one too,
// so nothing here can hold the server up. Nothing here throws or leaves an
// error unhandled, since an uncaught error stops the atServer.
final class AtServerTelemetryHttpExporter
    implements AtTelemetryLogRecordExporter {
  static const String logsPath = '/v1/logs';
  static const int defaultMaxBatchRecords = 100;
  static const Duration defaultFlushInterval = Duration(seconds: 5);
  static const Duration defaultRequestTimeout = Duration(seconds: 10);
  static const Duration defaultInitialBackoff = Duration(seconds: 1);
  static const Duration defaultMaxBackoff = Duration(minutes: 5);
  static const Duration defaultShutdownTimeout = Duration(seconds: 10);
  static const int maxBatchBytes = 1024 * 1024;

  final AtSignLogger _logger = AtSignLogger('AtServerTelemetryHttpExporter');
  final Uri endpoint;
  final String audience;
  final String producer;
  final AtServerTelemetrySigningKey _key;
  final AtServerTelemetryOutbox _outbox;
  final http.Client _client;
  final bool _ownsClient;
  final int _maxBatchRecords;
  final Duration _flushInterval;
  final Duration _requestTimeout;
  final Duration _initialBackoff;
  final Duration _maxBackoff;
  final Duration _shutdownTimeout;
  final Random _random;
  final List<AtTelemetryLogRecord> _records = <AtTelemetryLogRecord>[];
  final List<Completer<bool>> _deliveries = <Completer<bool>>[];
  final Completer<void> _abortAll = Completer<void>();
  AtTelemetryResource? _resource;
  Future<void> _persisting = Future<void>.value();
  Future<void>? _sending;
  Future<void>? _shutdown;
  Timer? _batchTimer;
  Timer? _retryTimer;
  DateTime? _retryAt;
  Duration _backoff;
  bool _closed = false;

  AtServerTelemetryHttpExporter({
    required Uri endpoint,
    required this.producer,
    required AtServerTelemetrySigningKey key,
    required AtServerTelemetryOutbox outbox,
    http.Client? client,
    int maxBatchRecords = defaultMaxBatchRecords,
    Duration flushInterval = defaultFlushInterval,
    Duration requestTimeout = defaultRequestTimeout,
    Duration initialBackoff = defaultInitialBackoff,
    Duration maxBackoff = defaultMaxBackoff,
    Duration shutdownTimeout = defaultShutdownTimeout,
    Random? random,
  })  : endpoint = logsEndpointFor(endpoint),
        audience = endpoint.host,
        _key = key,
        _outbox = outbox,
        // The request deadline cannot abort a connect, so the client's own
        // connection timeout bounds it
        _client = client ??
            IOClient(HttpClient()..connectionTimeout = requestTimeout),
        _ownsClient = client == null,
        _maxBatchRecords = maxBatchRecords,
        _flushInterval = flushInterval,
        _requestTimeout = requestTimeout,
        _initialBackoff = initialBackoff,
        _maxBackoff = maxBackoff,
        _shutdownTimeout = shutdownTimeout,
        _random = random ?? Random(),
        _backoff = initialBackoff {
    if (maxBatchRecords < 1) {
      throw RangeError.value(maxBatchRecords, 'maxBatchRecords');
    }
    if (flushInterval <= Duration.zero ||
        requestTimeout <= Duration.zero ||
        initialBackoff <= Duration.zero ||
        maxBackoff < initialBackoff ||
        shutdownTimeout <= Duration.zero) {
      throw ArgumentError('Intervals, timeouts and backoffs must be positive');
    }
    // Batches left by an earlier boot go first
    if (_outbox.batchCount > 0) {
      unawaited(_send());
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

  Map<String, Object?> get outboxHealth => _outbox.health;

  @override
  Future<bool> export(
    AtTelemetryLogRecord logRecord,
    AtTelemetryResource resource,
  ) {
    if (_closed) {
      return Future<bool>.value(false);
    }
    if (_resource != null && !identical(_resource, resource)) {
      _closeBatch();
    }
    _resource = resource;

    final Completer<bool> delivery = Completer<bool>();
    _records.add(logRecord);
    _deliveries.add(delivery);
    if (_records.length >= _maxBatchRecords) {
      _closeBatch();
    } else {
      _batchTimer ??= Timer(_flushInterval, _closeBatch);
    }
    return delivery.future;
  }

  // Persists what is batched and makes one pass over the outbox, ignoring
  // any backoff in force
  @override
  Future<void> flush() async {
    _closeBatch();
    await _persisting;
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAt = null;
    await _send();
  }

  // Batches still in the outbox stay there for the next boot
  @override
  Future<void> shutdown() => _shutdown ??= _shutdownOnce();

  Future<void> _shutdownOnce() async {
    _closed = true;
    try {
      await flush().timeout(_shutdownTimeout);
    } on TimeoutException {
      _logger.warning('Telemetry shutdown timed out after $_shutdownTimeout; '
          '${_outbox.batchCount} batches stay in the outbox');
    } on Object catch (error) {
      _logger.warning('Telemetry shutdown failed: $error');
    }
    _batchTimer?.cancel();
    _retryTimer?.cancel();
    if (!_abortAll.isCompleted) {
      _abortAll.complete();
    }
    if (_ownsClient) {
      _client.close();
    }
  }

  void _closeBatch() {
    _batchTimer?.cancel();
    _batchTimer = null;
    final AtTelemetryResource? resource = _resource;
    if (_records.isEmpty || resource == null) {
      return;
    }
    final List<AtTelemetryLogRecord> records =
        List<AtTelemetryLogRecord>.of(_records);
    final List<Completer<bool>> deliveries =
        List<Completer<bool>>.of(_deliveries);
    _records.clear();
    _deliveries.clear();
    _persisting = _persisting.then(
      (void _) => _persist(records, deliveries, resource),
    );
    unawaited(_persisting.then((void _) {
      if (_retryAt == null) {
        return _send();
      }
    }));
  }

  // Each record learns its outcome once it is on disk, or dropped. Never
  // fails, so the persisting chain never holds an error.
  Future<void> _persist(
    List<AtTelemetryLogRecord> records,
    List<Completer<bool>> deliveries,
    AtTelemetryResource resource,
  ) async {
    try {
      await _persistOrThrow(records, deliveries, resource);
    } on Object catch (error) {
      _logger.warning('Dropped ${records.length} telemetry records: $error');
      _complete(deliveries, false);
    }
  }

  Future<void> _persistOrThrow(
    List<AtTelemetryLogRecord> records,
    List<Completer<bool>> deliveries,
    AtTelemetryResource resource,
  ) async {
    final String body;
    try {
      body = const AtTelemetryLogsCodec()
          .encodeExportRequest(records, resource: resource);
    } on Object catch (error) {
      _logger.warning('Dropped ${records.length} telemetry records that '
          'could not be encoded: $error');
      _complete(deliveries, false);
      return;
    }

    if (utf8.encode(body).length > maxBatchBytes) {
      if (records.length == 1) {
        _logger.warning('Dropped a telemetry record larger than '
            '$maxBatchBytes bytes');
        _complete(deliveries, false);
        return;
      }
      final int half = records.length ~/ 2;
      await _persist(
          records.sublist(0, half), deliveries.sublist(0, half), resource);
      await _persist(records.sublist(half), deliveries.sublist(half), resource);
      return;
    }

    try {
      await _outbox.add(body);
      _complete(deliveries, true);
    } on Object catch (error) {
      _logger.warning('Dropped ${records.length} telemetry records the '
          'outbox could not store: $error');
      _complete(deliveries, false);
    }
  }

  void _complete(List<Completer<bool>> deliveries, bool outcome) {
    for (final Completer<bool> delivery in deliveries) {
      if (!delivery.isCompleted) {
        delivery.complete(outcome);
      }
    }
  }

  Future<void> _send() {
    return _sending ??= _drain().whenComplete(() => _sending = null);
  }

  // Never fails, so neither the send chain nor anything awaiting it holds an
  // error
  Future<void> _drain() async {
    try {
      while (!_abortAll.isCompleted) {
        final AtServerTelemetryBatch? batch = _outbox.oldest;
        if (batch == null) {
          return;
        }
        final AtServerTelemetryDeliveryOutcome outcome = await _post(batch);
        switch (outcome) {
          case AtServerTelemetryDeliveryOutcome.delivered:
            _backoff = _initialBackoff;
            await _outbox.remove(batch);
          case AtServerTelemetryDeliveryOutcome.rejected:
            await _outbox.remove(batch);
          case AtServerTelemetryDeliveryOutcome.retry:
            _scheduleRetry();
            return;
        }
      }
    } on Object catch (error) {
      _logger.warning('Telemetry sending failed: $error; will retry');
      _scheduleRetry();
    }
  }

  Future<AtServerTelemetryDeliveryOutcome> _post(
      AtServerTelemetryBatch batch) async {
    final Completer<void> abort = Completer<void>();
    final http.AbortableRequest request;
    try {
      final AtTelemetryHttpSignature signature =
          await AtTelemetryHttpSignature.sign(
        body: batch.body,
        path: logsPath,
        keyId: _key.keyId,
        audience: audience,
        producer: producer,
        sequence: batch.sequence,
        signer: _key.signer,
      );
      request = http.AbortableRequest(
        'POST',
        endpoint,
        abortTrigger: abort.future,
      )
        ..headers.addAll(signature.headers)
        ..bodyBytes = batch.body;
    } on Object catch (error) {
      _logger.warning('Dropped telemetry batch ${batch.sequence} that could '
          'not be signed: $error');
      return AtServerTelemetryDeliveryOutcome.rejected;
    }

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

    try {
      final http.StreamedResponse response = await _client.send(request);
      // Drained so the connection can be reused; aborts with the request
      await response.stream.drain<void>();
      return _classify(response.statusCode, batch);
    } on http.RequestAbortedException {
      _logger.info('Telemetry batch ${batch.sequence} timed out after '
          '$_requestTimeout; will retry');
      return AtServerTelemetryDeliveryOutcome.retry;
    } on Object catch (error) {
      _logger.info('Telemetry batch ${batch.sequence} not sent: '
          '${error.runtimeType}; will retry');
      return AtServerTelemetryDeliveryOutcome.retry;
    } finally {
      deadline.cancel();
    }
  }

  AtServerTelemetryDeliveryOutcome _classify(
      int status, AtServerTelemetryBatch batch) {
    if (status >= 200 && status < 300) {
      return AtServerTelemetryDeliveryOutcome.delivered;
    }
    if (status == 408 || status == 429 || status >= 500) {
      _logger.info('Collector answered $status for telemetry batch '
          '${batch.sequence}; will retry');
      return AtServerTelemetryDeliveryOutcome.retry;
    }
    _logger.warning('Collector rejected telemetry batch ${batch.sequence} '
        'with $status; dropping it');
    return AtServerTelemetryDeliveryOutcome.rejected;
  }

  // Capped exponential backoff with full jitter
  void _scheduleRetry() {
    if (_closed) {
      return;
    }
    // Random.nextInt takes at most 2^32
    final Duration delay = Duration(
      microseconds:
          _random.nextInt(min(max(_backoff.inMicroseconds, 1), 1 << 32)) + 1,
    );
    final Duration doubled = _backoff * 2;
    _backoff = doubled > _maxBackoff ? _maxBackoff : doubled;
    _retryAt = DateTime.now().add(delay);
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      _retryAt = null;
      unawaited(_send());
    });
  }
}
