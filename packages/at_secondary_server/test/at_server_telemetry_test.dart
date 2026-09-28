import 'dart:async';

import 'package:at_secondary/src/telemetry/at_server_telemetry.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_configuration.dart';
import 'package:at_telemetry/at_telemetry.dart';
import 'package:at_telemetry/at_telemetry_otel.dart';
import 'package:crypton/crypton.dart';
import 'package:test/test.dart';

void main() {
  test('server-resolved at_chops signs and verifies telemetry', () async {
    final RSAKeypair keys = RSAKeypair.fromRandom();
    final AtTelemetryHttpSignature signed = await AtTelemetryHttpSignature.sign(
      body: <int>[1, 2, 3],
      path: '/v1/logs',
      keyId: '@denise',
      audience: '@telemetry1',
      signer: AtTelemetryRsaSigner.fromBase64(keys.privateKey.toString()),
    );
    expect(
        await signed.verify(
          path: '/v1/logs',
          publicKey: keys.publicKey.toString(),
        ),
        isTrue);
  });

  group('AtServerTelemetryConfiguration', () {
    test('is disabled when telemetry environment variables are absent', () {
      expect(
        AtServerTelemetryConfiguration.fromEnvironment(<String, String>{}),
        isNull,
      );
    });

    test('uses the configured endpoint, audience and optional API key', () {
      final AtServerTelemetryConfiguration configuration =
          AtServerTelemetryConfiguration.fromEnvironment(<String, String>{
        'AT_TELEMETRY_ENDPOINT': 'http://host.docker.internal:4318',
        'AT_TELEMETRY_API_KEY': 'secret',
        'AT_TELEMETRY_COLLECTOR_ATSIGN': '@telemetry1',
      })!;

      expect(
        configuration.endpoint,
        Uri.parse('http://host.docker.internal:4318'),
      );
      expect(configuration.apiKey, 'secret');
      expect(configuration.collectorAtsign, '@telemetry1');
      final AtServerTelemetryConfiguration legacy =
          AtServerTelemetryConfiguration.fromEnvironment(<String, String>{
        'AT_TELEMETRY_ENDPOINT': 'http://localhost:4318',
        'AT_TELEMETRY_API_KEY': 'secret',
      })!;
      expect(legacy.collectorAtsign, isNull);
      expect(legacy.apiKey, 'secret');
      expect(
          AtServerTelemetryConfiguration.fromEnvironment(<String, String>{
            'AT_TELEMETRY_ENDPOINT': 'http://localhost:4318',
            'AT_TELEMETRY_COLLECTOR_ATSIGN': '@telemetry1',
          })!
              .apiKey,
          isNull);
    });

    test('rejects partial and invalid configurations', () {
      expect(
        () => AtServerTelemetryConfiguration.fromEnvironment(<String, String>{
          'AT_TELEMETRY_ENDPOINT': 'http://localhost:4318',
        }),
        throwsFormatException,
      );
      expect(
        () => AtServerTelemetryConfiguration.fromEnvironment(<String, String>{
          'AT_TELEMETRY_API_KEY': 'secret',
        }),
        throwsFormatException,
      );
      expect(
        () => AtServerTelemetryConfiguration.fromEnvironment(<String, String>{
          'AT_TELEMETRY_ENDPOINT': 'http://localhost:4318',
          'AT_TELEMETRY_COLLECTOR_ATSIGN': '@Telemetry1',
        }),
        throwsFormatException,
      );
      expect(
        () => AtServerTelemetryConfiguration.fromEnvironment(<String, String>{
          'AT_TELEMETRY_ENDPOINT': 'localhost:4318',
          'AT_TELEMETRY_API_KEY': 'secret',
        }),
        throwsFormatException,
      );
    });
  });

  test('signed telemetry is disabled without the signing key', () async {
    final AtTelemetryExporter? exporter = await createAtServerTelemetryExporter(
      serverId: '@denise',
      signingKey: null,
      environment: <String, String>{
        'AT_TELEMETRY_ENDPOINT': 'http://localhost:4318',
        'AT_TELEMETRY_COLLECTOR_ATSIGN': '@telemetry1',
      },
    );

    expect(exporter, isNull);
  });

  test('telemetry is disabled when the environment is not configured',
      () async {
    final AtTelemetryExporter? exporter = await createAtServerTelemetryExporter(
      serverId: '@denise',
      signingKey: null,
      environment: <String, String>{},
    );

    expect(exporter, isNull);
  });

  group('AtServerTelemetry', () {
    test('pushes events stamped with the server ID and timestamp', () async {
      final _RecordingExporter exporter = _RecordingExporter();
      final AtServerTelemetry telemetry = AtServerTelemetry(
        now: () => DateTime.utc(2026, 9, 28, 12),
      )..enable(exporter: exporter, serverId: '@denise');

      telemetry.push(
        'atsign.server.notify',
        attributes: <String, Object?>{'atsign.notify.count': 3},
      );
      await telemetry.flush();

      expect(telemetry.isEnabled, isTrue);
      expect(exporter.events.single.name, 'atsign.server.notify');
      expect(exporter.events.single.timestamp, DateTime.utc(2026, 9, 28, 12));
      expect(exporter.events.single.attributes, <String, Object?>{
        'atsign.notify.count': 3,
        'atsign.server.id': '@denise',
      });
    });

    test('callers cannot override the server ID', () async {
      final _RecordingExporter exporter = _RecordingExporter();
      final AtServerTelemetry telemetry = _enabledTelemetry(exporter);

      telemetry.push(
        'atsign.server.op',
        attributes: <String, Object?>{'atsign.server.id': '@mallory'},
      );
      await telemetry.flush();

      expect(exporter.events.single.attributes['atsign.server.id'], '@denise');
    });

    test('drops events with an empty name', () async {
      final _RecordingExporter exporter = _RecordingExporter();
      final AtServerTelemetry telemetry = _enabledTelemetry(exporter);

      telemetry.push('  ');
      await telemetry.flush();

      expect(exporter.events, isEmpty);
    });

    test('telemetry ignores every call until enabled', () async {
      final AtServerTelemetry telemetry = AtServerTelemetry();

      telemetry.push('atsign.server.op');
      await telemetry.flush();
      await telemetry.shutdown();

      expect(telemetry.isEnabled, isFalse);
    });

    test('export failures never reach the caller', () async {
      final AtServerTelemetry telemetry =
          _enabledTelemetry(_RecordingExporter(failExports: true));

      telemetry.push('atsign.server.op');

      await expectLater(telemetry.flush(), completes);
    });

    test('flush waits for exports that are still in flight', () async {
      final Completer<void> release = Completer<void>();
      final _RecordingExporter exporter =
          _RecordingExporter(exportGate: release.future);
      final AtServerTelemetry telemetry = _enabledTelemetry(exporter);

      telemetry.push('atsign.server.op');
      bool flushed = false;
      final Future<void> flush =
          telemetry.flush().then((void _) => flushed = true);
      await Future<void>.delayed(Duration.zero);
      expect(flushed, isFalse);

      release.complete();
      await flush;
      expect(flushed, isTrue);
      expect(exporter.flushCount, 1);
    });

    test('shutdown drains, shuts the exporter down once and stops pushes',
        () async {
      final _RecordingExporter exporter = _RecordingExporter();
      final AtServerTelemetry telemetry = _enabledTelemetry(exporter);

      telemetry.push('atsign.server.before');
      await telemetry.shutdown();
      await telemetry.shutdown();
      telemetry.push('atsign.server.after');
      await telemetry.flush();

      expect(telemetry.isEnabled, isFalse);
      expect(exporter.shutdownCount, 1);
      expect(
        <String>[
          for (final AtTelemetryEvent event in exporter.events) event.name
        ],
        <String>['atsign.server.before'],
      );
    });

    test('the same instance starts pushing once enabled', () async {
      final _RecordingExporter exporter = _RecordingExporter();
      final AtServerTelemetry telemetry = AtServerTelemetry();

      telemetry.push('atsign.server.before');
      telemetry.enable(exporter: exporter, serverId: '@denise');
      telemetry.push('atsign.server.after');
      await telemetry.flush();

      expect(telemetry.serverId, '@denise');
      expect(
        <String>[
          for (final AtTelemetryEvent event in exporter.events) event.name
        ],
        <String>['atsign.server.after'],
      );
      expect(
        () => telemetry.enable(exporter: exporter, serverId: '@denise'),
        throwsStateError,
      );
    });

    test('drops events beyond the pending limit', () async {
      final Completer<void> release = Completer<void>();
      final _RecordingExporter exporter =
          _RecordingExporter(exportGate: release.future);
      final AtServerTelemetry telemetry = AtServerTelemetry(
        maxPendingEvents: 2,
      )..enable(exporter: exporter, serverId: '@denise');

      telemetry.push('atsign.server.one');
      telemetry.push('atsign.server.two');
      telemetry.push('atsign.server.three');
      release.complete();
      await telemetry.flush();
      telemetry.push('atsign.server.four');
      await telemetry.flush();

      expect(
        <String>[
          for (final AtTelemetryEvent event in exporter.events) event.name
        ],
        <String>[
          'atsign.server.one',
          'atsign.server.two',
          'atsign.server.four'
        ],
      );
      expect(() => AtServerTelemetry(maxPendingEvents: 0), throwsArgumentError);
    });

    test('flush with a timeout returns while an export is stuck', () async {
      final _RecordingExporter exporter =
          _RecordingExporter(exportGate: Completer<void>().future);
      final AtServerTelemetry telemetry = _enabledTelemetry(exporter);

      telemetry.push('atsign.server.op');

      await expectLater(
        telemetry.flush(timeout: const Duration(milliseconds: 50)),
        completes,
      );
      expect(exporter.flushCount, 0);
    });
  });
}

AtServerTelemetry _enabledTelemetry(AtTelemetryExporter exporter) {
  return AtServerTelemetry()..enable(exporter: exporter, serverId: '@denise');
}

final class _RecordingExporter implements AtTelemetryExporter {
  _RecordingExporter({this.failExports = false, this.exportGate});

  final bool failExports;
  final Future<void>? exportGate;
  final List<AtTelemetryEvent> events = <AtTelemetryEvent>[];
  int flushCount = 0;
  int shutdownCount = 0;

  @override
  Future<void> export(AtTelemetryEvent event) async {
    if (exportGate case final Future<void> gate) {
      await gate;
    }
    if (failExports) {
      throw StateError('collector unavailable');
    }
    events.add(event);
  }

  @override
  Future<void> flush() async {
    flushCount++;
  }

  @override
  Future<void> shutdown() async {
    shutdownCount++;
  }
}
