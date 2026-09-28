import 'dart:async';
import 'dart:io';

import 'package:at_commons/at_commons.dart' show InvalidAtSignException;
import 'package:at_telemetry/at_telemetry.dart';
import 'package:at_telemetry/at_telemetry_otel.dart';
import 'package:at_utils/at_logger.dart';
import 'package:at_utils/at_utils.dart' show AtUtils;

final class AtServerTelemetryConfiguration {
  final Uri endpoint;
  final String? collectorAtsign;
  final String? apiKey;

  const AtServerTelemetryConfiguration({
    required this.endpoint,
    this.collectorAtsign,
    this.apiKey,
  });

  static AtServerTelemetryConfiguration? fromEnvironment([
    Map<String, String>? environment,
  ]) {
    final Map<String, String> values = environment ?? Platform.environment;
    final String? endpointValue = _nonEmpty(
      values['AT_TELEMETRY_ENDPOINT'],
    );
    final String? apiKey = _nonEmpty(values['AT_TELEMETRY_API_KEY']);
    final String? collectorAtsign =
        _nonEmpty(values['AT_TELEMETRY_COLLECTOR_ATSIGN']);

    if (endpointValue == null && apiKey == null && collectorAtsign == null) {
      return null;
    }
    if (endpointValue == null) {
      throw const FormatException('AT_TELEMETRY_ENDPOINT is required');
    }
    if (collectorAtsign == null && apiKey == null) {
      throw const FormatException(
        'AT_TELEMETRY_API_KEY or AT_TELEMETRY_COLLECTOR_ATSIGN is required',
      );
    }
    if (collectorAtsign != null) {
      if (!collectorAtsign.startsWith('@')) {
        throw const FormatException('Invalid collector Atsign');
      }
      try {
        if (AtUtils.fixAtSign(collectorAtsign) != collectorAtsign) {
          throw const FormatException('Collector Atsign must be canonical');
        }
      } on InvalidAtSignException {
        throw const FormatException('Invalid collector Atsign');
      }
    }

    final Uri endpoint = Uri.parse(endpointValue);
    if (!endpoint.hasAuthority ||
        (endpoint.scheme != 'http' && endpoint.scheme != 'https')) {
      throw const FormatException(
        'AT_TELEMETRY_ENDPOINT must be an HTTP or HTTPS URL',
      );
    }

    return AtServerTelemetryConfiguration(
      endpoint: endpoint,
      apiKey: apiKey,
      collectorAtsign: collectorAtsign,
    );
  }

  static String? _nonEmpty(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return value.trim();
  }
}

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
  Map<String, String>? environment,
}) async {
  final AtServerTelemetryConfiguration? configuration =
      AtServerTelemetryConfiguration.fromEnvironment(environment);
  if (configuration == null) {
    return null;
  }

  if (configuration.collectorAtsign case final String audience) {
    if (signingKey == null || signingKey.isEmpty) {
      AtSignLogger('AtServerTelemetry')
          .warning('Signing key unavailable, disabling signed telemetry');
      return null;
    }
    return AtTelemetrySignedHttpExporter(
      endpoint: configuration.endpoint,
      serviceName: 'at_secondary_server',
      keyId: serverId,
      audience: audience,
      signer: AtTelemetryRsaSigner.fromBase64(signingKey),
      apiKey: configuration.apiKey,
      onError: (Object error) => AtSignLogger('AtServerTelemetry')
          .warning('Telemetry export failed: ${error.runtimeType}'),
    );
  }
  return AtTelemetryExporterOtelHttp.create(
    endpoint: configuration.endpoint,
    serviceName: 'at_secondary_server',
    apiKey: configuration.apiKey,
  );
}
