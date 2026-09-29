import 'dart:math';

import 'package:at_secondary/src/telemetry/at_server_heartbeat_scheduler.dart';
import 'package:at_secondary/src/telemetry/at_server_telemetry.dart';
import 'package:at_telemetry/at_telemetry.dart';
import 'package:test/test.dart';

void main() {
  test('heartbeat uses the current server Atsign as its server ID', () async {
    final _RecordingExporter exporter = _RecordingExporter();
    final AtServerHeartbeatScheduler scheduler = AtServerHeartbeatScheduler(
      telemetry: _enabledTelemetry(exporter),
      interval: const Duration(milliseconds: 100),
      offset: Duration.zero,
    );
    addTearDown(scheduler.stop);

    scheduler.start();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    scheduler.stop();

    expect(exporter.events, isNotEmpty);
    expect(AtServerHeartbeatScheduler.eventName, 'atsign.atserver.heartbeat');
    expect(exporter.events.first.name, AtServerHeartbeatScheduler.eventName);
    expect(exporter.events.first.attributes, <String, Object?>{
      'atsign.atserver.id': '@denise',
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
        telemetry: _enabledTelemetry(exporter ?? _RecordingExporter()),
        interval: interval,
        offset: offset,
        random: random,
      );
    }

    test('defaults to a one-minute interval with an offset inside it', () {
      expect(
        AtServerHeartbeatScheduler.defaultInterval,
        const Duration(minutes: 1),
      );
      final AtServerHeartbeatScheduler defaults = AtServerHeartbeatScheduler(
        telemetry: _enabledTelemetry(_RecordingExporter()),
      );

      expect(defaults.interval, const Duration(minutes: 1));
      expect(defaults.offset, greaterThanOrEqualTo(Duration.zero));
      expect(defaults.offset, lessThan(const Duration(minutes: 1)));
    });

    test('spreads random offsets across the whole minute', () {
      final Random random = Random(42);
      final List<Duration> offsets = <Duration>[
        for (int index = 0; index < 1000; index++)
          scheduler(random: random).offset,
      ];
      final Set<int> seconds = <int>{
        for (final Duration offset in offsets) offset.inSeconds,
      };

      expect(offsets, everyElement(greaterThanOrEqualTo(Duration.zero)));
      expect(offsets, everyElement(lessThan(const Duration(minutes: 1))));
      expect(seconds, hasLength(60));
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

    test('waits for the initial offset, then sends every interval', () async {
      const Duration interval = Duration(milliseconds: 400);
      const Duration offset = Duration(milliseconds: 200);
      final _RecordingExporter exporter = _RecordingExporter();
      final AtServerHeartbeatScheduler running = scheduler(
        interval: interval,
        offset: offset,
        exporter: exporter,
      );
      addTearDown(running.stop);

      running.start();
      running.start();
      expect(running.isRunning, isTrue);
      expect(exporter.events, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(exporter.events, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(exporter.events, hasLength(1));

      await Future<void>.delayed(const Duration(milliseconds: 430));
      expect(exporter.events, hasLength(2));
      final Duration between = exporter.events[1].timestamp.difference(
        exporter.events[0].timestamp,
      );
      expect(between, greaterThan(const Duration(milliseconds: 300)));
      expect(between, lessThan(const Duration(milliseconds: 500)));

      running.stop();
      expect(running.isRunning, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(exporter.events, hasLength(2));
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

AtServerTelemetry _enabledTelemetry(AtTelemetryExporter exporter) {
  return AtServerTelemetry()..enable(exporter: exporter, serverId: '@denise');
}
