import 'dart:async';
import 'dart:io';

import 'package:at_telemetry/at_telemetry.dart';
import 'package:at_telemetry/at_telemetry_otel.dart';

final class AtServerHeartbeatConfiguration {
  static const Duration heartbeatInterval = Duration(seconds: 60);

  final Uri endpoint;
  final String apiKey;

  const AtServerHeartbeatConfiguration({
    required this.endpoint,
    required this.apiKey,
  });

  static AtServerHeartbeatConfiguration? fromEnvironment([
    Map<String, String>? environment,
  ]) {
    final Map<String, String> values = environment ?? Platform.environment;
    final String? endpointValue = _nonEmpty(
      values['AT_TELEMETRY_ENDPOINT'],
    );
    final String? apiKey = _nonEmpty(values['AT_TELEMETRY_API_KEY']);

    if (endpointValue == null && apiKey == null) {
      return null;
    }
    if (endpointValue == null) {
      throw const FormatException('AT_TELEMETRY_ENDPOINT is required');
    }
    if (apiKey == null) {
      throw const FormatException('AT_TELEMETRY_API_KEY is required');
    }

    final Uri endpoint = Uri.parse(endpointValue);
    if (!endpoint.hasAuthority ||
        (endpoint.scheme != 'http' && endpoint.scheme != 'https')) {
      throw const FormatException(
        'AT_TELEMETRY_ENDPOINT must be an HTTP or HTTPS URL',
      );
    }

    return AtServerHeartbeatConfiguration(
      endpoint: endpoint,
      apiKey: apiKey,
    );
  }

  static String? _nonEmpty(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return value.trim();
  }
}

final class AtServerHeartbeat {
  AtServerHeartbeat({
    required AtTelemetryExporter telemetryExporter,
    required this.serverId,
  }) : _telemetryExporter = telemetryExporter;

  final AtTelemetryExporter _telemetryExporter;
  final String serverId;

  Future<void> send() {
    return _telemetryExporter.export(
      AtTelemetryEvent(
        name: 'atsign.server.heartbeat',
        timestamp: DateTime.now().toUtc(),
        attributes: <String, Object?>{
          'atsign.server.id': serverId,
        },
      ),
    );
  }
}

final class AtServerHeartbeatScheduler {
  final AtServerHeartbeat _heartbeat;
  final Duration _interval;
  Timer? _timer;

  AtServerHeartbeatScheduler({
    required AtServerHeartbeat heartbeat,
    required Duration interval,
  })  : _heartbeat = heartbeat,
        _interval = interval {
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval', 'must be positive');
    }
  }

  bool get isRunning => _timer != null;

  Future<void> start() async {
    if (_timer != null) {
      return;
    }
    await _heartbeat.send();
    _timer = Timer.periodic(_interval, (_) {
      unawaited(_heartbeat.send());
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

Future<AtServerHeartbeatScheduler?> startAtServerHeartbeat({
  required String serverId,
  Map<String, String>? environment,
}) async {
  final AtServerHeartbeatConfiguration? configuration =
      AtServerHeartbeatConfiguration.fromEnvironment(environment);
  if (configuration == null) {
    return null;
  }

  final AtTelemetryExporterOtelHttp exporter =
      await AtTelemetryExporterOtelHttp.create(
    endpoint: configuration.endpoint,
    serviceName: 'at_secondary_server',
    apiKey: configuration.apiKey,
  );
  final AtServerHeartbeatScheduler scheduler = AtServerHeartbeatScheduler(
    heartbeat: AtServerHeartbeat(
      telemetryExporter: exporter,
      serverId: serverId,
    ),
    interval: AtServerHeartbeatConfiguration.heartbeatInterval,
  );
  await scheduler.start();
  return scheduler;
}
