import 'dart:async';

import 'package:at_secondary/src/telemetry/at_server_telemetry.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_configuration.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_exporter.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry_constants.dart';
import 'package:at_telemetry/at_telemetry.dart';
import 'package:at_telemetry/at_telemetry_otel.dart';
import 'package:crypton/crypton.dart';
import 'package:test/test.dart';

import 'telemetry_support/recording_event_exporter.dart';
import 'telemetry_support/recording_gauge_exporter.dart';

void main() {
  test('server-resolved at_chops signs and verifies telemetry', () async {
    final RSAKeypair keys = RSAKeypair.fromRandom();
    final AtTelemetryOtelHttpSignature signed =
        await AtTelemetryOtelHttpSignature.sign(
      body: <int>[1, 2, 3],
      path: '/v1/logs',
      keyId: '@denise',
      audience: 'collector.example.org',
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
      expect(_load(<String, String>{}), isNull);
    });

    test('prefers config.yaml over the environment', () {
      final AtServerTelemetryConfiguration configuration = _load(
        <String, String>{
          'AT_TELEMETRY_ENDPOINT': 'https://environment.example.org',
        },
        <String, Object?>{'endpoint': 'https://collector.example.org'},
      )!;

      expect(
          configuration.endpoint, Uri.parse('https://collector.example.org'));
    });

    test('falls back to the environment for an empty config.yaml value', () {
      final AtServerTelemetryConfiguration configuration = _load(
        <String, String>{
          'AT_TELEMETRY_ENDPOINT': 'https://collector.example.org',
        },
        <String, Object?>{'endpoint': ''},
      )!;

      expect(
          configuration.endpoint, Uri.parse('https://collector.example.org'));
    });

    test('an endpoint alone enables signed telemetry', () {
      final AtServerTelemetryConfiguration configuration =
          _load(<String, String>{
        'AT_TELEMETRY_ENDPOINT': 'https://collector.example.org:4318',
      })!;

      expect(configuration.endpoint.host, 'collector.example.org');
    });

    test('rejects insecure and invalid endpoints', () {
      expect(
        () => _load(<String, String>{
          'AT_TELEMETRY_ENDPOINT': 'http://collector.example.org',
        }),
        throwsFormatException,
      );
      expect(
        () => _load(<String, String>{
          'AT_TELEMETRY_ENDPOINT': 'https://',
        }),
        throwsFormatException,
      );
      expect(
        () => _load(<String, String>{
          'AT_TELEMETRY_ENDPOINT': 'collector.example.org:4318',
        }),
        throwsFormatException,
      );
    });

    test('ignores legacy collector Atsign and API key settings', () {
      expect(
        _load(<String, String>{
          'AT_TELEMETRY_COLLECTOR_ATSIGN': '@telemetry1',
          'AT_TELEMETRY_API_KEY': 'legacy-secret',
        }),
        isNull,
      );
    });
  });

  test('a configured exporter always signs with the server key', () async {
    final RSAKeypair keys = RSAKeypair.fromRandom();
    final AtTelemetryLogRecordExporter? exporter = await createAtServerTelemetryExporter(
      serverId: '@denise',
      signingKey: keys.privateKey.toString(),
      yaml: const <String, Object?>{},
      environment: <String, String>{
        'AT_TELEMETRY_ENDPOINT': 'https://collector.example.org:4318',
      },
    );

    expect(exporter, isA<AtTelemetryOtelSignedHttpExporter>());
    expect(exporter, isA<AtTelemetryMetricExporter>());
    await exporter!.shutdown();
  });

  test('signed telemetry is disabled with an empty signing key', () async {
    final AtTelemetryLogRecordExporter? exporter = await createAtServerTelemetryExporter(
      serverId: '@denise',
      signingKey: '',
      yaml: const <String, Object?>{},
      environment: <String, String>{
        'AT_TELEMETRY_ENDPOINT': 'https://collector.example.org:4318',
      },
    );

    expect(exporter, isNull);
  });

  test('telemetry is disabled when the environment is not configured',
      () async {
    final AtTelemetryLogRecordExporter? exporter = await createAtServerTelemetryExporter(
      serverId: '@denise',
      signingKey: '',
      yaml: const <String, Object?>{},
      environment: <String, String>{},
    );

    expect(exporter, isNull);
  });

  test('an invalid configuration disables telemetry instead of throwing',
      () async {
    final AtTelemetryLogRecordExporter? exporter = await createAtServerTelemetryExporter(
      serverId: '@denise',
      signingKey: '',
      yaml: const <String, Object?>{},
      environment: <String, String>{
        'AT_TELEMETRY_ENDPOINT': 'http://collector.example.org:4318',
      },
    );

    expect(exporter, isNull);
  });

  group('AtServerTelemetry', () {
    test('pushes events stamped with the server ID and timestamp', () async {
      final RecordingEventExporter exporter = RecordingEventExporter();
      final AtServerTelemetry telemetry =
          AtServerTelemetry(heartbeatInterval: null)
            ..enable(exporter: exporter, serverId: '@denise');

      final DateTime beforePush = DateTime.now().toUtc();
      telemetry.emitEvent(
        '$atServerTelemetryEventPrefix.notify',
        attributes: <String, Object?>{'atsign.notify.count': 3},
      );
      final DateTime afterPush = DateTime.now().toUtc();
      await telemetry.flush();

      expect(telemetry.isEnabled, isTrue);
      expect(exporter.events.single.name, 'atsign.atserver.notify');
      final DateTime timestamp = exporter.events.single.timestamp;
      expect(timestamp.isUtc, isTrue);
      expect(timestamp.isBefore(beforePush), isFalse);
      expect(timestamp.isAfter(afterPush), isFalse);
      expect(exporter.events.single.attributes, <String, Object?>{
        'atsign.notify.count': 3,
        'atsign.atserver.id': '@denise',
      });
    });

    test('callers cannot override the server ID', () async {
      final RecordingEventExporter exporter = RecordingEventExporter();
      final AtServerTelemetry telemetry = _enabledTelemetry(exporter);

      telemetry.emitEvent(
        '$atServerTelemetryEventPrefix.op',
        attributes: <String, Object?>{'atsign.atserver.id': '@mallory'},
      );
      await telemetry.flush();

      expect(
          exporter.events.single.attributes['atsign.atserver.id'], '@denise');
    });

    test('drops events with an empty name', () async {
      final RecordingEventExporter exporter = RecordingEventExporter();
      final AtServerTelemetry telemetry = _enabledTelemetry(exporter);

      telemetry.emitEvent('  ');
      await telemetry.flush();

      expect(exporter.events, isEmpty);
    });

    test('only exports events in the atServer namespace', () async {
      final RecordingEventExporter exporter = RecordingEventExporter();
      final AtServerTelemetry telemetry = _enabledTelemetry(exporter);

      expect(atServerTelemetryEventPrefix, 'atsign.atserver');
      telemetry.emitEvent('atsign.server.heartbeat');
      telemetry.emitEvent(atServerTelemetryEventPrefix);
      telemetry.emitEvent('$atServerTelemetryEventPrefix.');
      telemetry.emitEvent('atsign.atserverx.heartbeat');
      telemetry.emitEvent('atsign.atserver.invalid ');
      telemetry.emitEvent(atServerHeartbeatEventName);
      await telemetry.flush();

      expect(exporter.events.single.name, 'atsign.atserver.heartbeat');
    });

    test('lifecycle events are accepted in the atServer namespace', () async {
      final RecordingEventExporter exporter = RecordingEventExporter();
      final AtServerTelemetry telemetry = _enabledTelemetry(exporter);

      telemetry.emitEvent(atServerStartedEventName);
      telemetry.emitEvent(atServerStoppedEventName);
      await telemetry.flush();

      expect(
        <String>[
          for (final AtTelemetryLogRecord event in exporter.events) event.name
        ],
        <String>['atsign.atserver.started', 'atsign.atserver.stopped'],
      );
      expect(
        exporter.events.map((AtTelemetryLogRecord e) => e.attributes),
        everyElement(containsPair('atsign.atserver.id', '@denise')),
      );
    });

    test('telemetry ignores every call until enabled', () async {
      final AtServerTelemetry telemetry =
          AtServerTelemetry(heartbeatInterval: null);

      telemetry.emitEvent('$atServerTelemetryEventPrefix.op');
      await telemetry.flush();
      await telemetry.shutdown();

      expect(telemetry.isEnabled, isFalse);
    });

    test('export failures never reach the caller', () async {
      final AtServerTelemetry telemetry =
          _enabledTelemetry(RecordingEventExporter(failExports: true));

      telemetry.emitEvent('$atServerTelemetryEventPrefix.op');

      await expectLater(telemetry.flush(), completes);
    });

    test('flush waits for exports that are still in flight', () async {
      final Completer<void> release = Completer<void>();
      final RecordingEventExporter exporter =
          RecordingEventExporter(exportGate: release.future);
      final AtServerTelemetry telemetry = _enabledTelemetry(exporter);

      telemetry.emitEvent('$atServerTelemetryEventPrefix.op');
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
      final RecordingEventExporter exporter = RecordingEventExporter();
      final AtServerTelemetry telemetry = _enabledTelemetry(exporter);

      telemetry.emitEvent('$atServerTelemetryEventPrefix.before');
      await telemetry.shutdown();
      await telemetry.shutdown();
      telemetry.emitEvent('$atServerTelemetryEventPrefix.after');
      await telemetry.flush();

      expect(telemetry.isEnabled, isFalse);
      expect(exporter.shutdownCount, 1);
      expect(
        <String>[
          for (final AtTelemetryLogRecord event in exporter.events) event.name
        ],
        <String>['atsign.atserver.before'],
      );
    });

    test('the same instance starts pushing once enabled', () async {
      final RecordingEventExporter exporter = RecordingEventExporter();
      final AtServerTelemetry telemetry =
          AtServerTelemetry(heartbeatInterval: null);

      telemetry.emitEvent('$atServerTelemetryEventPrefix.before');
      telemetry.enable(exporter: exporter, serverId: '@denise');
      telemetry.emitEvent('$atServerTelemetryEventPrefix.after');
      await telemetry.flush();

      expect(telemetry.serverId, '@denise');
      expect(
        <String>[
          for (final AtTelemetryLogRecord event in exporter.events) event.name
        ],
        <String>['atsign.atserver.after'],
      );
      expect(
        () => telemetry.enable(exporter: exporter, serverId: '@denise'),
        throwsStateError,
      );
    });

    test('drops events beyond the pending limit', () async {
      final Completer<void> release = Completer<void>();
      final RecordingEventExporter exporter =
          RecordingEventExporter(exportGate: release.future);
      final AtServerTelemetry telemetry = AtServerTelemetry(
        maxPendingEvents: 2,
        heartbeatInterval: null,
      )..enable(exporter: exporter, serverId: '@denise');

      telemetry.emitEvent('$atServerTelemetryEventPrefix.one');
      telemetry.emitEvent('$atServerTelemetryEventPrefix.two');
      telemetry.emitEvent('$atServerTelemetryEventPrefix.three');
      telemetry.emitEvent('$atServerTelemetryEventPrefix.four');
      release.complete();
      await telemetry.flush();
      telemetry.emitEvent('$atServerTelemetryEventPrefix.five');
      await telemetry.flush();

      expect(
        <String>[
          for (final AtTelemetryLogRecord event in exporter.events) event.name
        ],
        <String>[
          'atsign.atserver.one',
          'atsign.atserver.two',
          'atsign.atserver.five'
        ],
      );
      expect(() => AtServerTelemetry(maxPendingEvents: 0), throwsArgumentError);
    });

    test('enable starts the heartbeat and shutdown stops it', () async {
      final RecordingGaugeExporter exporter = RecordingGaugeExporter();
      final AtServerTelemetry telemetry = AtServerTelemetry(
        heartbeatInterval: const Duration(milliseconds: 50),
      );
      addTearDown(telemetry.shutdown);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(exporter.gauges, isEmpty);

      telemetry.enable(exporter: exporter, serverId: '@denise');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(exporter.gauges, isNotEmpty);
      expect(exporter.gauges.first.name, 'atsign.atserver.uptime');
      expect(exporter.gauges.first.attributes['atsign.atserver.id'], '@denise');

      await telemetry.shutdown();
      final int sent = exporter.gauges.length;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(exporter.gauges, hasLength(sent));
    });

    test('a null heartbeat interval sends no heartbeat', () async {
      final RecordingGaugeExporter exporter = RecordingGaugeExporter();
      final AtServerTelemetry telemetry = AtServerTelemetry(
        heartbeatInterval: null,
      )..enable(exporter: exporter, serverId: '@denise');
      addTearDown(telemetry.shutdown);

      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(exporter.gauges, isEmpty);
    });

    test('can be enabled again after shutdown', () async {
      final RecordingGaugeExporter first = RecordingGaugeExporter();
      final RecordingGaugeExporter second = RecordingGaugeExporter();
      final AtServerTelemetry telemetry = AtServerTelemetry(
        heartbeatInterval: const Duration(milliseconds: 50),
      )..enable(exporter: first, serverId: '@denise');
      addTearDown(telemetry.shutdown);

      await telemetry.shutdown();
      telemetry.enable(exporter: second, serverId: '@denise');
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(second.gauges, isNotEmpty);
    });

    test('flush with a timeout returns while an export is stuck', () async {
      final RecordingEventExporter exporter =
          RecordingEventExporter(exportGate: Completer<void>().future);
      final AtServerTelemetry telemetry = _enabledTelemetry(exporter);

      telemetry.emitEvent('$atServerTelemetryEventPrefix.op');

      await expectLater(
        telemetry.flush(timeout: const Duration(milliseconds: 50)),
        completes,
      );
      expect(exporter.flushCount, 0);
    });
  });
}

AtServerTelemetry _enabledTelemetry(AtTelemetryLogRecordExporter exporter) {
  return AtServerTelemetry(heartbeatInterval: null)
    ..enable(exporter: exporter, serverId: '@denise');
}

AtServerTelemetryConfiguration? _load(
  Map<String, String> environment, [
  Map<String, Object?> yaml = const <String, Object?>{},
]) {
  return AtServerTelemetryConfiguration.load(
    yaml: yaml,
    environment: environment,
  );
}
