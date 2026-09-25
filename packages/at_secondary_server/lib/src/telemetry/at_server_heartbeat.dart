import 'dart:async';
import 'dart:io';
import 'dart:math';

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
  // minimum that the interval can be set to
  static const Duration _minimumInterval = Duration(milliseconds: 1);

  final AtServerHeartbeat _heartbeat;
  final Duration interval;
  final Duration offset;
  final DateTime Function() _now;
  Timer? _timer;
  DateTime? _previousSlot;

  AtServerHeartbeatScheduler({
    required AtServerHeartbeat heartbeat,
    this.interval = AtServerHeartbeatConfiguration.heartbeatInterval,
    Duration? offset,
    Random? random,
    DateTime Function()? now,
  })  : _heartbeat = heartbeat,
        offset = offset ?? randomOffset(interval, random ?? Random.secure()),
        _now = now ?? DateTime.now {
    _requireInterval(interval);
    if (this.offset < Duration.zero || this.offset >= interval) {
      throw ArgumentError.value(
        this.offset,
        'offset',
        'must be at least zero and less than interval',
      );
    }
  }

  static Duration randomOffset(Duration interval, Random random) {
    _requireInterval(interval);
    return Duration(milliseconds: random.nextInt(interval.inMilliseconds));
  }

  static void _requireInterval(Duration interval) {
    if (interval < _minimumInterval) {
      throw ArgumentError.value(
        interval,
        'interval',
        'must be at least one millisecond',
      );
    }
  }

  bool get isRunning => _timer != null;

  DateTime nextSlot({required DateTime now, DateTime? previousSlot}) {
    final int intervalMicroseconds = interval.inMicroseconds;
    final int nowMicroseconds = now.microsecondsSinceEpoch;
    int slotMicroseconds = nowMicroseconds -
        nowMicroseconds % intervalMicroseconds +
        offset.inMicroseconds;
    if (slotMicroseconds <= nowMicroseconds) {
      slotMicroseconds += intervalMicroseconds;
    }

    final DateTime slot = DateTime.fromMicrosecondsSinceEpoch(
      slotMicroseconds,
      isUtc: true,
    );
    if (previousSlot != null && slot.isAtSameMomentAs(previousSlot)) {
      return slot.add(interval);
    }
    return slot;
  }

  void start() {
    if (_timer == null) {
      _scheduleNext();
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _scheduleNext() {
    final DateTime now = _now().toUtc();
    final DateTime slot = nextSlot(now: now, previousSlot: _previousSlot);
    _timer = Timer(slot.difference(now), () {
      _previousSlot = slot;
      _scheduleNext();
      unawaited(_heartbeat.send());
    });
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
  );
  scheduler.start();
  return scheduler;
}
