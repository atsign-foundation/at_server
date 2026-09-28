import 'dart:async';

import 'package:at_telemetry/at_telemetry.dart';
import 'package:at_telemetry/at_telemetry_otel.dart';
import 'package:at_utils/at_logger.dart';

import 'at_server_telemetry_configuration.dart';
import 'at_server_telemetry_disk_exporter.dart';

final class AtServerTelemetry {
  static const String serverIdAttribute = 'atsign.server.id';
  static const int defaultMaxPendingEvents = 1000;

  final int maxPendingEvents;
  final DateTime Function() _now;
  final AtSignLogger _logger = AtSignLogger('AtServerTelemetry');
  final Set<Future<void>> _pending = <Future<void>>{};
  AtTelemetryExporter? _exporter;
  String? _serverId;
  bool _isDropping = false;

  AtServerTelemetry({
    this.maxPendingEvents = defaultMaxPendingEvents,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    if (maxPendingEvents < 1) {
      throw ArgumentError.value(
        maxPendingEvents,
        'maxPendingEvents',
        'must be at least one',
      );
    }
  }

  bool get isEnabled => _exporter != null;
  String? get serverId => _serverId;

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
    if (_pending.length >= maxPendingEvents) {
      if (!_isDropping) {
        _isDropping = true;
        _logger.warning('Telemetry backlog full, dropping events');
      }
      return;
    }
    _isDropping = false;

    final AtTelemetryEvent event = AtTelemetryEvent(
      name: name,
      timestamp: _now().toUtc(),
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
  required String? signingKey,
  Map<Object?, Object?>? yaml,
  Map<String, String>? environment,
}) async {
  final AtSignLogger logger = AtSignLogger('AtServerTelemetry');
  void disable(String reason) {
    logger.warning('Not pushing telemetry anywhere: $reason');
  }

  final AtServerTelemetryConfiguration? configuration;
  try {
    configuration = AtServerTelemetryConfiguration.load(
      yaml: yaml,
      environment: environment,
    );
  } on FormatException catch (error) {
    disable(error.message);
    return null;
  }
  if (configuration == null) {
    disable('no telemetry endpoint is configured');
    return null;
  }

  if (signingKey == null || signingKey.isEmpty) {
    disable('signing key unavailable');
    return null;
  }

  final String destination = configuration.endpoint.origin;
  try {
    final AtTelemetryExporter exporter = AtServerTelemetryDiskExporter.open(
      endpoint: configuration.endpoint,
      keyId: serverId,
      audience: configuration.endpoint.host,
      signer: AtTelemetryRsaSigner.fromBase64(signingKey),
      storagePath: configuration.storagePath,
      maxRecords: configuration.maxRecords,
      maxBytes: configuration.maxBytes,
      onError: (Object error) =>
          logger.warning('Telemetry export failed: ${error.runtimeType}'),
    );
    logger.info('Pushing signed telemetry to $destination');
    return exporter;
  } catch (error) {
    disable('exporter setup failed: ${error.runtimeType}');
    return null;
  }
}
