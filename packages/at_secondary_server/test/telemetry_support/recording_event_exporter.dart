import 'package:at_telemetry/at_telemetry.dart';

final class RecordingEventExporter implements AtTelemetryExporter {
  final bool failExports;
  final Future<void>? exportGate;
  final List<AtTelemetryEvent> events = <AtTelemetryEvent>[];
  int flushCount = 0;
  int shutdownCount = 0;

  RecordingEventExporter({this.failExports = false, this.exportGate});

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
