import 'dart:math';

import 'package:at_secondary/src/telemetry/at_server_heartbeat.dart';
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

  group('AtServerHeartbeatConfiguration', () {
    test('is disabled when telemetry environment variables are absent', () {
      expect(
        AtServerHeartbeatConfiguration.fromEnvironment(<String, String>{}),
        isNull,
      );
    });

    test('uses the configured endpoint, audience and optional API key', () {
      final AtServerHeartbeatConfiguration configuration =
          AtServerHeartbeatConfiguration.fromEnvironment(<String, String>{
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
      final AtServerHeartbeatConfiguration legacy =
          AtServerHeartbeatConfiguration.fromEnvironment(<String, String>{
        'AT_TELEMETRY_ENDPOINT': 'http://localhost:4318',
        'AT_TELEMETRY_API_KEY': 'secret',
      })!;
      expect(legacy.collectorAtsign, isNull);
      expect(legacy.apiKey, 'secret');
      expect(
          AtServerHeartbeatConfiguration.fromEnvironment(<String, String>{
            'AT_TELEMETRY_ENDPOINT': 'http://localhost:4318',
            'AT_TELEMETRY_COLLECTOR_ATSIGN': '@telemetry1',
          })!
              .apiKey,
          isNull);
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
          'AT_TELEMETRY_ENDPOINT': 'http://localhost:4318',
          'AT_TELEMETRY_COLLECTOR_ATSIGN': '@Telemetry1',
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

  test('signed heartbeats do not start without the signing key', () async {
    expect(
        await startAtServerHeartbeat(
          serverId: '@denise',
          signingKey: null,
          environment: <String, String>{
            'AT_TELEMETRY_ENDPOINT': 'http://localhost:4318',
            'AT_TELEMETRY_COLLECTOR_ATSIGN': '@telemetry1',
          },
        ),
        isNull);
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

  group('AtServerHeartbeatScheduler', () {
    AtServerHeartbeatScheduler scheduler({
      Duration interval = const Duration(minutes: 1),
      Duration? offset,
      Random? random,
      _RecordingExporter? exporter,
    }) {
      return AtServerHeartbeatScheduler(
        heartbeat: AtServerHeartbeat(
          telemetryExporter: exporter ?? _RecordingExporter(),
          serverId: '@denise',
        ),
        interval: interval,
        offset: offset,
        random: random,
      );
    }

    test('defaults to a one-minute interval with an offset inside it', () {
      final AtServerHeartbeatScheduler defaults = AtServerHeartbeatScheduler(
        heartbeat: AtServerHeartbeat(
          telemetryExporter: _RecordingExporter(),
          serverId: '@denise',
        ),
      );

      expect(defaults.interval, const Duration(minutes: 1));
      expect(defaults.offset, greaterThanOrEqualTo(Duration.zero));
      expect(defaults.offset, lessThan(const Duration(minutes: 1)));
    });

    test('spreads random offsets across the whole minute', () {
      final Random random = Random(42);
      final List<Duration> offsets = <Duration>[
        for (int index = 0; index < 1000; index++)
          AtServerHeartbeatScheduler.randomOffset(
            const Duration(minutes: 1),
            random,
          ),
      ];
      final Set<int> seconds = <int>{
        for (final Duration offset in offsets) offset.inSeconds,
      };

      expect(offsets, everyElement(greaterThanOrEqualTo(Duration.zero)));
      expect(offsets, everyElement(lessThan(const Duration(minutes: 1))));
      expect(seconds, hasLength(60));
    });

    test('schedules the offset within the current minute when ahead', () {
      final DateTime slot = scheduler(offset: const Duration(seconds: 35))
          .nextSlot(now: DateTime.utc(2026, 2, 24, 10, 14, 20));

      expect(slot, DateTime.utc(2026, 2, 24, 10, 14, 35));
    });

    test('schedules the next minute when the offset has passed', () {
      final AtServerHeartbeatScheduler fixed = scheduler(
        offset: const Duration(seconds: 5, milliseconds: 250),
      );

      expect(
        fixed.nextSlot(now: DateTime.utc(2026, 2, 24, 10, 14, 20)),
        DateTime.utc(2026, 2, 24, 10, 15, 5, 250),
      );
      expect(
        fixed.nextSlot(now: DateTime.utc(2026, 2, 24, 10, 14, 5, 250)),
        DateTime.utc(2026, 2, 24, 10, 15, 5, 250),
      );
    });

    test('keeps every slot inside a single wall-clock minute', () {
      final Random random = Random(7);
      for (int index = 0; index < 500; index++) {
        final Duration offset = AtServerHeartbeatScheduler.randomOffset(
          const Duration(minutes: 1),
          random,
        );
        final DateTime now = DateTime.utc(2026, 2, 24, 10).add(
          Duration(milliseconds: random.nextInt(3600000)),
        );

        final DateTime slot = scheduler(offset: offset).nextSlot(now: now);
        final DateTime minute = DateTime.utc(
          slot.year,
          slot.month,
          slot.day,
          slot.hour,
          slot.minute,
        );

        expect(slot.isAfter(now), isTrue);
        expect(slot.difference(now),
            lessThanOrEqualTo(const Duration(minutes: 1)));
        expect(slot.difference(minute), offset);
      }
    });

    test('skips a slot that was already sent when a timer fires early', () {
      final AtServerHeartbeatScheduler fixed = scheduler(
        offset: const Duration(seconds: 30),
      );
      final DateTime previousSlot = DateTime.utc(2026, 2, 24, 10, 14, 30);

      expect(
        fixed.nextSlot(
          now: previousSlot.subtract(const Duration(milliseconds: 1)),
          previousSlot: previousSlot,
        ),
        DateTime.utc(2026, 2, 24, 10, 15, 30),
      );
      expect(
        fixed.nextSlot(
          now: DateTime.utc(2026, 2, 24, 10, 9, 45),
          previousSlot: previousSlot,
        ),
        DateTime.utc(2026, 2, 24, 10, 10, 30),
      );
    });

    test('rejects invalid intervals and offsets', () {
      expect(
        () => scheduler(interval: Duration.zero, offset: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => scheduler(offset: const Duration(minutes: 1)),
        throwsArgumentError,
      );
      expect(
        () => scheduler(offset: const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });

    test('waits for its slot instead of sending immediately', () {
      final _RecordingExporter exporter = _RecordingExporter();
      final AtServerHeartbeatScheduler waiting = scheduler(
        exporter: exporter,
      );
      addTearDown(waiting.stop);

      waiting.start();

      expect(waiting.isRunning, isTrue);
      expect(exporter.events, isEmpty);
    });

    test('sends once per interval at its offset', () async {
      const Duration interval = Duration(milliseconds: 400);
      const Duration offset = Duration(milliseconds: 100);
      final _RecordingExporter exporter = _RecordingExporter();
      final AtServerHeartbeatScheduler running = scheduler(
        interval: interval,
        offset: offset,
        exporter: exporter,
      );
      addTearDown(running.stop);

      running.start();
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      running.stop();

      final List<int> periods = <int>[
        for (final AtTelemetryEvent event in exporter.events)
          event.timestamp.microsecondsSinceEpoch ~/ interval.inMicroseconds,
      ];
      expect(exporter.events.length, greaterThanOrEqualTo(2));
      expect(periods.toSet(), hasLength(periods.length));
      for (final AtTelemetryEvent event in exporter.events) {
        final Duration intoPeriod = Duration(
          microseconds:
              event.timestamp.microsecondsSinceEpoch % interval.inMicroseconds,
        );
        expect(intoPeriod, greaterThanOrEqualTo(offset));
      }
      expect(running.isRunning, isFalse);
    });
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
