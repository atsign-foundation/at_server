import 'dart:async';
import 'dart:io';

import 'package:at_telemetry/at_telemetry.dart';
import 'package:at_telemetry/at_telemetry_otel.dart';
import 'package:at_utils/at_logger.dart';
import 'package:sqlite3/sqlite3.dart';

import 'at_server_telemetry_configuration.dart';
import 'at_server_telemetry_disk_exporter.dart';
import 'at_server_telemetry_event_names.dart';

final class AtServerTelemetry {
  // constants
  static const String serverIdAttribute = 'atsign.atserver.id';
  static const int defaultMaxPendingEvents = 1000;

  final int maxPendingEvents; // the amount of events we'll hold in disk
  final AtSignLogger _logger = AtSignLogger('AtServerTelemetry');
  final List<Future<void>> _pending =
      <Future<void>>[]; // holds pending telemetry waiting to be pushed
  AtTelemetryExporter? _exporter; // handles exporting of telemetry
  String? _serverId; // the Atsign that the atServer claims to be

  bool get isEnabled => _exporter != null;
  String? get serverId => _serverId;

  AtServerTelemetry({
    this.maxPendingEvents = defaultMaxPendingEvents,
  }) {
    if (maxPendingEvents < 1) {
      throw ArgumentError.value(
        maxPendingEvents,
        'maxPendingEvents',
        'must be at least one',
      );
    }
  }

  void enable({
    required AtTelemetryExporter exporter,
    required String serverId,
  }) {
    if (_exporter != null) {
      throw StateError('Telemetry is already enabled');
    }
    _exporter = exporter;
    _serverId = serverId;
  }

  void push(String name, {Map<String, Object?> attributes = const {}}) {
    final AtTelemetryExporter? exporter = _exporter;
    if (exporter == null) {
      return;
    }
    if (name.trim().isEmpty) {
      _logger.warning('Ignoring telemetry event with an empty name');
      return;
    }
    if (!name.startsWith(atServerTelemetryEventPrefix) ||
        name.length == atServerTelemetryEventPrefix.length ||
        name.trim() != name) {
      _logger
          .warning('Ignoring telemetry event outside the atServer namespace');
      return;
    }
    if (_pending.length >= maxPendingEvents &&
        !(exporter is AtServerTelemetryDiskExporter &&
            !exporter.isDirectExport)) {
      _logger.warning('Telemetry backlog full, dropping event');
      return;
    }

    final AtTelemetryEvent event = AtTelemetryEvent(
      name: name,
      timestamp: DateTime.now().toUtc(),
      attributes: Map<String, Object?>.unmodifiable(<String, Object?>{
        ...attributes,
        serverIdAttribute: _serverId,
      }),
    );
    final Future<void> export = _export(exporter, event);
    _pending.add(export);
    unawaited(export.whenComplete(() => _pending.remove(export)));
  }

  Future<void> flush({Duration? timeout}) async {
    final AtTelemetryExporter? exporter = _exporter;
    if (exporter == null) {
      return;
    }
    await _bounded(_drain(exporter), timeout, 'flush');
  }

  Future<void> shutdown({Duration? timeout}) async {
    final AtTelemetryExporter? exporter = _exporter;
    if (exporter == null) {
      return;
    }
    _exporter = null;
    _serverId = null;
    await _bounded(
      _drain(exporter).then((void _) => _guard(exporter.shutdown, 'shutdown')),
      timeout,
      'shutdown',
    );
  }

  Future<void> _drain(AtTelemetryExporter exporter) async {
    await Future.wait(_pending.toList());
    await _guard(exporter.flush, 'flush');
  }

  Future<void> _bounded(
    Future<void> work,
    Duration? timeout,
    String operation,
  ) async {
    if (timeout == null) {
      return work;
    }
    try {
      await work.timeout(timeout);
    } on TimeoutException {
      _logger.warning('Telemetry $operation timed out after $timeout');
    }
  }

  Future<void> _guard(Future<void> Function() action, String operation) async {
    try {
      await action();
    } catch (error) {
      _logger.warning('Telemetry $operation failed: ${error.runtimeType}');
    }
  }

  Future<void> _export(
    AtTelemetryExporter exporter,
    AtTelemetryEvent event,
  ) {
    return _guard(() => exporter.export(event), 'export');
  }
}

Future<AtTelemetryExporter?> createAtServerTelemetryExporter({
  required String serverId,
  required String signingKey,
  Map<Object?, Object?>? yaml,
  Map<String, String>? environment,
}) async {
  final AtSignLogger logger = AtSignLogger('AtServerTelemetry');

  // Set up AtServerTelemetryConfiguration
  final AtServerTelemetryConfiguration? configuration;
  try {
    configuration = AtServerTelemetryConfiguration.load(
      yaml: yaml,
      environment: environment,
    );
  } on FormatException catch (error) {
    logger.warning('Not pushing telemetry anywhere: ${error.message}');
    return null;
  }
  if (configuration == null) {
    logger.warning(
        'Not pushing telemetry anywhere: no telemetry endpoint is configured');
    return null;
  }

  // Require signingKey
  if (signingKey.isEmpty) {
    logger
        .warning('Not pushing telemetry anywhere: signing key is empty String');
    return null;
  }

  final Uri endpoint = configuration.endpoint;
  final String destination = endpoint.origin;
  try {
    final AtTelemetryRsaSigner signer =
        AtTelemetryRsaSigner.fromBase64(signingKey);
    void onError(Object error) =>
        logger.warning('Telemetry export failed: ${error.runtimeType}');
    AtTelemetryExporter direct() => AtTelemetrySignedHttpExporter(
          endpoint: endpoint,
          serviceName: 'at_secondary_server',
          keyId: serverId,
          audience: endpoint.host,
          signer: signer,
          onError: onError,
        );

    if (!configuration.persistToDisk) {
      logger.info('Pushing signed telemetry directly to $destination');
      return direct();
    }
    try {
      final AtTelemetryExporter exporter = AtServerTelemetryDiskExporter.open(
        endpoint: endpoint,
        keyId: serverId,
        audience: endpoint.host,
        signer: signer,
        storagePath: configuration.storagePath,
        maxRecords: configuration.maxRecords,
        maxBytes: configuration.maxBytes,
        onError: onError,
      );
      logger.info('Pushing persisted signed telemetry to $destination');
      return exporter;
    } on FileSystemException catch (error) {
      logger.warning('Telemetry disk unavailable: ${error.runtimeType}; '
          'switching to direct signed export');
      return direct();
    } on SqliteException catch (error) {
      logger.warning('Telemetry disk unavailable: ${error.runtimeType}; '
          'switching to direct signed export');
      return direct();
    }
  } catch (error) {
    logger.warning(
        'Not pushing telemetry anywhere: exporter setup failed: ${error.runtimeType}');
    return null;
  }
}
