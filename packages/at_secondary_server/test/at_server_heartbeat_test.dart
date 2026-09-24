import 'package:at_secondary/src/telemetry/at_server_heartbeat.dart';
import 'package:at_telemetry/at_telemetry.dart';
import 'package:test/test.dart';

void main() {
  group('AtServerHeartbeatConfiguration', () {
    test('is disabled when telemetry environment variables are absent', () {
      expect(
        AtServerHeartbeatConfiguration.fromEnvironment(<String, String>{}),
        isNull,
      );
    });

    test('uses the configured endpoint and API key', () {
      final AtServerHeartbeatConfiguration configuration =
          AtServerHeartbeatConfiguration.fromEnvironment(<String, String>{
        'AT_TELEMETRY_ENDPOINT': 'http://host.docker.internal:4318',
        'AT_TELEMETRY_API_KEY': 'secret',
      })!;

      expect(
        configuration.endpoint,
        Uri.parse('http://host.docker.internal:4318'),
      );
      expect(configuration.apiKey, 'secret');
      expect(
        AtServerHeartbeatConfiguration.heartbeatInterval,
        const Duration(seconds: 60),
      );
    });

    test('rejects partial and invalid configurations', () {
      expect(
        () => AtServerHeartbeatConfiguration.fromEnvironment(<String, String>{
          'AT_TELEMETRY_ENDPOINT': 'http://localhost:4318',
        }),
        throwsFormatException,
      );
      expect(
        () => AtServerHeartbeatConfiguration.fromEnvironment(<String, String>{
          'AT_TELEMETRY_API_KEY': 'secret',
        }),
        throwsFormatException,
      );
      expect(
        () => AtServerHeartbeatConfiguration.fromEnvironment(<String, String>{
          'AT_TELEMETRY_ENDPOINT': 'localhost:4318',
          'AT_TELEMETRY_API_KEY': 'secret',
        }),
        throwsFormatException,
      );
    });
  });

  test('heartbeat uses the current server Atsign as its server ID', () async {
    final _RecordingExporter exporter = _RecordingExporter();
    final AtServerHeartbeat heartbeat = AtServerHeartbeat(
      telemetryExporter: exporter,
      serverId: '@denise',
    );

    await heartbeat.send();

    expect(exporter.events, hasLength(1));
    expect(exporter.events.single.name, 'atsign.server.heartbeat');
    expect(exporter.events.single.attributes, <String, Object?>{
      'atsign.server.id': '@denise',
    });
  });

  test('scheduler sends immediately and starts its timer', () async {
    final _RecordingExporter exporter = _RecordingExporter();
    final AtServerHeartbeatScheduler scheduler = AtServerHeartbeatScheduler(
      heartbeat: AtServerHeartbeat(
        telemetryExporter: exporter,
        serverId: '@denise',
      ),
      interval: const Duration(hours: 1),
    );
    addTearDown(scheduler.stop);

    await scheduler.start();

    expect(scheduler.isRunning, isTrue);
    expect(exporter.events, hasLength(1));
  });
}

final class _RecordingExporter implements AtTelemetryExporter {
  final List<AtTelemetryEvent> events = <AtTelemetryEvent>[];

  @override
  Future<void> export(AtTelemetryEvent event) async {
    events.add(event);
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> shutdown() async {}
}
